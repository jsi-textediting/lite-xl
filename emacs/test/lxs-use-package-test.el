;;; lxs-use-package-test.el --- the documented use-package forms work  -*- lexical-binding: t; no-byte-compile: t; -*-

;; Each scenario runs in a fresh Emacs (so "not loaded yet" is real).
;; Needs LXS_SERVER (see lxs-test.el).

(require 'ert)

(defconst lxs-up-test--dir (file-name-directory (or load-file-name buffer-file-name)))

(defun lxs-up-test--run (script)
  (let* ((dir lxs-up-test--dir)
         (emacs (expand-file-name invocation-name invocation-directory))
         (process-environment
          (cons (concat "LXS_EMACS_DIR=" (expand-file-name ".." dir)) process-environment)))
    (with-temp-buffer
      (let ((code (call-process emacs nil t nil "-Q" "--batch" "-l" (expand-file-name script dir))))
        (list code (buffer-string))))))

(defun lxs-up-test--ok (script)
  (let ((r (lxs-up-test--run script)))
    (should (equal (list 0 t)
                   (list (car r) (and (string-match-p "^DONE$" (cadr r)) t))))
    (should-not (string-match-p "^FAIL" (cadr r)))))

(ert-deftest lxs-use-package-lazy ()
  (unless (getenv "LXS_SERVER") (ert-skip "LXS_SERVER not set"))
  (lxs-up-test--ok "up-lazy.el"))

(ert-deftest lxs-use-package-eager ()
  (lxs-up-test--ok "up-eager.el"))

(ert-deftest lxs-package-autoloads-cookies ()
  "The files carry the autoload cookies package.el turns into autoloads."
  (let ((setup (expand-file-name "../lxs-setup.el" lxs-up-test--dir)))
    (with-temp-buffer
      (insert-file-contents setup)
      (dolist (fn '("lxs-find-file" "lxs-disconnect-all"))
        (goto-char (point-min))
        (should (re-search-forward (concat ";;;###autoload\n(defun " fn " ") nil t)))
      (goto-char (point-min))
      (should (search-forward "(autoload 'lxs-file-name-handler" nil t)))))

(provide 'lxs-use-package-test)
;;; lxs-use-package-test.el ends here
