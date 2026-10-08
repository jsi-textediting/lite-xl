;;; thither.el --- Client for thither-server (remote editing)  -*- lexical-binding: t; -*-

;; Version: 0.1
;; Package-Requires: ((emacs "28.1"))
;; Keywords: files, comm, processes

;;; Commentary:

;; Talks the thither-server protocol v1 (thither/docs/protocol.md): length
;; prefixed msgpack frames over the stdio of a subprocess, normally
;; `ssh -T host thither-server --stdio'.
;;
;; Layers:
;;   1. msgpack codec        `thither--encode', `thither--decode'
;;   2. framing + connection `thither-connect', `thither-call', `thither-call-sync'
;;   3. file helpers         `thither-stat', `thither-readdir', `thither-read-file',
;;                           `thither-write-file', `thither-exec'
;;
;; Value mapping, Emacs -> msgpack: integer, float (always float64), t/:false,
;; nil (nil; skipped when it is a map value), unibyte non-ASCII string -> bin,
;; other string -> str (UTF-8), vector -> array, alist or hash table -> map.
;; msgpack -> Emacs: array -> vector, map -> `equal' hash table with string
;; keys, str -> multibyte string, bin -> unibyte string, true -> t,
;; false -> :false, nil -> nil.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(define-error 'thither-error "thither-server error")

(defgroup thither nil "Remote editing through thither-server." :group 'files)

(defcustom thither-timeout 30
  "Seconds a synchronous request may take."
  :type 'number)

(defconst thither-proto-version 1)
(defconst thither-max-frame (* 16 1024 1024))
(defconst thither-read-chunk (* 256 1024) "Bytes per `read' request.")
(defconst thither-read-window 8 "Concurrent `read' requests in `thither-read-file'.")
(defconst thither-write-chunk (* 1024 1024))

;;;; msgpack encoder

(defvar thither--out nil "Reversed list of unibyte strings being produced.")

(defun thither--be (n width)
  "N as WIDTH big endian bytes (two's complement for negative N)."
  (let ((s (make-string width 0)) (i 0))
    (while (< i width)
      (aset s i (logand (ash n (- (* 8 (- width 1 i)))) 255))
      (setq i (1+ i)))
    s))

(defun thither--le (n width)
  (let ((s (make-string width 0)) (i 0))
    (while (< i width)
      (aset s i (logand (ash n (- (* 8 i))) 255))
      (setq i (1+ i)))
    s))

(defun thither--emit (&rest parts) (dolist (p parts) (push p thither--out)))

