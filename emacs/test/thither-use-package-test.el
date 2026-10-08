;;; thither-use-package-test.el --- the documented use-package forms work  -*- lexical-binding: t; no-byte-compile: t; -*-

;; Each scenario runs in a fresh Emacs (so "not loaded yet" is real).
;; Needs THITHER_SERVER (see thither-test.el).

(require 'ert)

(defconst thither-up-test--dir (file-name-directory (or load-file-name buffer-file-name)))

(defun thither-up-test--run (script)
  (let* ((dir thither-up-test--dir)
         (emacs (expand-file-name invocation-name invocation-directory))
         (process-environment
          (cons (concat "THITHER_EMACS_DIR=" (expand-file-name ".." dir)) process-environment)))
    (with-temp-buffer
      (let ((code (call-process emacs nil t nil "-Q" "--batch" "-l" (expand-file-name script dir))))
        (list code (buffer-string))))))

(defun thither-up-test--ok (script)
  (let ((r (thither-up-test--run script)))
    (should (equal (list 0 t)
                   (list (car r) (and (string-match-p "^DONE$" (cadr r)) t))))
    (should-not (string-match-p "^FAIL" (cadr r)))))

(ert-deftest thither-use-package-lazy ()
  (unless (getenv "THITHER_SERVER") (ert-skip "THITHER_SERVER not set"))
  (thither-up-test--ok "up-lazy.el"))

(ert-deftest thither-use-package-eager ()
  (thither-up-test--ok "up-eager.el"))

(ert-deftest thither-package-autoloads-cookies ()
  "The files carry the autoload cookies package.el turns into autoloads."
  (let ((setup (expand-file-name "../thither-setup.el" thither-up-test--dir)))
    (with-temp-buffer
      (insert-file-contents setup)
      (dolist (fn '("thither-find-file" "thither-disconnect-all"))
        (goto-char (point-min))
        (should (re-search-forward (concat ";;;###autoload\n(defun " fn " ") nil t)))
      (goto-char (point-min))
      (should (search-forward "(autoload 'thither-file-name-handler" nil t)))))

(provide 'thither-use-package-test)
;;; thither-use-package-test.el ends here
