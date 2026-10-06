;;; bench.el --- rough timings for lxs.el  -*- lexical-binding: t; no-byte-compile: t; -*-

;; LXS_SERVER="... --stdio" emacs -Q --batch -L emacs -l emacs/test/bench.el
;; Optionally compare with TRAMP: LXS_TRAMP=/ssh:host:  (prefix of a scratch dir).

(require 'lxs)

(defmacro bench (label &rest body)
  `(let ((t0 (float-time)))
     ,@body
     (message "%-40s %8.1f ms" ,label (* 1000 (- (float-time) t0)))))

(let* ((conn (lxs-connect (split-string-and-unquote (getenv "LXS_SERVER"))))
       (dir (string-trim (plist-get (lxs-exec conn '("mktemp" "-d")) :stdout)))
       (big (make-string (* 4 1024 1024) ?a)))
  (lxs-exec conn (list "sh" "-c" (format "cd %s && seq -f file%%05g.txt 1 10000 | xargs touch && yes aaaaaaaaaaaaaaa | head -c 4194304 > big" dir)))
  (message "byte-compiled: %s" (byte-code-function-p (symbol-function 'lxs--dec)))
  (bench "ping x100 (sync)" (dotimes (_ 100) (lxs-call-sync conn "ping")))
  (bench "readdir 10000 entries" (lxs-readdir conn dir))
  (bench "stat x100" (dotimes (_ 100) (lxs-stat conn (concat dir "/file00001.txt"))))
  (bench "read 4 MiB" (lxs-read-file conn (concat dir "/big")))
  ;; the first big send is much slower than later ones (~0.7 s warm-up in WSL)
  (bench "write 4 MiB (first)" (lxs-write-file conn (concat dir "/big2") big))
  (bench "write 4 MiB (second)" (lxs-write-file conn (concat dir "/big3") big))
  (bench "write 1 KiB x20" (dotimes (_ 20) (lxs-write-file conn (concat dir "/s") "x")))
  (let ((payload (lxs--encode `(("data" . ,(encode-coding-string big 'utf-8)))))
        (f (lxs--frame '(("id" . 1) ("ok" . "x")))))
    (bench "decode 4 MiB bin frame" (lxs--decode payload))
    (bench "decode 100k small frames"
           (dotimes (_ 100000) (lxs--decode f 4))))
  (lxs-exec conn (list "rm" "-rf" dir))
  (lxs-close conn))
