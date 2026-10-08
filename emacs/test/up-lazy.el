;;; up-lazy.el --- use-package, deferred: loaded on first /thither: name  -*- lexical-binding: t; no-byte-compile: t; -*-

;; Run in a fresh Emacs by thither-use-package-test.el (needs THITHER_EMACS_DIR, THITHER_SERVER).

(require 'use-package)

(defun up--server () (split-string-and-unquote (getenv "THITHER_SERVER")))

(use-package thither-setup
  :ensure nil
  :load-path (lambda () (list (getenv "THITHER_EMACS_DIR")))
  :commands (thither-find-file thither-disconnect-all)
  :init
  ;; the handler must exist before the package is loaded
  (autoload 'thither-file-name-handler "thither-setup")
  (add-to-list 'file-name-handler-alist
               (cons "\\`/thither:[^:/]+:" #'thither-file-name-handler))
  :custom
  (thither-cache-ttl 5)
  (thither-hosts '("t"))
  (thither-host-options `(("t" :command ,(lambda (_host) (up--server))))))

(defun up--check (label ok)
  (message "%s: %s" (if ok "ok" "FAIL") label)
  (unless ok (kill-emacs 1)))

(up--check "not loaded at startup" (not (featurep 'thither-setup)))
(up--check "not even thither-fs loaded" (not (featurep 'thither-fs)))
(up--check "commands are autoloaded" (and (fboundp 'thither-find-file) (autoloadp (symbol-function 'thither-find-file))))

;; first use of an thither name loads the package through the handler autoload
(up--check "expand-file-name works" (equal "/thither:t:/a/b" (expand-file-name "/thither:t:/a/./b")))
(up--check "package loaded on demand" (featurep 'thither-setup))
(up--check ":custom applied" (and (= 5 thither-cache-ttl) (equal '("t") thither-hosts)))
(up--check "launcher installed" (eq thither-command-function #'thither-launch-command))
(up--check "handler registered once"
           (= 1 (length (cl-remove-if-not (lambda (e) (eq (cdr e) 'thither-file-name-handler))
                                          file-name-handler-alist))))
(let* ((conn (thither-connection "t"))
       (dir (string-trim (plist-get (thither-exec conn '("mktemp" "-d")) :stdout)))
       (remote (concat "/thither:t:" dir "/x/")))
  ;; everything through the handler, so it also works against a remote server
  (make-directory remote t)
  (write-region "hello" nil (concat remote "f.txt") nil 'silent)
  (up--check "remote file seen" (file-exists-p (concat remote "f.txt")))
  (up--check "remote read" (equal "hello" (with-temp-buffer
                                            (insert-file-contents (concat remote "f.txt"))
                                            (buffer-string))))
  (thither-exec conn (list "rm" "-rf" dir)))
(thither-disconnect-all)
(message "DONE")
