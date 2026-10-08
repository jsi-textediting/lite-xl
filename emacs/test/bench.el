;;; bench.el --- rough timings for thither.el  -*- lexical-binding: t; no-byte-compile: t; -*-

;; THITHER_SERVER="... --stdio" emacs -Q --batch -L emacs -l emacs/test/bench.el
;; Optionally compare with TRAMP: THITHER_TRAMP=/ssh:host:  (prefix of a scratch dir).

(require 'thither)

(defmacro bench (label &rest body)
  `(let ((t0 (float-time)))
     ,@body
     (message "%-40s %8.1f ms" ,label (* 1000 (- (float-time) t0)))))

(let* ((conn (thither-connect (split-string-and-unquote (getenv "THITHER_SERVER"))))
       (dir (string-trim (plist-get (thither-exec conn '("mktemp" "-d")) :stdout)))
       (big (make-string (* 4 1024 1024) ?a)))
  (thither-exec conn (list "sh" "-c" (format "cd %s && seq -f file%%05g.txt 1 10000 | xargs touch && yes aaaaaaaaaaaaaaa | head -c 4194304 > big" dir)))
  (message "byte-compiled: %s" (byte-code-function-p (symbol-function 'thither--dec)))
  (bench "ping x100 (sync)" (dotimes (_ 100) (thither-call-sync conn "ping")))
  (bench "readdir 10000 entries" (thither-readdir conn dir))
  (bench "stat x100" (dotimes (_ 100) (thither-stat conn (concat dir "/file00001.txt"))))
  (bench "read 4 MiB" (thither-read-file conn (concat dir "/big")))
  ;; the first big send is much slower than later ones (~0.7 s warm-up in WSL)
  (bench "write 4 MiB (first)" (thither-write-file conn (concat dir "/big2") big))
  (bench "write 4 MiB (second)" (thither-write-file conn (concat dir "/big3") big))
  (bench "write 1 KiB x20" (dotimes (_ 20) (thither-write-file conn (concat dir "/s") "x")))
  (let ((payload (thither--encode `(("data" . ,(encode-coding-string big 'utf-8)))))
        (f (thither--frame '(("id" . 1) ("ok" . "x")))))
    (bench "decode 4 MiB bin frame" (thither--decode payload))
    (bench "decode 100k small frames"
           (dotimes (_ 100000) (thither--decode f 4))))
  (thither-exec conn (list "rm" "-rf" dir))
  (thither-close conn))
