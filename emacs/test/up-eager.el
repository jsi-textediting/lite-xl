;;; up-eager.el --- use-package, eager (:demand t)  -*- lexical-binding: t; no-byte-compile: t; -*-

;; Run in a fresh Emacs by lxs-use-package-test.el (needs LXS_EMACS_DIR, LXS_SERVER).

(require 'use-package)

(defun up--server () (split-string-and-unquote (getenv "LXS_SERVER")))

(use-package lxs-setup
  :ensure nil
  :demand t
  :load-path (lambda () (list (getenv "LXS_EMACS_DIR")))
  :custom
  (lxs-server-program "/opt/lxs/lite-xl-server")
  (lxs-host-options `(("devbox" :server "/home/me/lxs/lite-xl-server"
                       :server-args ("--root" "/home/me"))
                      ("t" :command ,(lambda (_host) (up--server))))))

(defun up--check (label ok)
  (message "%s: %s" (if ok "ok" "FAIL") label)
  (unless ok (kill-emacs 1)))

(up--check "loaded" (featurep 'lxs-setup))
(up--check "handler registered" (rassq #'lxs-file-name-handler file-name-handler-alist))
(up--check "launcher installed" (eq lxs-command-function #'lxs-launch-command))
(up--check "launch command with options"
           (equal (lxs-launch-command "devbox")
                  (append (if (eq system-type 'windows-nt)
                              (list (or (executable-find "plink") "plink") "-ssh" "-batch" "-T")
                            (list "ssh" "-T"))
                          '("devbox" "/home/me/lxs/lite-xl-server" "--root" "/home/me" "--stdio"))))
(up--check "default server program"
           (equal (car (last (lxs-launch-command "other") 2)) "/opt/lxs/lite-xl-server"))
(up--check ":command override" (equal (lxs-launch-command "t") (up--server)))
(up--check "user command function is kept"
           (let ((lxs-command-function #'ignore))
             ;; loading again must not replace a value the user set
             (load (expand-file-name "lxs-setup.el" (getenv "LXS_EMACS_DIR")) nil t)
             (eq lxs-command-function #'ignore)))
(message "DONE")
