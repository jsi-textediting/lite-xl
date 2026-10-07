;;; lxs-fs-test.el --- ERT tests for lxs-fs.el and lxs-proc.el  -*- lexical-binding: t; no-byte-compile: t; -*-

;; Run like lxs-test.el (needs LXS_SERVER; every host name maps to it):
;;   LXS_SERVER="$HOME/lxs-build/lite-xl-server --datadir $PWD/data --stdio" \
;;     emacs -Q --batch -L emacs -l emacs/test/lxs-fs-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'lxs-fs)
(require 'lxs-proc)
(require 'dired)
(require 'compile)
(require 'grep)

(defun lxs-fs-test--command ()
  (let ((s (getenv "LXS_SERVER"))) (and s (split-string-and-unquote s))))

(setq lxs-command-function (lambda (_host) (lxs-fs-test--command)))
(lxs-fs-enable)

(defvar lxs-fs-test--host "t")

(defun lxs-fs-test--sh (script)
  (lxs--text (plist-get (lxs-exec (lxs-connection lxs-fs-test--host) (list "sh" "-c" script))
                          :stdout)))

(defmacro lxs-fs-test--with-dir (var &rest body)
  "Run BODY with VAR bound to a fresh remote directory name (with slash)."
  (declare (indent 1))
  `(progn
     (unless (lxs-fs-test--command) (ert-skip "LXS_SERVER not set"))
     (let* ((local (string-trim (lxs-fs-test--sh "mktemp -d")))
            (,var (format "/lxs:%s:%s/" lxs-fs-test--host local)))
       (unwind-protect (progn ,@body)
         (ignore-errors (lxs-fs-test--sh (format "rm -rf %s" local)))))))

(defun lxs-fs-test--slurp (file)
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

;;;; Names (no server)

(ert-deftest lxs-fs-expand-names ()
  (should (equal "/lxs:h:/x/y/b" (expand-file-name "a/../b" "/lxs:h:/x/y")))
  (should (equal "/lxs:h:/x/y/b" (expand-file-name "b" "/lxs:h:/x/y/")))
  (should (equal "/lxs:h:/b" (expand-file-name "/lxs:h:/a/./../b")))
  (should (equal "/lxs:h:/" (expand-file-name "/lxs:h:/a/../..")))
  (should (equal "/lxs:h:/a/b/" (expand-file-name "/lxs:h:/a//b/")))
  (should (equal "/etc/passwd" (expand-file-name "/etc/passwd" "/lxs:h:/x"))))

(ert-deftest lxs-fs-remote-p ()
  (should (equal "/lxs:h:" (file-remote-p "/lxs:h:/a/b")))
  (should (equal "h" (file-remote-p "/lxs:h:/a/b" 'host)))
  (should (equal "lxs" (file-remote-p "/lxs:h:/a/b" 'method)))
  (should (equal "/a/b" (file-remote-p "/lxs:h:/a/b" 'localname)))
  (should (equal "/a/b" (file-local-name "/lxs:h:/a/b")))
  (should-not (file-remote-p "/tmp/x"))
  (should (equal "/lxs:h:/a/" (file-name-directory "/lxs:h:/a/b")))
  (should (equal "b" (file-name-nondirectory "/lxs:h:/a/b")))
  (should (equal "/lxs:h:/a/b/" (file-name-as-directory "/lxs:h:/a/b"))))

(ert-deftest lxs-fs-mode-string ()
  (should (equal "-rw-r--r--" (lxs--mode-string "file" #o644)))
  (should (equal "drwxr-xr-x" (lxs--mode-string "dir" #o755)))
  (should (equal "-rwsr-xr-x" (lxs--mode-string "file" #o4755)))
  (should (equal "drwxrwxrwt" (lxs--mode-string "dir" #o1777))))

;;;; Files

(ert-deftest lxs-fs-write-read ()
  (lxs-fs-test--with-dir d
    (let ((f (concat d "a.txt")))
      (should-not (file-exists-p f))
      (write-region "héllo\nwörld\n" nil f)
      (should (file-exists-p f))
      (should (file-regular-p f))
      (should-not (file-directory-p f))
      (should (equal "héllo\nwörld\n" (lxs-fs-test--slurp f)))
      (should (= 14 (file-attribute-size (file-attributes f))))
      (should (equal "-rw" (substring (file-attribute-modes (file-attributes f)) 0 3)))
      (should (file-readable-p f))
      (should (file-writable-p f))
      (should (file-directory-p d))
      (should (file-writable-p (concat d "new-file")))
      (with-temp-buffer
        (insert "x")
        (write-region (point-min) (point-max) f t 'silent))
      (should (equal "héllo\nwörld\nx" (lxs-fs-test--slurp f)))
      (should-error (lxs-fs-test--slurp (concat d "missing")) :type 'file-missing)
      (should-error (lxs-fs-test--slurp d) :type 'file-error))))

(ert-deftest lxs-fs-insert-range-binary ()
  (lxs-fs-test--with-dir d
    (let ((f (concat d "b.bin")) (data (apply #'unibyte-string (number-sequence 0 255))))
      (let ((coding-system-for-write 'no-conversion)) (write-region data nil f nil 'silent))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally f)
        (should (equal data (buffer-string))))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally f nil 10 20)
        (should (equal (substring data 10 20) (buffer-string)))))))

(ert-deftest lxs-fs-directories ()
  (lxs-fs-test--with-dir d
    (make-directory (concat d "x/y/z") t)
    (write-region "1" nil (concat d "x/one") nil 'silent)
    (write-region "22" nil (concat d "x/two.txt") nil 'silent)
    (let ((x (concat d "x")))
      (should (equal '("." ".." "one" "two.txt" "y") (directory-files x nil nil)))
      (should (equal '("one" "two.txt" "y") (directory-files x nil directory-files-no-dot-files-regexp)))
      (should (equal (list (concat d "x/two.txt")) (directory-files x t "\\.txt\\'")))
      (should (equal '("one" "two.txt") (directory-files x nil "\\`[ot]")))
      (let ((attrs (directory-files-and-attributes x nil "\\`[a-z]")))
        (should (equal '("one" "two.txt" "y") (mapcar #'car attrs)))
        (should (= 2 (file-attribute-size (cdr (assoc "two.txt" attrs)))))
        (should (eq t (file-attribute-type (cdr (assoc "y" attrs))))))
      (should (member "y/" (file-name-all-completions "" x)))
      (should (equal '("two.txt") (file-name-all-completions "tw" x)))
      (should (equal "two.txt" (file-name-completion "tw" x)))
      (should (equal "one" (file-name-completion "o" (concat d "x/y/.."))))
      (should (equal 2 (length (directory-files-recursively d ""))))
      (should-error (directory-files (concat d "nope")) :type 'file-error)
      (should-error (make-directory (concat d "x")) :type 'file-already-exists)
      (make-directory (concat d "x") t))))

(ert-deftest lxs-fs-mutations ()
  (lxs-fs-test--with-dir d
    (let ((a (concat d "a")) (b (concat d "b")) (c (concat d "c")))
      (write-region "A" nil a nil 'silent)
      (copy-file a b)
      (should (equal "A" (lxs-fs-test--slurp b)))
      (should-error (copy-file a b) :type 'file-already-exists)
      (write-region "A2" nil a nil 'silent)
      (copy-file a b t)
      (should (equal "A2" (lxs-fs-test--slurp b)))
      (rename-file b c)
      (should-not (file-exists-p b))
      (should (equal "A2" (lxs-fs-test--slurp c)))
      (make-symbolic-link a (concat d "ln"))
      (should (equal (file-local-name a) (file-symlink-p (concat d "ln"))))
      (should (equal (file-truename a) (file-truename (concat d "ln"))))
      (set-file-modes a #o600)
      (should (= #o600 (file-modes a)))
      (delete-file c)
      (should-not (file-exists-p c))
      (delete-file c)                   ; missing: silently ignored
      (make-directory (concat d "sub/deeper") t)
      (write-region "x" nil (concat d "sub/deeper/f") nil 'silent)
      (should-error (delete-directory (concat d "sub")) :type 'file-error)
      (delete-directory (concat d "sub") t)
      (should-not (file-exists-p (concat d "sub"))))))

(ert-deftest lxs-fs-copy-local-remote ()
  (lxs-fs-test--with-dir d
    (let ((loc (make-temp-file "lxs-local")) (r (concat d "r")))
      (unwind-protect
          (progn
            (let ((coding-system-for-write 'no-conversion))
              (write-region "local data\n" nil loc nil 'silent))
            (copy-file loc r)
            (should (equal "local data\n" (lxs-fs-test--slurp r)))
            (delete-file loc)
            (copy-file r loc)
            (should (equal "local data\n" (lxs-fs-test--slurp loc))))
        (ignore-errors (delete-file loc))))))

;;;; Visiting files

(ert-deftest lxs-fs-find-file-save ()
  (lxs-fs-test--with-dir d
    (let ((f (concat d "v.txt")))
      (write-region "one\n" nil f nil 'silent)
      (let ((buf (find-file-noselect f)))
        (unwind-protect
            (with-current-buffer buf
              (should (equal f buffer-file-name))
              (should (equal "one\n" (buffer-string)))
              (should-not (buffer-modified-p))
              (should (verify-visited-file-modtime))
              (goto-char (point-max))
              (insert "two\n")
              (save-buffer)
              (should-not (buffer-modified-p))
              (should (equal "one\ntwo\n" (lxs-fs-test--slurp f)))
              (should (verify-visited-file-modtime))
              ;; the file changes behind our back
              (lxs-fs-test--sh (format "printf external > %s"
                                       (shell-quote-argument (file-local-name f))))
              (should-not (verify-visited-file-modtime))
              (insert "three\n")
              (let ((err (should-error
                          (write-region nil nil f nil t) :type 'file-error)))
                (should (string-match-p "changed" (format "%S" err))))
              (revert-buffer t t)
              (should (equal "external" (buffer-string)))
              (should (verify-visited-file-modtime)))
          (kill-buffer buf))))))

(ert-deftest lxs-fs-new-file ()
  (lxs-fs-test--with-dir d
    (let* ((f (concat d "new.txt")) (buf (find-file-noselect f)))
      (unwind-protect
          (with-current-buffer buf
            (insert "fresh")
            (save-buffer)
            (should (equal "fresh
" (lxs-fs-test--slurp f))))
        (kill-buffer buf)))))

;;;; Dired

(ert-deftest lxs-fs-dired ()
  (lxs-fs-test--with-dir d
    (write-region "x" nil (concat d "file one.txt") nil 'silent)
    (make-directory (concat d "subdir"))
    (let ((buf (dired-noselect d)))
      (unwind-protect
          (with-current-buffer buf
            (let ((names nil))
              (goto-char (point-min))
              (while (not (eobp))
                (let ((n (ignore-errors (dired-get-filename 'no-dir t))))
                  (when n (push n names)))
                (forward-line 1))
              (should (member "file one.txt" names))
              (should (member "subdir" names)))
            (goto-char (point-min))
            (should (search-forward "file one.txt" nil t))
            (should (equal (concat d "file one.txt") (dired-get-filename))))
        (kill-buffer buf)))))

;;;; Processes

(ert-deftest lxs-proc-process-file ()
  (lxs-fs-test--with-dir d
    (let ((default-directory d))
      (with-temp-buffer
        (should (eq 0 (process-file "pwd" nil t)))
        (should (equal (concat (directory-file-name (file-local-name d)) "\n") (buffer-string))))
      (with-temp-buffer
        (should (eq 3 (process-file "sh" nil t nil "-c" "echo out; echo err >&2; exit 3")))
        (should (equal "out\nerr\n" (buffer-string))))
      (with-temp-buffer
        (should (eq 0 (process-file "sh" nil '(t nil) nil "-c" "echo out; echo err >&2")))
        (should (equal "out\n" (buffer-string))))
      (with-temp-buffer
        (write-region "from infile" nil (concat d "in") nil 'silent)
        (should (eq 0 (process-file "cat" (concat d "in") t)))
        (should (equal "from infile" (buffer-string))))
      (with-temp-buffer
        (should (eq 0 (process-file-shell-command "echo $((1+2)) é" nil t)))
        (should (equal "3 é\n" (buffer-string))))
      (should (equal '("x") (process-lines "echo" "x")))
      (should (equal "hi" (string-trim (shell-command-to-string "echo hi")))))))

(defun lxs-fs-test--wait (pred &optional timeout)
  (let ((deadline (+ (float-time) (or timeout 15))))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall pred)))

(ert-deftest lxs-proc-make-process ()
  (lxs-fs-test--with-dir d
    (let* ((default-directory d) out events
           (proc (make-process :name "t" :command '("sh" "-c" "echo one; sleep 0.2; echo two é; exit 2")
                               :connection-type 'pipe :noquery t :file-handler t
                               :filter (lambda (_p s) (push s out))
                               :sentinel (lambda (_p e) (push e events)))))
      (should (process-live-p proc))
      (should (lxs-fs-test--wait (lambda () events)))
      (should (equal "one\ntwo é\n" (apply #'concat (reverse out))))
      (should (equal '("exited abnormally with code 2\n") events))
      (should (eq 'exit (process-status proc)))
      (should (= 2 (process-exit-status proc)))
      (should-not (process-live-p proc)))))

(ert-deftest lxs-proc-make-process-buffer-stderr-stdin ()
  (lxs-fs-test--with-dir d
    (let* ((default-directory d)
           (buf (generate-new-buffer " *lxs-test*")) (err (generate-new-buffer " *lxs-err*"))
           events
           (proc (make-process :name "cat" :command '("sh" "-c" "cat; echo problem >&2")
                               :buffer buf :stderr err :noquery t :file-handler t
                               :sentinel (lambda (_p e) (push e events)))))
      (unwind-protect
          (progn
            (process-send-string proc "line 1\n")
            (process-send-string proc "ünï\n")
            (process-send-eof proc)
            (should (lxs-fs-test--wait (lambda () events)))
            (should (equal '("finished\n") events))
            (should (equal "line 1\nünï\n" (with-current-buffer buf (buffer-string))))
            (should (equal "problem\n" (with-current-buffer err (buffer-string)))))
        (kill-buffer buf) (kill-buffer err)))))

(ert-deftest lxs-proc-delete-process ()
  (lxs-fs-test--with-dir d
    (let* ((default-directory d)
           (proc (make-process :name "sleeper" :command '("sleep" "30") :noquery t
                               :file-handler t)))
      (should (process-live-p proc))
      (delete-process proc)
      (should-not (process-live-p proc))
      ;; the server child is gone and the connection still works
      (should (lxs-fs-test--wait
               (lambda () (string-empty-p (string-trim (lxs-fs-test--sh "pgrep -x -f 'sleep 30' || true")))))))))

(ert-deftest lxs-proc-large-output-and-many-processes ()
  (lxs-fs-test--with-dir d
    (let ((default-directory d) (n 0) (done 0))
      (dotimes (_ 5)
        (make-process :name "big" :command '("sh" "-c" "head -c 2000000 /dev/zero | tr '\\0' x")
                      :noquery t :file-handler t
                      :filter (lambda (_p s) (cl-incf n (length s)))
                      :sentinel (lambda (_p _e) (cl-incf done))))
      (should (lxs-fs-test--wait (lambda () (= done 5)) 60))
      (should (= 10000000 n)))))

(ert-deftest lxs-proc-executable-find ()
  (lxs-fs-test--with-dir d
    ;; the host's PATH is searched, not the local `exec-path'
    (let ((default-directory d) (exec-path '("c:/Windows/system32" "/nonexistent")))
      (should (member "/bin" (exec-path)))
      (should (equal "/bin/sh" (replace-regexp-in-string "\\`/usr" "" (executable-find "sh" t))))
      (should-not (executable-find "no-such-program-xyz" t)))))

(ert-deftest lxs-proc-vc-and-project ()
  (lxs-fs-test--with-dir d
    (skip-unless (string-match-p "git" (lxs-fs-test--sh "command -v git || true")))
    (lxs-fs-test--sh (format "cd %s && git init -q . && echo a > a.txt && mkdir s && echo b > s/b.txt && git add . && git -c user.email=a@b -c user.name=n commit -qm init"
                             (file-local-name d)))
    (let* ((default-directory (concat d "s/"))
           (pr (project-current)))
      (should pr)
      (should (equal d (file-name-as-directory (project-root pr))))
      (should (equal (list (concat d "a.txt") (concat d "s/b.txt"))
                     (sort (project-files pr) #'string<))))))


;;;; Review fixes

(ert-deftest lxs-fs-connect-from-remote-buffer ()
  "Reconnecting while default-directory is an lxs name must not recurse."
  (lxs-fs-test--with-dir d
    (let ((default-directory d))
      (lxs-disconnect lxs-fs-test--host)
      (should (file-exists-p d))
      (should (lxs-alive-p (gethash lxs-fs-test--host lxs--connections)))
      (with-temp-buffer
        (should (eq 0 (process-file "true")))))))

(ert-deftest lxs-fs-completion-ignored-extensions ()
  (lxs-fs-test--with-dir d
    (dolist (n '("notes.org" "x.c" "x.o" "only.o" "run.log.txt"))
      (write-region "" nil (concat d n) nil 'silent))
    ;; ".o" inside ".org", ".lo" inside ".log" must not hide files
    (should (equal "notes.org" (file-name-completion "notes" d)))
    (should (equal "run.log.txt" (file-name-completion "run" d)))
    ;; an ignored suffix loses only when something else matches
    (should (equal "x.c" (file-name-completion "x." d)))
    (should (equal "only.o" (file-name-completion "only" d)))
    (should (eq t (file-name-completion "x.o" d)))   ; exact and unique, as in Emacs
    (should (equal '("x.c" "x.o") (sort (file-name-all-completions "x." d) #'string<)))))

(ert-deftest lxs-fs-permissions ()
  (lxs-fs-test--with-dir d
    (skip-unless (not (equal "0" (string-trim (lxs-fs-test--sh "id -u")))))
    (let ((f (concat d "p")))
      (write-region "" nil f nil 'silent)
      (set-file-modes f #o644)
      (should (file-readable-p f))
      (should (file-writable-p f))
      (should-not (file-executable-p f))
      (set-file-modes f #o444)
      (should (file-readable-p f))
      (should-not (file-writable-p f))
      (set-file-modes f #o000)
      (should-not (file-readable-p f))
      (should-not (file-writable-p f))
      (set-file-modes f #o755)
      (should (file-executable-p f))
      ;; a file of someone else is judged by its "other" bits only
      (lxs-fs-test--sh (format "cd %s && echo x > rootish" (file-local-name d)))
      (should (file-accessible-directory-p d))
      (should-not (file-accessible-directory-p f)))))

(ert-deftest lxs-proc-process-file-file-destination ()
  (lxs-fs-test--with-dir d
    (let ((default-directory d) (out (make-temp-file "lxs-out")))
      (unwind-protect
          (progn
            (should (eq 0 (process-file "echo" nil (list :file out) nil "to a file")))
            (should (equal "to a file\n" (lxs-fs-test--slurp out)))
            (with-temp-buffer
              (should (eq 0 (process-file "sh" nil (list t out) nil "-c" "echo o; echo e >&2")))
              (should (equal "o\n" (buffer-string)))
              (should (equal "e\n" (lxs-fs-test--slurp out)))))
        (delete-file out)))))

(ert-deftest lxs-proc-non-lxs-arguments-fall-through ()
  "The global advice must leave integers, buffers and names alone."
  (should (= -1 (signal-process 99999999 'INT)))   ; integer pids reach the real function
  (with-temp-buffer
    ;; Emacs' own error for a buffer without a process, not a type error from us
    (should (string-match-p "has no process"
                            (cadr (should-error (process-status (current-buffer)))))))
  (should-not (process-status "no-such-process"))
  (should-not (lxs--proc-of 1234))
  (should-not (lxs--proc-of (current-buffer)))
  (let ((p (start-process "plain" nil "sleep" "5")))
    (unwind-protect
        (progn (should (eq 'run (process-status p)))
               (should (eq (lxs--proc-of p) p)))
      (delete-process p))))

(ert-deftest lxs-proc-local-shell-is-mapped ()
  "A Windows style shell and switch run as sh -c on the host."
  (lxs-fs-test--with-dir d
    (let ((default-directory d)
          (shell-file-name "C:/Windows/System32/cmd.exe")
          (shell-command-switch "/c"))
      (with-temp-buffer
        (should (eq 0 (process-file-shell-command "echo mapped" nil t)))
        (should (equal "mapped\n" (buffer-string))))
      (let (out)
        (let ((p (make-process :name "sh" :command (list shell-file-name shell-command-switch "echo async")
                               :noquery t :file-handler t
                               :filter (lambda (_p s) (push s out)))))
          (should (lxs-fs-test--wait (lambda () (not (process-live-p p)))))
          (should (equal "async\n" (apply #'concat (reverse out)))))))))

(ert-deftest lxs-proc-kill-entry-points ()
  (lxs-fs-test--with-dir d
    (let ((default-directory d))
      (dolist (kill (list #'kill-process #'interrupt-process #'quit-process))
        (let ((p (make-process :name "s" :command '("sleep" "41") :noquery t :file-handler t)))
          (should (process-live-p p))
          (funcall kill p)
          (should (lxs-fs-test--wait (lambda () (not (process-live-p p)))))))
      (should (lxs-fs-test--wait
               (lambda () (string-empty-p (string-trim (lxs-fs-test--sh "pgrep -x -f 'sleep 41' || true")))))))))

(ert-deftest lxs-proc-kill-buffer-stops-remote-program ()
  (lxs-fs-test--with-dir d
    (let* ((default-directory d)
           (buf (generate-new-buffer " *lxs-kill*"))
           (p (make-process :name "s" :buffer buf :command '("sleep" "42") :noquery t
                            :file-handler t)))
      (should (process-live-p p))
      (kill-buffer buf)
      (should (lxs-fs-test--wait
               (lambda () (string-empty-p (string-trim (lxs-fs-test--sh "pgrep -x -f 'sleep 42' || true")))))))))

(ert-deftest lxs-proc-final-bytes-are-delivered ()
  "An incomplete UTF-8 sequence at the very end must not be dropped."
  (lxs-fs-test--with-dir d
    (let* ((default-directory d) out done
           (p (make-process :name "t" :command '("sh" "-c" "printf 'ab\\303'")
                            :noquery t :file-handler t
                            :filter (lambda (_p s) (push s out))
                            :sentinel (lambda (_p _e) (setq done t)))))
      (ignore p)
      (should (lxs-fs-test--wait (lambda () done)))
      (let ((s (apply #'concat (reverse out))))
        (should (string-prefix-p "ab" s))
        (should (> (length s) 2))))))


(ert-deftest lxs-proc-compile-and-shell-command ()
  (lxs-fs-test--with-dir d
    (let ((default-directory d) (compilation-ask-about-save nil) (compilation-scroll-output nil))
      ;; synchronous M-!
      (should (equal "sync ok\n" (shell-command-to-string "echo sync ok")))
      (with-temp-buffer
        (shell-command "echo in-buffer" (current-buffer))
        (should (equal "in-buffer\n" (buffer-string))))
      ;; M-x compile (compilation-start -> start-file-process)
      (let* ((buf (compile "echo compiling; exit 3")) (proc (get-buffer-process buf)))
        (unwind-protect
            (progn
              (should (lxs-fs-test--wait (lambda () (not (process-live-p proc)))))
              (should (lxs-fs-test--wait
                       (lambda () (with-current-buffer buf
                                    (string-match-p "exited abnormally with code 3" (buffer-string))))))
              (with-current-buffer buf
                (should (string-match-p "compiling" (buffer-string)))
                (should (equal d default-directory))))
          (kill-buffer buf)))
      ;; M-x grep (same machinery, with a remote default-directory)
      (write-region "needle here\nother\n" nil (concat d "g.txt") nil 'silent)
      (let* ((buf (grep "grep --color=never -nH needle g.txt")) (proc (get-buffer-process buf)))
        (unwind-protect
            (progn
              (should (lxs-fs-test--wait (lambda () (not (process-live-p proc)))))
              (should (lxs-fs-test--wait
                       (lambda () (with-current-buffer buf (string-match-p "g\.txt:1:needle here" (buffer-string)))))))
          (kill-buffer buf))))))

;;;; Review fixes, round 2

(ert-deftest lxs-fs-host-root-names ()
  (should (equal "/lxs:h:/" (directory-file-name "/lxs:h:/")))
  (should (equal "/lxs:h:/" (directory-file-name "/lxs:h://")))
  (should (equal "/lxs:h:/a" (directory-file-name "/lxs:h:/a/")))
  (should (equal "/lxs:h:/" (file-name-directory (directory-file-name "/lxs:h:/"))))
  (should (equal "/lxs:h:" (file-name-directory "/lxs:h:")))
  (should (equal "/lxs:h:/a/" (file-name-directory "/lxs:h:/a/b"))))

(ert-deftest lxs-fs-substitute-in-file-name ()
  (should (equal "/lxs:h:/etc" (substitute-in-file-name "/lxs:h:/home/u//etc")))
  (should (equal "/lxs:h:~/x" (substitute-in-file-name "/lxs:h:/home/u/~/x")))
  (should (equal "/lxs:k:/b" (substitute-in-file-name "/lxs:h:/a//lxs:k:/b")))
  (should (equal "/lxs:h:/a/b" (substitute-in-file-name "/lxs:h:/a/b"))))

(ert-deftest lxs-setup-posix-quote ()
  (require 'lxs-setup)
  (should (equal "lite-xl-server" (lxs--posix-quote "lite-xl-server")))
  (should (equal "~/bin/lxs" (lxs--posix-quote "~/bin/lxs")))
  (should (equal "'/opt/my dir/lxs'" (lxs--posix-quote "/opt/my dir/lxs")))
  (should (equal "'it'\\''s'" (lxs--posix-quote "it's")))
  (should (equal "''" (lxs--posix-quote "")))
  (let ((lxs-host-options '(("remote-box" :server "/opt/my dir/lxs" :server-args ("--root" "$HOME")))))
    (should (equal '("'/opt/my dir/lxs'" "--root" "'$HOME'" "--stdio")
                   (last (lxs-launch-command "remote-box") 4)))))

(ert-deftest lxs-fs-write-excl-existing ()
  (lxs-fs-test--with-dir d
    (let ((f (concat d "e")))
      (write-region "x" nil f nil 'silent)
      (should-error (write-region "y" nil f nil 'silent nil 'excl) :type 'file-already-exists)
      (should (equal "x" (lxs-fs-test--slurp f)))
      ;; make-temp-file creates remote temp files with 'excl
      (should (string-prefix-p (concat d "tmp") (make-temp-file (concat d "tmp")))))))

(ert-deftest lxs-fs-write-append ()
  (lxs-fs-test--with-dir d
    (let ((f (concat d "ap")))
      (write-region "one\n" nil f t 'silent)
      (write-region "two\n" nil f t 'silent)
      (should (equal "one\ntwo\n" (lxs-fs-test--slurp f)))
      ;; a failing read must not truncate the file (root reads anyway)
      (unless (equal "0" (string-trim (lxs-fs-test--sh "id -u")))
        (lxs-fs-test--sh (format "chmod 200 %s" (shell-quote-argument (file-local-name f))))
        (should-error (write-region "three\n" nil f t 'silent) :type 'file-error)
        (lxs-fs-test--sh (format "chmod 600 %s" (shell-quote-argument (file-local-name f))))
        (should (equal "one\ntwo\n" (lxs-fs-test--slurp f)))))))

(ert-deftest lxs-fs-save-precious ()
  (lxs-fs-test--with-dir d
    (let ((f (concat d "p.txt")) (file-precious-flag t))
      (write-region "one\n" nil f nil 'silent)
      (let ((buf (find-file-noselect f)))
        (unwind-protect
            (with-current-buffer buf
              (goto-char (point-max))
              (insert "two\n")
              (save-buffer)
              (should-not (buffer-modified-p))
              (should (equal f buffer-file-name))
              (should (verify-visited-file-modtime))
              (should (equal "one\ntwo\n" (lxs-fs-test--slurp f)))
              (insert "three\n")
              (save-buffer)
              (should-not (buffer-modified-p))
              (should (equal "one\ntwo\nthree\n" (lxs-fs-test--slurp f))))
          (kill-buffer buf))))))

(ert-deftest lxs-proc-process-file-missing-program ()
  (lxs-fs-test--with-dir d
    (let ((default-directory d))
      (should-error (process-file "no-such-program-xyz" nil nil nil) :type 'file-missing))))

(ert-deftest lxs-proc-set-process-coding-system ()
  (lxs-fs-test--with-dir d
    (let* ((default-directory d) out done
           (p (make-process :name "c" :command '("sh" "-c" "read x; printf '\\351\\n'")
                            :noquery t :file-handler t
                            :filter (lambda (_p s) (push s out))
                            :sentinel (lambda (_p _e) (setq done t)))))
      (set-process-coding-system p 'latin-1 'latin-1)
      (should (eq 'latin-1 (car (process-coding-system p))))
      (process-send-string p "go\n")
      (should (lxs-fs-test--wait (lambda () done)))
      (should (equal "\u00e9\n" (apply #'concat (reverse out)))))))

(ert-deftest lxs-proc-connection-lost ()
  "A bridged process finishes when its connection goes away."
  (lxs-fs-test--with-dir d
    (let* ((default-directory d) event
           (p (make-process :name "s" :command '("sleep" "43") :noquery t :file-handler t
                            :sentinel (lambda (_p e) (setq event e)))))
      (should (lxs-fs-test--wait (lambda () (lxs-exec-handle-stream (process-get p 'lxs-handle)))))
      (lxs-disconnect lxs-fs-test--host)
      (should (lxs-fs-test--wait (lambda () event)))
      (should (string-match-p "exited abnormally with code 255" event))
      (should-not (process-live-p p))
      (should (eq 'exit (process-status p)))
      (delete-process p))))

(provide 'lxs-fs-test)
;;; lxs-fs-test.el ends here
