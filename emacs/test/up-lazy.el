;;; up-lazy.el --- use-package, deferred: loaded on first /lxs: name  -*- lexical-binding: t; no-byte-compile: t; -*-

;; Run in a fresh Emacs by lxs-use-package-test.el (needs LXS_EMACS_DIR, LXS_SERVER).

(require 'use-package)

(defun up--server () (split-string-and-unquote (getenv "LXS_SERVER")))

(use-package lxs-setup
  :ensure nil
  :load-path (lambda () (list (getenv "LXS_EMACS_DIR")))
  :commands (lxs-find-file lxs-disconnect-all)
  :init
  ;; the handler must exist before the package is loaded
  (autoload 'lxs-file-name-handler "lxs-setup")
  (add-to-list 'file-name-handler-alist
               (cons "\\`/lxs:[^:/]+:" #'lxs-file-name-handler))
  :custom
  (lxs-cache-ttl 5)
  (lxs-hosts '("t"))
  (lxs-host-options `(("t" :command ,(lambda (_host) (up--server))))))

(defun up--check (label ok)
  (message "%s: %s" (if ok "ok" "FAIL") label)
  (unless ok (kill-emacs 1)))

(up--check "not loaded at startup" (not (featurep 'lxs-setup)))
(up--check "not even lxs-fs loaded" (not (featurep 'lxs-fs)))
(up--check "commands are autoloaded" (and (fboundp 'lxs-find-file) (autoloadp (symbol-function 'lxs-find-file))))

;; first use of an lxs name loads the package through the handler autoload
(up--check "expand-file-name works" (equal "/lxs:t:/a/b" (expand-file-name "/lxs:t:/a/./b")))
(up--check "package loaded on demand" (featurep 'lxs-setup))
(up--check ":custom applied" (and (= 5 lxs-cache-ttl) (equal '("t") lxs-hosts)))
(up--check "launcher installed" (eq lxs-command-function #'lxs-launch-command))
(up--check "handler registered once"
           (= 1 (length (cl-remove-if-not (lambda (e) (eq (cdr e) 'lxs-file-name-handler))
                                          file-name-handler-alist))))
(let* ((conn (lxs-connection "t"))
       (dir (string-trim (plist-get (lxs-exec conn '("mktemp" "-d")) :stdout)))
       (remote (concat "/lxs:t:" dir "/x/")))
  ;; everything through the handler, so it also works against a remote server
  (make-directory remote t)
  (write-region "hello" nil (concat remote "f.txt") nil 'silent)
  (up--check "remote file seen" (file-exists-p (concat remote "f.txt")))
  (up--check "remote read" (equal "hello" (with-temp-buffer
                                            (insert-file-contents (concat remote "f.txt"))
                                            (buffer-string))))
  (lxs-exec conn (list "rm" "-rf" dir)))
(lxs-disconnect-all)
(message "DONE")