(defun thither--enc-int (n)
  (cond ((<= 0 n 127) (thither--emit (unibyte-string n)))
        ((<= -32 n -1) (thither--emit (unibyte-string (logand n 255))))
        ((>= n 0)
         (cond ((< n #x100) (thither--emit "\314" (thither--be n 1)))
               ((< n #x10000) (thither--emit "\315" (thither--be n 2)))
               ((< n #x100000000) (thither--emit "\316" (thither--be n 4)))
               ((< n (ash 1 64)) (thither--emit "\317" (thither--be n 8)))
               (t (error "Integer too large for msgpack: %S" n))))
        (t
         (cond ((>= n -128) (thither--emit "\320" (thither--be n 1)))
               ((>= n -32768) (thither--emit "\321" (thither--be n 2)))
               ((>= n (- (ash 1 31))) (thither--emit "\322" (thither--be n 4)))
               ((>= n (- (ash 1 63))) (thither--emit "\323" (thither--be n 8)))
               (t (error "Integer too small for msgpack: %S" n))))))

(defun thither--enc-float (x)
  (let (sign biased mant)
    (setq sign (if (< (copysign 1.0 x) 0) 1 0))
    (cond ((isnan x) (setq biased #x7ff mant (ash 1 51) sign 0))
          ((= (abs x) 1.0e+INF) (setq biased #x7ff mant 0))
          ((= x 0.0) (setq biased 0 mant 0))
          (t
           (let* ((ax (abs x)) (fe (frexp ax)) (ex (cdr fe)))
             (setq biased (+ ex 1022))
             (if (<= biased 0)
                 (setq mant (round (ldexp ax 1074)) biased 0)
               (setq mant (- (truncate (ldexp (car fe) 53)) (ash 1 52)))))))
    (thither--emit "\313" (thither--be (logior (ash sign 63) (ash biased 52) mant) 8))))

(defun thither--enc-str (s)
  (let* ((bytes (if (multibyte-string-p s)
                    (string-to-unibyte (encode-coding-string s 'utf-8-unix))
                  s))
         (n (length bytes))
         (text (or (multibyte-string-p s)
                   (and (<= n 1024) (string-match-p "\\`[\0-\177]*\\'" s)))))
    (if text
        (cond ((< n 32) (thither--emit (unibyte-string (logior #xa0 n))))
              ((< n #x100) (thither--emit "\331" (thither--be n 1)))
              ((< n #x10000) (thither--emit "\332" (thither--be n 2)))
              (t (thither--emit "\333" (thither--be n 4))))
      (cond ((< n #x100) (thither--emit "\304" (thither--be n 1)))
            ((< n #x10000) (thither--emit "\305" (thither--be n 2)))
            (t (thither--emit "\306" (thither--be n 4)))))
    (thither--emit bytes)))

(defun thither--key-string (k)
  (cond ((stringp k) k)
        ((keywordp k) (substring (symbol-name k) 1))
        ((symbolp k) (symbol-name k))
        (t (error "Bad msgpack map key: %S" k))))

(defun thither--enc-map-header (n)
  (cond ((< n 16) (thither--emit (unibyte-string (logior #x80 n))))
        ((< n #x10000) (thither--emit "\336" (thither--be n 2)))
        (t (thither--emit "\337" (thither--be n 4)))))

(defun thither--enc (x)
  (cond ((null x) (thither--emit "\300"))
        ((eq x t) (thither--emit "\303"))
        ((eq x :false) (thither--emit "\302"))
        ((integerp x) (thither--enc-int x))
        ((floatp x) (thither--enc-float x))
        ((stringp x) (thither--enc-str x))
        ((vectorp x)
         (let ((n (length x)))
           (cond ((< n 16) (thither--emit (unibyte-string (logior #x90 n))))
                 ((< n #x10000) (thither--emit "\334" (thither--be n 2)))
                 (t (thither--emit "\335" (thither--be n 4))))
           (mapc #'thither--enc x)))
        ((hash-table-p x)
         (let (pairs)
           (maphash (lambda (k v) (when v (push (cons k v) pairs))) x)
           (thither--enc-pairs pairs)))
        ((and (consp x) (consp (car x))) (thither--enc-pairs x))
        (t (error "Cannot encode %S as msgpack" x))))

(defun thither--enc-pairs (pairs)
  (let ((pairs (cl-remove-if (lambda (p) (null (cdr p))) pairs)))
    (thither--enc-map-header (length pairs))
    (dolist (p pairs)
      (thither--enc-str (thither--key-string (car p)))
      (thither--enc (cdr p)))))

(defun thither--encode (x)
  "Encode X as one msgpack value (unibyte string)."
  (let ((thither--out nil))
    (thither--enc x)
    (let ((out (apply #'concat (nreverse thither--out))))
      (if (multibyte-string-p out) (string-to-unibyte out) out))))

(defun thither--frame (x)
  "Encode X (a map) as one protocol frame."
  (let ((payload (thither--encode x)))
    (concat (thither--le (length payload) 4) payload)))

;;;; msgpack decoder

(defvar thither--s "" "Unibyte string being decoded.")
(defvar thither--i 0 "Read position in `thither--s'.")

(defun thither--u (n)
  (let ((v 0) (s thither--s) (i thither--i))
    (dotimes (_ n)
      (setq v (+ (ash v 8) (aref s i)) i (1+ i)))
    (setq thither--i i)
    v))

(defun thither--sgn (n)
  (let ((v (thither--u n)) (bits (* 8 n)))
    (if (>= v (ash 1 (1- bits))) (- v (ash 1 bits)) v)))

(defun thither--take (n)
  (let ((i thither--i))
    (setq thither--i (+ i n))
    (when (> thither--i (length thither--s)) (signal 'args-out-of-range (list thither--s i n)))
    (substring thither--s i thither--i)))

(defun thither--dec-str (n) (decode-coding-string (thither--take n) 'utf-8-unix t))

(defun thither--dec-array (n)
  (let ((v (make-vector n nil)) (i 0))
    (while (< i n) (aset v i (thither--dec)) (setq i (1+ i)))
    v))

(defun thither--dec-map (n)
  (let ((h (make-hash-table :test 'equal :size (max n 1))))
    (dotimes (_ n)
      (let* ((k (thither--dec)) (v (thither--dec)))
        (puthash k v h)))
    h))

(defun thither--dec-float (ebits mbits)
  (let* ((bits (+ 1 ebits mbits))
         (b (thither--u (/ bits 8)))
         (sign (if (zerop (ash b (- (1- bits)))) 1.0 -1.0))
         (e (logand (ash b (- mbits)) (1- (ash 1 ebits))))
         (m (logand b (1- (ash 1 mbits))))
         (bias (1- (ash 1 (1- ebits)))))
    (cond ((= e (1- (ash 1 ebits))) (if (zerop m) (* sign 1.0e+INF) 0.0e+NaN))
          ((zerop e) (* sign (ldexp (float m) (- 1 bias mbits))))
          (t (* sign (ldexp (float (+ m (ash 1 mbits))) (- e bias mbits)))))))

(defun thither--dec ()
  (let ((b (aref thither--s thither--i)))
    (setq thither--i (1+ thither--i))
    (cond ((< b #x80) b)
          ((< b #x90) (thither--dec-map (logand b 15)))
          ((< b #xa0) (thither--dec-array (logand b 15)))
          ((< b #xc0) (thither--dec-str (logand b 31)))
          ((>= b #xe0) (- b 256))
          (t
           (pcase b
             (#xc0 nil) (#xc2 :false) (#xc3 t)
             (#xc4 (thither--take (thither--u 1)))
             (#xc5 (thither--take (thither--u 2)))
             (#xc6 (thither--take (thither--u 4)))
             (#xca (thither--dec-float 8 23))
             (#xcb (thither--dec-float 11 52))
             (#xcc (thither--u 1)) (#xcd (thither--u 2)) (#xce (thither--u 4)) (#xcf (thither--u 8))
             (#xd0 (thither--sgn 1)) (#xd1 (thither--sgn 2)) (#xd2 (thither--sgn 4)) (#xd3 (thither--sgn 8))
             (#xd9 (thither--dec-str (thither--u 1)))
             (#xda (thither--dec-str (thither--u 2)))
             (#xdb (thither--dec-str (thither--u 4)))
             (#xdc (thither--dec-array (thither--u 2)))
             (#xdd (thither--dec-array (thither--u 4)))
             (#xde (thither--dec-map (thither--u 2)))
             (#xdf (thither--dec-map (thither--u 4)))
             (_ (error "Unsupported msgpack type 0x%x" b)))))))

(defun thither--decode (string &optional start)
  "Decode one msgpack value from unibyte STRING at START (default 0)."
  (let ((thither--s string) (thither--i (or start 0)))
    (thither--dec)))

;;;; Connection

(cl-defstruct (thither-conn (:constructor thither--make-conn))
  proc (next-id 1) (pending (make-hash-table))
  hello chunks (nbytes 0) need
  event-fn (streams (make-hash-table)) last-error dead sending outq (depth 0))

(defun thither-get (table key) (and table (gethash key table)))

(defun thither--disconnected-error (why)
  (let ((h (make-hash-table :test 'equal)))
    (puthash "code" "disconnected" h)
    (puthash "msg" why h)
    h))

(defun thither--dispatch (conn f)
  (let ((id (gethash "id" f)) (ev (gethash "ev" f)))
    (cond (id
           (let ((cb (gethash id (thither-conn-pending conn))))
             (when cb
               (remhash id (thither-conn-pending conn))
               (funcall cb (gethash "ok" f) (gethash "err" f)))))
          ((equal ev "hello") (setf (thither-conn-hello conn) f))
          ((and (null ev) (gethash "err" f))
           (setf (thither-conn-last-error conn) (gethash "err" f)))
          ((gethash "stream" f)
           (let ((h (gethash (gethash "stream" f) (thither-conn-streams conn))))
             (when h (funcall h f))))
          ((thither-conn-event-fn conn)
           (funcall (thither-conn-event-fn conn) conn f)))))

(defun thither--drain (conn)
  (catch 'wait
    (while t
      (let ((need (or (thither-conn-need conn) 4)))
        (when (< (thither-conn-nbytes conn) need) (throw 'wait nil))
        (let* ((chunks (thither-conn-chunks conn))
               (buf (if (cdr chunks) (apply #'concat (nreverse chunks)) (car chunks))))
          (setf (thither-conn-chunks conn) (list buf))
          (if (null (thither-conn-need conn))
              (let ((len (logior (aref buf 0) (ash (aref buf 1) 8)
                                 (ash (aref buf 2) 16) (ash (aref buf 3) 24))))
                (when (> len thither-max-frame) (error "Frame too large: %d" len))
                (setf (thither-conn-need conn) (+ 4 len)))
            (let* ((frame (thither--decode buf 4))
                   (rest (substring buf need)))
              (setf (thither-conn-chunks conn) (if (string-empty-p rest) nil (list rest))
                    (thither-conn-nbytes conn) (length rest)
                    (thither-conn-need conn) nil)
              (thither--dispatch conn frame))))))))

(defun thither--drain-safe (conn)
  (cl-incf (thither-conn-depth conn))
  (unwind-protect
      (condition-case err (thither--drain conn)
        (error
         (message "thither: protocol error: %S" err)
         (when (process-live-p (thither-conn-proc conn)) (delete-process (thither-conn-proc conn)))))
    (cl-decf (thither-conn-depth conn))))

(defun thither--filter (conn str)
  (push str (thither-conn-chunks conn))
  (cl-incf (thither-conn-nbytes conn) (length str))
  ;; While a big frame is being sliced out nothing is dispatched: a callback
  ;; making a synchronous request then would wait for an answer to a frame
  ;; that can only be sent after the current one.  `thither--send' drains later.
  (unless (thither-conn-sending conn) (thither--drain-safe conn)))

(defun thither--fail-all (conn why)
  (setf (thither-conn-dead conn) why)
  (let ((pending (thither-conn-pending conn)) (streams (thither-conn-streams conn)) cbs hs)
    (maphash (lambda (_ cb) (push cb cbs)) pending)
    (clrhash pending)
    (maphash (lambda (id h) (push (cons id h) hs)) streams)
    (clrhash streams)
    (dolist (cb cbs) (funcall cb nil (thither--disconnected-error why)))
    ;; Running programs are gone with the connection: end their streams.
    (dolist (h hs)
      (let ((f (make-hash-table :test 'equal)))
        (puthash "ev" "exit" f)
        (puthash "stream" (car h) f)
        (puthash "err" (thither--disconnected-error why) f)
        (funcall (cdr h) f)))))

(defun thither--wait (conn pred timeout)
  "Run process output until PRED returns non-nil.  Return PRED's value."
  (let ((deadline (+ (float-time) timeout)) v)
    (while (and (not (setq v (funcall pred)))
                (not (thither-conn-dead conn))
                (< (float-time) deadline))
      ;; frames buffered while a big frame was sent may already hold the answer
      (if (and (thither-conn-chunks conn) (not (thither-conn-sending conn))
               (progn (thither--drain-safe conn) (funcall pred)))
          nil
        (accept-process-output (thither-conn-proc conn) 0.05)))
    (or v (funcall pred))))

(defun thither--signal (err)
  (signal 'thither-error (list (gethash "code" err) (gethash "msg" err) err)))

(defconst thither--send-slice 16384
  "Bytes per `process-send-string' for big frames.
Emacs stalls (about 20 ms per full pipe) whenever a write blocks, so a 4 MiB
frame sent in one call takes 1.4 s.  Measured with a 4 MiB frame through
plink: 16 KiB slices with a short `accept-process-output' in between 0.23 s,
4096 byte slices without it 0.4-1.3 s.")

(defconst thither--send-pause 0.0003)

(defun thither--send (conn frame)
  "Send FRAME.  Frames queued while a big frame is being sliced out are sent
afterwards, never in the middle of it.  Nothing is sent on a dead connection."
  (cond
   ((thither-conn-dead conn) nil)
   ((thither-conn-sending conn)
    (setf (thither-conn-outq conn) (nconc (thither-conn-outq conn) (list frame))))
   (t
    (setf (thither-conn-sending conn) t)
    (unwind-protect
        (let ((proc (thither-conn-proc conn)))
          (while frame
            (let ((n (length frame)) (pos 0))
              (if (<= n thither--send-slice)
                  (process-send-string proc frame)
                (while (< pos n)
                  (let ((end (min n (+ pos thither--send-slice))))
                    (process-send-string proc (substring frame pos end))
                    (setq pos end)
                    ;; Only this process, and no timers (integer JUST-THIS-ONE):
                    ;; output is buffered by the filter, not dispatched.
                    (when (< pos n) (accept-process-output proc thither--send-pause nil 0))))))
            (setq frame (pop (thither-conn-outq conn)))))
      (setf (thither-conn-sending conn) nil))
    ;; Inside a dispatch the running `thither--drain' picks the buffered frames up.
    (when (zerop (thither-conn-depth conn)) (thither--drain-safe conn)))))

(defun thither-connect (command &optional event-fn)
  "Start COMMAND (a list: program and arguments) and handshake.
EVENT-FN, if non-nil, is called with (CONN FRAME) for server events."
  (let* ((conn (thither--make-conn :event-fn event-fn))
         ;; From an thither buffer default-directory is a remote name: spawn locally.
         (default-directory (if (file-remote-p default-directory)
                                temporary-file-directory
                              default-directory))
         (proc (make-process
                :name "thither" :command command :connection-type 'pipe
                :coding 'no-conversion :noquery t
                :buffer nil :stderr (get-buffer-create " *thither-stderr*")
                :filter (lambda (_p s) (thither--filter conn s))
                :sentinel (lambda (_p ev)
                            (thither--fail-all conn (string-trim ev))))))
    (set-process-query-on-exit-flag proc nil)
    (setf (thither-conn-proc conn) proc)
    (thither--send conn (thither--frame `(("ev" . "hello") ("proto_version" . ,thither-proto-version)
                                  ("client_version" . "thither.el 0.1") ("caps" . []))))
    (unless (thither--wait conn (lambda () (thither-conn-hello conn)) thither-timeout)
      (thither-close conn)
      (error "thither-server did not answer the handshake (see \" *thither-stderr*\")"))
    (let ((err (gethash "err" (thither-conn-hello conn))))
      (when err (thither-close conn) (thither--signal err)))
    conn))

(defun thither-close (conn)
  (when (process-live-p (thither-conn-proc conn))
    (delete-process (thither-conn-proc conn))))

(defun thither-alive-p (conn) (and (process-live-p (thither-conn-proc conn)) t))

(defun thither-has-cap (conn cap)
  (seq-contains-p (gethash "caps" (thither-conn-hello conn)) cap #'equal))

(defun thither-call (conn op args callback)
  "Send request OP with ARGS; call (CALLBACK OK ERR) when answered.
Returns the request id (usable with `thither-cancel')."
  (if (thither-conn-dead conn)
      (progn (funcall callback nil (thither--disconnected-error (thither-conn-dead conn)))
             nil)
    (let ((id (thither-conn-next-id conn)))
      (setf (thither-conn-next-id conn) (1+ id))
      (puthash id callback (thither-conn-pending conn))
      (thither--send conn (thither--frame `(("id" . ,id) ("op" . ,op)
                                    ("args" . ,(or args (make-hash-table :test 'equal))))))
      id)))

(defun thither-notify (conn op args)
  "Send request OP without id: no answer is produced."
  (thither--send conn (thither--frame `(("op" . ,op)
                                ("args" . ,(or args (make-hash-table :test 'equal)))))))

(defun thither-cancel (conn id)
  (thither--send conn (thither--frame `(("cancel" . ,id)))))

(defun thither-call-sync (conn op &optional args timeout)
  "Run OP and return its result, or signal `thither-error' (CODE MSG ERR-TABLE)."
  (let (done ok err)
    (let ((id (thither-call conn op args (lambda (o e) (setq ok o err e done t)))))
      (unless (thither--wait conn (lambda () done) (or timeout thither-timeout))
        (when id (remhash id (thither-conn-pending conn)) (thither-cancel conn id))
        (signal 'thither-error (list "timeout" (format "%s timed out" op) nil))))
    (when err (thither--signal err))
    ok))

;;;; File helpers

(defun thither-stat (conn path &optional nofollow)
  "Stat table (hash) for PATH, or nil when it does not exist."
  (condition-case err
      (thither-call-sync conn "stat" `(("path" . ,path) ("nofollow" . ,(and nofollow t))))
    (thither-error (if (equal (cadr err) "ENOENT") nil (signal (car err) (cdr err))))))

(defun thither-readdir (conn path)
  "All entries of directory PATH, as a list of stat tables with a \"name\"."
  (let ((offset 0) more entries)
    (while (progn
             (let ((r (thither-call-sync conn "readdir"
                                     `(("path" . ,path) ("offset" . ,offset)
                                       ("limit" . 20000)))))
               (setq entries (nconc entries (append (gethash "entries" r) nil))
                     more (eq (gethash "more" r) t)
                     offset (+ offset (length (gethash "entries" r)))))
             more))
    entries))

(defun thither-read-file (conn path)
  "Read PATH, return (DATA . ETAG) with DATA a unibyte string.
Requests are pipelined `thither-read-window' at a time and pinned to the etag
of the initial stat, so a concurrent change gives a \"stale\" error."
  (let* ((st (or (thither-stat conn path) (signal 'thither-error (list "ENOENT" path nil))))
         (etag (gethash "etag" st))
         (size (gethash "size" st))
         (n (max 1 (ceiling size thither-read-chunk)))
         (parts (make-vector n ""))
         (next 0) (done 0) (inflight 0) failure)
    (when (zerop size) (setq n 0 parts (vector)))
    (cl-labels ((pump ()
                  (while (and (< next n) (< inflight thither-read-window) (not failure))
                    (let ((idx next))
                      (cl-incf next) (cl-incf inflight)
                      (thither-call conn "read"
                                `(("path" . ,path) ("offset" . ,(* idx thither-read-chunk))
                                  ("len" . ,thither-read-chunk) ("etag" . ,etag))
                                (lambda (ok err)
                                  (cl-decf inflight) (cl-incf done)
                                  (if err (setq failure err)
                                    (aset parts idx (gethash "data" ok)))
                                  (pump)))))))
      (pump)
      (thither--wait conn (lambda () (or failure (>= done n))) (max thither-timeout 120)))
    (when failure (thither--signal failure))
    (unless (>= done n) (signal 'thither-error (list "timeout" "read timed out" nil)))
    (cons (apply #'concat (append parts nil)) etag)))

(defun thither-write-file (conn path data &optional if-match)
  "Atomically write unibyte string DATA to PATH.  Return the new stat table.
IF-MATCH is an etag (or \"-\" for \"must not exist\"); on mismatch an
`thither-error' with code \"conflict\" is signalled."
  (let ((args `(("path" . ,path) ("if_match" . ,if-match))))
    (if (<= (length data) thither-write-chunk)
        (thither-call-sync conn "write" `(("data" . ,data) ,@args))
      (let ((wid (gethash "wid" (thither-call-sync conn "write_begin" args))) (pos 0) (n (length data)))
        (condition-case e
            (progn
              (while (< pos n)
                (let ((end (min n (+ pos thither-write-chunk))))
                  (thither-call-sync conn "write_chunk"
                                 `(("wid" . ,wid) ("data" . ,(substring data pos end))))
                  (setq pos end)))
              (thither-call-sync conn "write_commit" `(("wid" . ,wid))))
          (error (ignore-errors (thither-call-sync conn "write_abort" `(("wid" . ,wid))))
                 (signal (car e) (cdr e))))))))

(defun thither--send-stdin (conn stream data close)
  "Send DATA to the stdin of STREAM in frames below the frame limit."
  (let ((n (length data)) (pos 0))
    (while (progn
             (let ((end (min n (+ pos thither-write-chunk))))
               (thither-notify conn "stdin" `(("stream" . ,stream) ("data" . ,(substring data pos end))
                                          ("close" . ,(and close (= end n) t))))
               (setq pos end))
             (< pos n)))))

(cl-defun thither-exec (conn argv &key cwd env stdin merge-stderr (timeout thither-timeout))
  "Run ARGV on the server.  Return a plist (:code :killed :stdout :stderr).
ENV is an alist of strings, STDIN a unibyte string or nil.  With
MERGE-STDERR the child's stderr arrives in :stdout."
  (let (stream failure done code killed out err)
    ;; The stream handler must be registered while the response is being
    ;; dispatched: output frames may follow it in the same read.
    (cl-flet ((handler (f)
                (let ((ev (gethash "ev" f)) (d (gethash "data" f)))
                  (cond ((member ev '("stdout" "stderr"))
                         (push d (if (equal ev "stdout") out err))
                         (thither-notify conn "ack" `(("stream" . ,stream) ("n" . ,(length d)))))
                        ((equal ev "exit")
                         (setq code (gethash "code" f) killed (eq (gethash "killed" f) t)
                               failure (gethash "err" f) done t))))))
      (thither-call conn "exec"
                `(("argv" . ,(vconcat argv)) ("cwd" . ,cwd) ("env" . ,env)
                  ("stdin" . ,(if stdin t :false)) ("merge_stderr" . ,(and merge-stderr t)))
                (lambda (ok e)
                  (if e (setq failure e)
                    (setq stream (gethash "stream" ok))
                    (puthash stream #'handler (thither-conn-streams conn)))))
      (thither--wait conn (lambda () (or stream failure)) timeout)
      (when failure (thither--signal failure))
      (unless stream (signal 'thither-error (list "timeout" "exec timed out" nil)))
      (when stdin
        (thither--send-stdin conn stream stdin t))
      (unwind-protect
          (unless (thither--wait conn (lambda () done) timeout)
            (thither-notify conn "kill" `(("stream" . ,stream) ("signal" . "kill")))
            (signal 'thither-error (list "timeout" "exec timed out" nil)))
        (remhash stream (thither-conn-streams conn)))
      (when failure (thither--signal failure)))
    (list :code code :killed killed
          :stdout (apply #'concat (nreverse out))
          :stderr (apply #'concat (nreverse err)))))

(cl-defstruct (thither-exec-handle (:constructor thither--make-exec-handle))
  stream pending killed)

(cl-defun thither-exec-async (conn argv &key cwd env stdin merge-stderr on-stdout on-stderr on-exit)
  "Start ARGV on the server without waiting; return an `thither-exec-handle'.
Callbacks run from the process filter: (ON-STDOUT DATA), (ON-STDERR DATA)
and (ON-EXIT CODE KILLED ERR) where ERR is the error table when the program
could not be started.  STDIN non-nil keeps the child's stdin open for
`thither-exec-send'."
  (let ((h (thither--make-exec-handle)))
    (thither-call
     conn "exec"
     `(("argv" . ,(vconcat argv)) ("cwd" . ,cwd) ("env" . ,env)
       ("stdin" . ,(if stdin t :false)) ("merge_stderr" . ,(and merge-stderr t)))
     (lambda (ok err)
       (if err
           (when on-exit (funcall on-exit nil nil err))
         (let ((stream (gethash "stream" ok)))
           (setf (thither-exec-handle-stream h) stream)
           ;; Registered while the response is dispatched: output frames may
           ;; follow it in the same read.
           (puthash stream
                    (lambda (f)
                      (let ((ev (gethash "ev" f)) (d (gethash "data" f)))
                        (cond ((member ev '("stdout" "stderr"))
                               (let ((cb (if (equal ev "stdout") on-stdout on-stderr)))
                                 (when cb (funcall cb d)))
                               (thither-notify conn "ack" `(("stream" . ,stream) ("n" . ,(length d)))))
                              ((equal ev "exit")
                               (remhash stream (thither-conn-streams conn))
                               (when on-exit
                                 (funcall on-exit (gethash "code" f)
                                          (eq (gethash "killed" f) t) (gethash "err" f)))))))
                    (thither-conn-streams conn))
           (dolist (m (nreverse (thither-exec-handle-pending h)))
             (thither--send-stdin conn stream (car m) (cdr m)))
           (setf (thither-exec-handle-pending h) nil)
           (when (thither-exec-handle-killed h)
             (thither-notify conn "kill" `(("stream" . ,stream) ("signal" . ,(thither-exec-handle-killed h)))))))))
    h))

(defun thither-exec-send (conn h data &optional close)
  "Send DATA (unibyte string) to the stdin of handle H; CLOSE ends the input."
  (let ((stream (thither-exec-handle-stream h)))
    (if stream
        (thither--send-stdin conn stream data close)
      (push (cons data close) (thither-exec-handle-pending h)))))

(defun thither-exec-kill (conn h &optional signal)
  "Signal (\"term\", \"kill\" or \"int\") the program of handle H."
  (let ((stream (thither-exec-handle-stream h)) (signal (or signal "term")))
    (if stream
        (thither-notify conn "kill" `(("stream" . ,stream) ("signal" . ,signal)))
      (setf (thither-exec-handle-killed h) signal))))

(provide 'thither)
;;; thither.el ends here
