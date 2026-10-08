;;; thither-test.el --- ERT tests for thither.el  -*- lexical-binding: t; no-byte-compile: t; -*-

;; Run (from the repository root, on a POSIX host with a built server):
;;   THITHER_SERVER="$HOME/thither-build/thither-server --datadir $PWD/thither/lua --stdio" \
;;     emacs -Q --batch -L emacs -l emacs/test/thither-test.el -f ert-run-tests-batch-and-exit
;; Codec tests need no server.  Server tests are skipped without THITHER_SERVER.

(require 'ert)
(require 'thither)

;;;; Codec

(defun thither-test--roundtrip (x) (thither--decode (thither--encode x)))

(ert-deftest thither-codec-integers ()
  (dolist (n (list 0 1 127 128 255 256 65535 65536 #xffffffff #x100000000
                   (1- (ash 1 63)) (ash 1 63) (1- (ash 1 64))
                   -1 -32 -33 -128 -129 -32768 -32769 (- (ash 1 31))
                   (1- (- (ash 1 31))) (- (ash 1 63))))
    (should (= n (thither-test--roundtrip n)))))

(ert-deftest thither-codec-wire-bytes ()
  (should (equal (thither--encode 5) "\5"))
  (should (equal (thither--encode -1) "\377"))
  (should (equal (thither--encode 200) "\314\310"))
  (should (equal (thither--encode "abc") "\243abc"))
  (should (equal (thither--encode (unibyte-string 255 0)) "\304\2\377\0"))
  (should (equal (thither--encode t) "\303"))
  (should (equal (thither--encode :false) "\302"))
  (should (equal (thither--encode []) "\220")))

(ert-deftest thither-codec-floats ()
  (dolist (x (list 0.0 1.0 -1.5 3.141592653589793 1.0e300 -2.5e-300 5e-324 1.0e+INF -1.0e+INF))
    (should (= x (thither-test--roundtrip x))))
  (should (isnan (thither-test--roundtrip 0.0e+NaN)))
  (should (< (copysign 1.0 (thither-test--roundtrip -0.0)) 0))
  (should (> (copysign 1.0 (thither-test--roundtrip 0.0)) 0))
  ;; float32 on decode
  (should (= 1.5 (thither--decode "\312\77\300\0\0"))))

(ert-deftest thither-codec-strings ()
  (should (equal "héllo ✓" (thither-test--roundtrip "héllo ✓")))
  (should (multibyte-string-p (thither-test--roundtrip "héllo ✓")))
  (let* ((raw (apply #'unibyte-string (number-sequence 0 255)))
         (back (thither-test--roundtrip raw)))
    (should (equal raw back))
    (should-not (multibyte-string-p back)))
  (let ((long (make-string 70000 ?x)))
    (should (equal long (thither-test--roundtrip long)))
    (should (equal (concat long "é") (thither-test--roundtrip (concat long "é"))))))

(ert-deftest thither-codec-containers ()
  (let ((h (thither-test--roundtrip
            `(("a" . 1) (b . [1 2 "x"]) (:c . (("n" . t))) ("skipped" . nil) ("f" . :false)))))
    (should (= 1 (gethash "a" h)))
    (should (equal [1 2 "x"] (gethash "b" h)))
    (should (eq t (gethash "n" (gethash "c" h))))
    (should (eq :false (gethash "f" h)))
    (should (= 4 (hash-table-count h))))
  (should (= 20 (length (thither-test--roundtrip (make-vector 20 1)))))
  (should (= 70000 (length (thither-test--roundtrip (make-vector 70000 1))))))

(ert-deftest thither-codec-hash-table-input ()
  (let ((in (make-hash-table :test 'equal)))
    (dotimes (i 40) (puthash (format "k%d" i) i in))
    (let ((out (thither-test--roundtrip in)))
      (should (= 40 (hash-table-count out)))
      (should (= 39 (gethash "k39" out))))))

;;;; Framing

(ert-deftest thither-frame-reassembly ()
  "Feed two frames one byte at a time, then both at once."
  (let* ((conn (thither--make-conn))
         (got nil)
         (f1 (thither--frame '(("id" . 1) ("ok" . "one"))))
         (f2 (thither--frame `(("id" . 2) ("ok" . ,(unibyte-string 0 1 2 255)))))
         (thither-test--cbs nil))
    (puthash 1 (lambda (ok _e) (push ok got)) (thither-conn-pending conn))
    (puthash 2 (lambda (ok _e) (push ok got)) (thither-conn-pending conn))
    (dolist (b (append (concat f1 f2) nil))
      (thither--filter conn (unibyte-string b)))
    (should (equal (reverse got) (list "one" (unibyte-string 0 1 2 255))))
    (setq got nil)
    (puthash 1 (lambda (ok _e) (push ok got)) (thither-conn-pending conn))
    (puthash 2 (lambda (ok _e) (push ok got)) (thither-conn-pending conn))
    (thither--filter conn (concat f1 f2))
    (should (= 2 (length got)))
    (should (= 0 (thither-conn-nbytes conn)))))

;;;; Server

(defvar thither-test--conn nil)

(defun thither-test--command ()
  (let ((s (getenv "THITHER_SERVER")))
    (and s (split-string-and-unquote s))))

(defmacro thither-test--with-server (&rest body)
  (declare (indent 0))
  `(let ((cmd (thither-test--command)))
     (unless cmd (ert-skip "THITHER_SERVER not set"))
     (let* ((conn (thither-connect cmd))
            (dir (string-trim (plist-get (thither-exec conn '("mktemp" "-d")) :stdout))))
       (unwind-protect (progn ,@body)
         (ignore-errors (thither-exec conn (list "rm" "-rf" dir)))
         (thither-close conn)))))

(defun thither-test--sh (conn script)
  "Run SCRIPT with sh on the server, return stdout."
  (plist-get (thither-exec conn (list "sh" "-c" script)) :stdout))

(ert-deftest thither-server-hello-ping ()
  (thither-test--with-server
    (should (= 1 (gethash "proto_version" (thither-conn-hello conn))))
    (should (thither-has-cap conn "fs"))
    (should (equal "x" (thither-call-sync conn "ping" '(("data" . "x")))))))

(ert-deftest thither-server-errors ()
  (thither-test--with-server
    (let ((e (should-error (thither-call-sync conn "stat" `(("path" . ,(concat dir "/nope"))))
                           :type 'thither-error)))
      (should (equal "ENOENT" (cadr e))))
    (should (null (thither-stat conn (concat dir "/nope"))))
    (should (equal "unknown_op" (cadr (should-error (thither-call-sync conn "bogus")
                                                    :type 'thither-error))))))

(ert-deftest thither-server-async ()
  (thither-test--with-server
    (let (results)
      (dotimes (i 20)
        (thither-call conn "ping" `(("data" . ,i)) (lambda (ok _e) (push ok results))))
      (thither--wait conn (lambda () (= 20 (length results))) 10)
      (should (equal (sort results #'<) (number-sequence 0 19))))))

(ert-deftest thither-server-readdir-stat ()
  (thither-test--with-server
    (thither-test--sh conn (format "cd %s && mkdir sub && for i in $(seq -w 0 49); do echo x > f$i; done" dir))
    (let ((entries (thither-readdir conn dir)))
      (should (= 51 (length entries)))
      (should (equal "f00" (gethash "name" (car entries))))
      (should (equal "dir" (gethash "type" (seq-find (lambda (e) (equal (gethash "name" e) "sub"))
                                                      entries)))))
    (should (equal "file" (gethash "type" (thither-stat conn (concat dir "/f01")))))))

(ert-deftest thither-server-write-read-roundtrip ()
  (thither-test--with-server
    (let* ((path (concat dir "/blob"))
           (small (apply #'unibyte-string (number-sequence 0 255)))
           ;; > one write frame chunk and > several read chunks, non-text bytes
           (big (let ((s (make-string (+ (* 3 1024 1024) 77) 0)) (i 0))
                  (while (< i (length s)) (aset s i (% (* i 7) 256)) (setq i (1+ i)))
                  s)))
      (dolist (data (list small big ""))
        (thither-write-file conn path data)
        (let ((r (thither-read-file conn path)))
          (should (equal data (car r)))
          (should-not (multibyte-string-p (car r)))
          (should (equal (cdr r) (gethash "etag" (thither-stat conn path)))))
        (should (equal data (plist-get (thither-exec conn (list "cat" path)) :stdout)))))))

(ert-deftest thither-server-write-conflict ()
  (thither-test--with-server
    (let* ((path (concat dir "/c"))
           (st (thither-write-file conn path "one" "-")))
      (should (equal "conflict" (cadr (should-error (thither-write-file conn path "again" "-")
                                                    :type 'thither-error))))
      (thither-write-file conn path "two" (gethash "etag" st))
      (let ((e (should-error (thither-write-file conn path "three" (gethash "etag" st))
                             :type 'thither-error)))
        (should (equal "conflict" (cadr e)))
        (should (stringp (gethash "etag" (nth 3 e)))))
      (should (equal "two" (car (thither-read-file conn path)))))))

(ert-deftest thither-server-exec ()
  (thither-test--with-server
    (let ((r (thither-exec conn '("echo" "hello"))))
      (should (= 0 (plist-get r :code)))
      (should (equal "hello\n" (plist-get r :stdout))))
    (let ((r (thither-exec conn '("cat") :stdin "piped é")))
      (should (equal "piped é" (decode-coding-string (plist-get r :stdout) 'utf-8))))
    (let ((r (thither-exec conn '("sh" "-c" "echo err >&2; exit 3"))))
      (should (= 3 (plist-get r :code)))
      (should (equal "err\n" (plist-get r :stderr))))
    ;; more output than the flow-control window
    (let ((r (thither-exec conn '("sh" "-c" "head -c 3000000 /dev/zero"))))
      (should (= 3000000 (length (plist-get r :stdout)))))
    (should (equal "exec_failed" (cadr (should-error (thither-exec conn '("/no/such/prog"))
                                                      :type 'thither-error))))))

(ert-deftest thither-server-exec-many-args ()
  "Regression: process.start left every argv entry on the Lua stack and
corrupted the heap of the server at about 20 arguments."
  (thither-test--with-server
    (dolist (n '(19 20 21 40 200))
      (let ((r (thither-exec conn (cons "echo" (make-list n "a")))))
        (should (= 0 (plist-get r :code)))
        ;; n letters separated by spaces, plus the newline
        (should (= (* 2 n) (length (plist-get r :stdout))))))
    (should (thither-alive-p conn))))

(ert-deftest thither-server-watch-event ()
  (thither-test--with-server
    (let* (events (c2 (thither-connect (thither-test--command) (lambda (_c f) (push f events)))))
      (unwind-protect
          (progn
            (thither-call-sync c2 "watch" `(("path" . ,dir) ("debounce_ms" . 20)))
            (thither-test--sh conn (format "touch %s/new" dir))
            (thither--wait c2 (lambda () events) 5)
            (should events)
            (should (equal "watch" (gethash "ev" (car events)))))
        (thither-close c2)))))

(ert-deftest thither-server-disconnect ()
  (thither-test--with-server
    (let ((c2 (thither-connect (thither-test--command))) result)
      (thither-call c2 "sleep_forever_not_an_op" nil (lambda (_o e) (setq result e)))
      (thither-close c2)
      (thither--wait c2 (lambda () result) 2)
      (should (thither-conn-dead c2)))))

(ert-deftest thither-server-big-stdin ()
  "Stdin larger than one frame is sent in several frames."
  (thither-test--with-server
    (let ((r (thither-exec conn '("wc" "-c") :stdin (make-string (+ (* 17 1024 1024) 5) ?a))))
      (should (equal (format "%d\n" (+ (* 17 1024 1024) 5)) (plist-get r :stdout))))
    (should (thither-alive-p conn))))

(ert-deftest thither-server-sync-call-during-big-send ()
  "A timer making a request while a big frame is sliced out must not stall."
  (thither-test--with-server
    (let* ((n 0) (t0 (float-time))
           (tm (run-with-timer 0 0.005 (lambda () (cl-incf n) (thither-stat conn "/")))))
      (unwind-protect
          (thither-write-file conn (concat dir "/big") (make-string (* 1024 1024) ?b))
        (cancel-timer tm))
      (should (< (- (float-time) t0) 10))
      ;; the timer still gets its turn afterwards
      (thither--wait conn (lambda () (> n 0)) 2)
      (should (> n 0)))))

(ert-deftest thither-server-str-crlf ()
  "str values keep CR LF (no end-of-line detection when decoding)."
  (thither-test--with-server
    (should (equal "a\r\nb\r\n" (thither-call-sync conn "ping" '(("data" . "a\r\nb\r\n")))))))

(ert-deftest thither-server-exec-disconnect ()
  "Running programs end with an error when the connection is lost."
  (thither-test--with-server
    (let* ((c2 (thither-connect (thither-test--command))) exit
           (h (thither-exec-async c2 '("sleep" "100") :on-exit (lambda (&rest a) (setq exit a)))))
      (thither--wait c2 (lambda () (thither-exec-handle-stream h)) 5)
      (thither-close c2)
      (thither--wait c2 (lambda () exit) 5)
      (should exit)
      (should (equal "disconnected" (gethash "code" (nth 2 exit))))
      ;; sending to the dead connection is a no-op, not an error
      (thither-exec-kill c2 h))))

(provide 'thither-test)
;;; thither-test.el ends here
