;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2015 David Thompson <davet@gnu.org>
;;; Copyright © 2016, 2017 Ludovic Courtès <ludo@gnu.org>
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.
;;;
;;; GNU Guix is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with GNU Guix.  If not, see <http://www.gnu.org/licenses/>.

(define-module (gnu system linux-container)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:use-module (guix config)
  #:use-module (guix store)
  #:use-module (guix gexp)
  #:use-module (guix derivations)
  #:use-module (guix monads)
  #:use-module (guix modules)
  #:use-module (gnu build linux-container)
  #:use-module (gnu services)
  #:use-module (gnu system)
  #:use-module (gnu system file-systems)
  #:export (system-container
            containerized-operating-system
            container-script))

(define (containerized-operating-system os mappings)
  "Return an operating system based on OS for use in a Linux container
environment.  MAPPINGS is a list of <file-system-mapping> to realize in the
containerized OS."
  (define user-file-systems
    (remove (lambda (fs)
              (let ((target (file-system-mount-point fs))
                    (source (file-system-device fs)))
                (or (string=? target (%store-prefix))
                    (string=? target "/")
                    (and (string? source)
                         (string-prefix? "/dev/" source))
                    (string-prefix? "/dev" target)
                    (string-prefix? "/sys" target))))
            (operating-system-file-systems os)))

  (define (mapping->fs fs)
    (file-system (inherit (file-system-mapping->bind-mount fs))
      (needed-for-boot? #t)))

  (operating-system (inherit os)
    (swap-devices '()) ; disable swap
    (file-systems (append (map mapping->fs (cons %store-mapping mappings))
                          %container-file-systems
                          user-file-systems))))


(define %network-configuration-files
  '("/etc/resolv.conf"
    "/etc/nsswitch.conf"
    "/etc/services"
    "/etc/hosts"))

(define* (container-script os #:key (mappings '())
                           container-shared-network?)
  "Return a derivation of a script that runs OS as a Linux container.
MAPPINGS is a list of <file-system> objects that specify the files/directories
that will be shared with the host system."
  (let* ((os           (containerized-operating-system
                        os
                        (append
                         mappings
                         (if
                          container-shared-network?
                          (filter-map (lambda (file)
                                        (and (file-exists? file)
                                             (file-system-mapping
                                              (source file)
                                              (target file)
                                              ;; XXX: On some GNU/Linux
                                              ;; systems, /etc/resolv.conf is a
                                              ;; symlink to a file in a tmpfs
                                              ;; which, for an unknown reason,
                                              ;; cannot be bind mounted
                                              ;; read-only within the
                                              ;; container.
                                              (writable?
                                               (string=?
                                                file "/etc/resolv.conf")))))
                                      %network-configuration-files)
                          '()))))
         (file-systems (filter file-system-needed-for-boot?
                               (operating-system-file-systems os)))
         (specs        (map file-system->spec file-systems)))

    (mlet* %store-monad ((os-drv
                          (operating-system-derivation
                           os
                           #:container? #t
                           #:container-shared-network? container-shared-network?)))

      (define script
        (with-imported-modules (source-module-closure
                                '((guix build utils)
                                  (gnu build linux-container)))
          #~(begin
              (use-modules (gnu build linux-container)
                           (gnu system file-systems) ;spec->file-system
                           (guix build utils))

              (call-with-container (map spec->file-system '#$specs)
                (lambda ()
                  (setenv "HOME" "/root")
                  (setenv "TMPDIR" "/tmp")
                  (setenv "GUIX_NEW_SYSTEM" #$os-drv)
                  (for-each mkdir-p '("/run" "/bin" "/etc" "/home" "/var"))
                  (primitive-load (string-append #$os-drv "/boot")))
                ;; A range of 65536 uid/gids is used to cover 16 bits worth of
                ;; users and groups, which is sufficient for most cases.
                ;;
                ;; See: http://www.freedesktop.org/software/systemd/man/systemd-nspawn.html#--private-users=
                #:host-uids 65536
                #:namespaces (if #$container-shared-network?
                                 (delq 'net %namespaces)
                                 %namespaces)))))

      (gexp->script "run-container" script))))
