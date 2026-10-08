;;; thither-integration-test.el --- thither with consult, vertico completion, project  -*- lexical-binding: t; no-byte-compile: t; -*-

;; Needs consult installed in the user's package directory (WSL ~/.emacs.d/elpa).
;; Tests are skipped when it is missing.  Run: emacs/test/run-wsl.sh local|remote emacs/test/thither-integration-test.el

(require 'ert)
(require 'package)
(package-initialize)
(require 'thither-setup)
(load (expand-file-name "thither-fs-test.el" (file-name-directory (or load-file-name buffer-file-name))) nil t)

(defvar thither-int--have-consult (require 'consult nil t))

(defun thither-int--async (builder dir input)
  "Run consult's own async process pipeline in DIR; return (STATE . LINES)."
  (let* ((default-directory dir) lines state
         (sink (lambda (a)
                 (cond ((consp a) (setq lines (append lines a)))
                       ((and (vectorp a) (eq (aref a 0) 'indicator)) (setq state (aref a 1))))))
         (fn (funcall (consult--async-process builder :file-handler t) sink)))
    (funcall fn 'setup)
    (funcall fn input)
    (thither-fs-test--wait (lambda () (memq state '(finished failed killed))) 30)
    (funcall fn 'destroy)
    (unless (eq state 'finished)
      (message "consult log: %s"
               (when (get-buffer consult--async-log)
                 (with-current-buffer consult--async-log (buffer-string)))))
    (cons state lines)))

(defmacro thither-int--with-tree (var &rest body)
  (declare (indent 1))
  `(thither-fs-test--with-dir ,var
     (unless thither-int--have-consult (ert-skip "consult not installed"))
     (make-directory (concat ,var "src/deep") t)
     (write-region "alpha\nneedle one\nomega\n" nil (concat ,var "src/a.txt") nil 'silent)
     (write-region "x\nNEEDLE two ünï\n" nil (concat ,var "src/deep/b.txt") nil 'silent)
     (write-region "nothing\n" nil (concat ,var "c.txt") nil 'silent)
     ,@body))

(ert-deftest thither-int-consult-ripgrep ()
  (thither-int--with-tree d
    (let ((default-directory d))
      (skip-unless (executable-find "rg" t)))
    ;; consult uses smart case: an all lowercase input matches NEEDLE too
    (let ((r (thither-int--async (consult--ripgrep-make-builder '(".")) d "needle")))
      (should (eq 'finished (car r)))
      (should (= 2 (length (cdr r))))
      ;; consult passes --null: file name and line number are NUL separated
      (should (equal '("./src/a.txt:2:needle one")
                     (mapcar (lambda (l) (string-replace (string 0) ":" l))
                             (cl-remove-if-not (lambda (l) (string-match-p "a\\.txt" l)) (cdr r)))))
      (should (cl-some (lambda (l) (string-match-p "NEEDLE two ünï" l)) (cdr r))))
    (let ((r (thither-int--async (consult--ripgrep-make-builder '(".")) d "NEEDLE")))
      (should (= 1 (length (cdr r))))
      (should (string-match-p "deep/b\\.txt.2.NEEDLE two ünï" (car (cdr r)))))
    (let ((r (thither-int--async (consult--ripgrep-make-builder '(".")) d "zzzznomatch")))
      (should (memq (car r) '(finished failed)))
      (should-not (cdr r)))))

(ert-deftest thither-int-consult-grep-fallback ()
  (thither-int--with-tree d
    (let ((r (thither-int--async (consult--grep-make-builder '(".")) d "needle")))
      (should (eq 'finished (car r)))
      (should (cl-some (lambda (l) (string-match-p "a\\.txt.2:needle one" l)) (cdr r))))))

(ert-deftest thither-int-consult-fd ()
  (thither-int--with-tree d
    (let ((default-directory d))
      (skip-unless (executable-find "fd" t)))
    (let ((r (thither-int--async (consult--fd-make-builder nil) d "txt")))
      (should (eq 'finished (car r)))
      (should (equal '("c.txt" "src/a.txt" "src/deep/b.txt") (sort (copy-sequence (cdr r)) #'string<))))))

(ert-deftest thither-int-consult-find ()
  (thither-int--with-tree d
    (let ((r (thither-int--async (consult--find-make-builder nil) d "b.txt")))
      (should (eq 'finished (car r)))
      (should (cl-some (lambda (l) (string-match-p "src/deep/b\\.txt" l)) (cdr r))))))

(ert-deftest thither-int-fallback-advice ()
  "consult-ripgrep / consult-fd turn into grep / find when the host lacks the tool."
  (thither-int--with-tree d
    (let ((default-directory d) called)
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (cmd &optional remote) (if remote nil (locate-file cmd exec-path))))
                ((symbol-function 'consult-grep) (lambda (&rest _) (setq called 'grep)))
                ((symbol-function 'consult-find) (lambda (&rest _) (setq called 'find))))
        (let ((orig (lambda (&rest _) (setq called 'orig))))
          (funcall (thither--fallback-advice "rg" #'consult-grep) orig)
          (should (eq called 'grep))
          (funcall (thither--fallback-advice "fd" #'consult-find) orig)
          (should (eq called 'find))))
      (let ((default-directory temporary-file-directory) called)
        (funcall (thither--fallback-advice "rg" #'consult-grep) (lambda (&rest _) (setq called 'orig)))
        (should (eq called 'orig))))))

(ert-deftest thither-int-completion-table ()
  "The completion table that vertico uses on every minibuffer keystroke."
  (thither-fs-test--with-dir d
    (dotimes (i 30) (write-region "" nil (format "%sfile-%02d.txt" d i) nil 'silent))
    (make-directory (concat d "folder"))
    (let* ((all (completion-all-completions (concat d "fil") #'completion-file-name-table nil
                                            (length (concat d "fil")))))
      (ignore all))
    (should (= 30 (length (file-name-all-completions "file-" d))))
    (should (member "folder/" (file-name-all-completions "fo" d)))
    (should (equal "file-" (file-name-completion "fi" d)))
    (let ((t0 (float-time)))
      (dotimes (_ 50) (file-name-all-completions "fi" d))
      ;; served from the cache: 50 keystrokes must not be 50 round trips
      (should (< (- (float-time) t0) 0.5)))))

(ert-deftest thither-int-project-find-file ()
  (thither-fs-test--with-dir d
    (skip-unless (string-match-p "git" (thither-fs-test--sh "command -v git || true")))
    (thither-fs-test--sh (format "cd %s && git init -q . && mkdir -p a/b && echo 1 > a/b/c.el && echo 2 > top.el && git add . && git -c user.email=a@b -c user.name=n commit -qm i"
                             (file-local-name d)))
    (let* ((default-directory (concat d "a/b/")) (pr (project-current)))
      (should pr)
      (should (member (concat d "top.el") (project-files pr)))
      (should (equal (concat d) (file-name-as-directory (project-root pr)))))))

(provide 'thither-integration-test)
;;; thither-integration-test.el ends here
