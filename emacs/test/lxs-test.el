;;; lxs-test.el --- ERT tests for lxs.el  -*- lexical-binding: t; no-byte-compile: t; -*-

;; Run (from the repository root, on a POSIX host with a built server):
;;   LXS_SERVER="$HOME/lxs-build/lite-xl-server --datadir $PWD/data --stdio" \
;;     emacs -Q --batch -L emacs -l emacs/test/lxs-test.el -f ert-run-tests-batch-and-exit
;; Codec tests need no server.  Server tests are skipped without LXS_SERVER.

(require 'ert)
(require 'lxs)

;;;; Codec

(defun lxs-test--roundtrip (x) (lxs--decode (lxs--encode x)))

(ert-deftest lxs-codec-integers ()
  (dolist (n (list 0 1 127 128 255 256 65535 65536 #xffffffff #x100000000
                   (1- (ash 1 63)) (ash 1 63) (1- (ash 1 64))
                   -1 -32 -33 -128 -129 -32768 -32769 (- (ash 1 31))
                   (1- (- (ash 1 31))) (- (ash 1 63))))
    (should (= n (lxs-test--roundtrip n)))))

(ert-deftest lxs-codec-wire-bytes ()
  (should (equal (lxs--encode 5) "\5"))
  (should (equal (lxs--encode -1) "\377"))
  (should (equal (lxs--encode 200) "\314\310"))
  (should (equal (lxs--encode "abc") "\243abc"))
  (should (equal (lxs--encode (unibyte-string 255 0)) "\304\2\377\0"))
  (should (equal (lxs--encode t) "\303"))
  (should (equal (lxs--encode :false) "\302"))
  (should (equal (lxs--encode []) "\220")))

(ert-deftest lxs-codec-floats ()
  (dolist (x (list 0.0 1.0 -1.5 3.141592653589793 1.0e300 -2.5e-300 5e-324 1.0e+INF -1.0e+INF))
    (should (= x (lxs-test--roundtrip x))))
  (should (isnan (lxs-test--roundtrip 0.0e+NaN)))
  (should (< (copysign 1.0 (lxs-test--roundtrip -0.0)) 0))
  (should (> (copysign 1.0 (lxs-test--roundtrip 0.0)) 0))
  ;; float32 on decode
  (should (= 1.5 (lxs--decode "\312\77\300\0\0"))))

(ert-deftest lxs-codec-strings ()
  (should (equal "héllo ✓" (lxs-test--roundtrip "héllo ✓")))
  (should (multibyte-string-p (lxs-test--roundtrip "héllo ✓")))
  (let* ((raw (apply #'unibyte-string (number-sequence 0 255)))
         (back (lxs-test--roundtrip raw)))
    (should (equal raw back))
    (should-not (multibyte-string-p back)))
  (let ((long (make-string 70000 ?x)))
    (should (equal long (lxs-test--roundtrip long)))
    (should (equal (concat long "é") (lxs-test--roundtrip (concat long "é"))))))

(ert-deftest lxs-codec-containers ()
  (let ((h (lxs-test--roundtrip
            `(("a" . 1) (b . [1 2 "x"]) (:c . (("n" . t))) ("skipped" . nil) ("f" . :false)))))
    (should (= 1 (gethash "a" h)))
    (should (equal [1 2 "x"] (gethash "b" h)))
    (should (eq t (gethash "n" (gethash "c" h))))
    (should (eq :false (gethash "f" h)))
    (should (= 4 (hash-table-count h))))
  (should (= 20 (length (lxs-test--roundtrip (make-vector 20 1)))))
  (should (= 70000 (length (lxs-test--roundtrip (make-vector 70000 1))))))

(ert-deftest lxs-codec-hash-table-input ()
  (let ((in (make-hash-table :test 'equal)))
    (dotimes (i 40) (puthash (format "k%d" i) i in))
    (let ((out (lxs-test--roundtrip in)))
      (should (= 40 (hash-table-count out)))
      (should (= 39 (gethash "k39" out))))))

;;;; Framing

(ert-deftest lxs-frame-reassembly ()
  "Feed two frames one byte at a time, then both at once."
  (let* ((conn (lxs--make-conn))
         (got nil)
         (f1 (lxs--frame '(("id" . 1) ("ok" . "one"))))
         (f2 (lxs--frame `(("id" . 2) ("ok" . ,(unibyte-string 0 1 2 255)))))
         (lxs-test--cbs nil))
    (puthash 1 (lambda (ok _e) (push ok got)) (lxs-conn-pending conn))
    (puthash 2 (lambda (ok _e) (push ok got)) (lxs-conn-pending conn))
    (dolist (b (append (concat f1 f2) nil))
      (lxs--filter conn (unibyte-string b)))
    (should (equal (reverse got) (list "one" (unibyte-string 0 1 2 255))))
    (setq got nil)
    (puthash 1 (lambda (ok _e) (push ok got)) (lxs-conn-pending conn))
    (puthash 2 (lambda (ok _e) (push ok got)) (lxs-conn-pending conn))
    (lxs--filter conn (concat f1 f2))
    (should (= 2 (length got)))
    (should (= 0 (lxs-conn-nbytes conn)))))

;;;; Server

(defvar lxs-test--conn nil)

(defun lxs-test--command ()
  (let ((s (getenv "LXS_SERVER")))
    (and s (split-string-and-unquote s))))

(defmacro lxs-test--with-server (&rest body)
  (declare (indent 0))
  `(let ((cmd (lxs-test--command)))
     (unless cmd (ert-skip "LXS_SERVER not set"))
     (let* ((conn (lxs-connect cmd))
            (dir (string-trim (plist-get (lxs-exec conn '("mktemp" "-d")) :stdout))))
       (unwind-protect (progn ,@body)
         (ignore-errors (lxs-exec conn (list "rm" "-rf" dir)))
         (lxs-close conn)))))

(defun lxs-test--sh (conn script)
  "Run SCRIPT with sh on the server, return stdout."
  (plist-get (lxs-exec conn (list "sh" "-c" script)) :stdout))

(ert-deftest lxs-server-hello-ping ()
  (lxs-test--with-server
    (should (= 1 (gethash "proto_version" (lxs-conn-hello conn))))
    (should (lxs-has-cap conn "fs"))
    (should (equal "x" (lxs-call-sync conn "ping" '(("data" . "x")))))))

(ert-deftest lxs-server-errors ()
  (lxs-test--with-server
    (let ((e (should-error (lxs-call-sync conn "stat" `(("path" . ,(concat dir "/nope"))))
                           :type 'lxs-error)))
      (should (equal "ENOENT" (cadr e))))
    (should (null (lxs-stat conn (concat dir "/nope"))))
    (should (equal "unknown_op" (cadr (should-error (lxs-call-sync conn "bogus")
                                                    :type 'lxs-error))))))

(ert-deftest lxs-server-async ()
  (lxs-test--with-server
    (let (results)
      (dotimes (i 20)
        (lxs-call conn "ping" `(("data" . ,i)) (lambda (ok _e) (push ok results))))
      (lxs--wait conn (lambda () (= 20 (length results))) 10)
      (should (equal (sort results #'<) (number-sequence 0 19))))))

(ert-deftest lxs-server-readdir-stat ()
  (lxs-test--with-server
    (lxs-test--sh conn (format "cd %s && mkdir sub && for i in $(seq -w 0 49); do echo x > f$i; done" dir))
    (let ((entries (lxs-readdir conn dir)))
      (should (= 51 (length entries)))
      (should (equal "f00" (gethash "name" (car entries))))
      (should (equal "dir" (gethash "type" (seq-find (lambda (e) (equal (gethash "name" e) "sub"))
                                                      entries)))))
    (should (equal "file" (gethash "type" (lxs-stat conn (concat dir "/f01")))))))

(ert-deftest lxs-server-write-read-roundtrip ()
  (lxs-test--with-server
    (let* ((path (concat dir "/blob"))
           (small (apply #'unibyte-string (number-sequence 0 255)))
           ;; > one write frame chunk and > several read chunks, non-text bytes
           (big (let ((s (make-string (+ (* 3 1024 1024) 77) 0)) (i 0))
                  (while (< i (length s)) (aset s i (% (* i 7) 256)) (setq i (1+ i)))
                  s)))
      (dolist (data (list small big ""))
        (lxs-write-file conn path data)
        (let ((r (lxs-read-file conn path)))
          (should (equal data (car r)))
          (should-not (multibyte-string-p (car r)))
          (should (equal (cdr r) (gethash "etag" (lxs-stat conn path)))))
        (should (equal data (plist-get (lxs-exec conn (list "cat" path)) :stdout)))))))

(ert-deftest lxs-server-write-conflict ()
  (lxs-test--with-server
    (let* ((path (concat dir "/c"))
           (st (lxs-write-file conn path "one" "-")))
      (should (equal "conflict" (cadr (should-error (lxs-write-file conn path "again" "-")
                                                    :type 'lxs-error))))
      (lxs-write-file conn path "two" (gethash "etag" st))
      (let ((e (should-error (lxs-write-file conn path "three" (gethash "etag" st))
                             :type 'lxs-error)))
        (should (equal "conflict" (cadr e)))
        (should (stringp (gethash "etag" (nth 3 e)))))
      (should (equal "two" (car (lxs-read-file conn path)))))))

(ert-deftest lxs-server-exec ()
  (lxs-test--with-server
    (let ((r (lxs-exec conn '("echo" "hello"))))
      (should (= 0 (plist-get r :code)))
      (should (equal "hello\n" (plist-get r :stdout))))
    (let ((r (lxs-exec conn '("cat") :stdin "piped é")))
      (should (equal "piped é" (decode-coding-string (plist-get r :stdout) 'utf-8))))
    (let ((r (lxs-exec conn '("sh" "-c" "echo err >&2; exit 3"))))
      (should (= 3 (plist-get r :code)))
      (should (equal "err\n" (plist-get r :stderr))))
    ;; more output than the flow-control window
    (let ((r (lxs-exec conn '("sh" "-c" "head -c 3000000 /dev/zero"))))
      (should (= 3000000 (length (plist-get r :stdout)))))
    (should (equal "exec_failed" (cadr (should-error (lxs-exec conn '("/no/such/prog"))
                                                      :type 'lxs-error))))))

(ert-deftest lxs-server-exec-many-args ()
  "Regression: process.start left every argv entry on the Lua stack and
corrupted the heap of the server at about 20 arguments."
  (lxs-test--with-server
    (dolist (n '(19 20 21 40 200))
      (let ((r (lxs-exec conn (cons "echo" (make-list n "a")))))
        (should (= 0 (plist-get r :code)))
        ;; n letters separated by spaces, plus the newline
        (should (= (* 2 n) (length (plist-get r :stdout))))))
    (should (lxs-alive-p conn))))

(ert-deftest lxs-server-watch-event ()
  (lxs-test--with-server
    (let* (events (c2 (lxs-connect (lxs-test--command) (lambda (_c f) (push f events)))))
      (unwind-protect
          (progn
            (lxs-call-sync c2 "watch" `(("path" . ,dir) ("debounce_ms" . 20)))
            (lxs-test--sh conn (format "touch %s/new" dir))
            (lxs--wait c2 (lambda () events) 5)
            (should events)
            (should (equal "watch" (gethash "ev" (car events)))))
        (lxs-close c2)))))

(ert-deftest lxs-server-disconnect ()
  (lxs-test--with-server
    (let ((c2 (lxs-connect (lxs-test--command))) result)
      (lxs-call c2 "sleep_forever_not_an_op" nil (lambda (_o e) (setq result e)))
      (lxs-close c2)
      (lxs--wait c2 (lambda () result) 2)
      (should (lxs-conn-dead c2)))))

(provide 'lxs-test)
;;; lxs-test.el ends here
