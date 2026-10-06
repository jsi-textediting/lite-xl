;;; lxs.el --- Client for lite-xl-server (remote editing)  -*- lexical-binding: t; -*-

;; Version: 0.1
;; Package-Requires: ((emacs "28.1"))
;; Keywords: files, comm, processes

;;; Commentary:

;; Talks the lite-xl-server protocol v1 (docs/remote-protocol.md): length
;; prefixed msgpack frames over the stdio of a subprocess, normally
;; `ssh -T host lite-xl-server --stdio'.
;;
;; Layers:
;;   1. msgpack codec        `lxs--encode', `lxs--decode'
;;   2. framing + connection `lxs-connect', `lxs-call', `lxs-call-sync'
;;   3. file helpers         `lxs-stat', `lxs-readdir', `lxs-read-file',
;;                           `lxs-write-file', `lxs-exec'
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

(define-error 'lxs-error "lite-xl-server error")

(defgroup lxs nil "Remote editing through lite-xl-server." :group 'files)

(defcustom lxs-timeout 30
  "Seconds a synchronous request may take."
  :type 'number)

(defconst lxs-proto-version 1)
(defconst lxs-max-frame (* 16 1024 1024))
(defconst lxs-read-chunk (* 256 1024) "Bytes per `read' request.")
(defconst lxs-read-window 8 "Concurrent `read' requests in `lxs-read-file'.")
(defconst lxs-write-chunk (* 1024 1024))

;;;; msgpack encoder

(defvar lxs--out nil "Reversed list of unibyte strings being produced.")

(defun lxs--be (n width)
  "N as WIDTH big endian bytes (two's complement for negative N)."
  (let ((s (make-string width 0)) (i 0))
    (while (< i width)
      (aset s i (logand (ash n (- (* 8 (- width 1 i)))) 255))
      (setq i (1+ i)))
    s))

(defun lxs--le (n width)
  (let ((s (make-string width 0)) (i 0))
    (while (< i width)
      (aset s i (logand (ash n (- (* 8 i))) 255))
      (setq i (1+ i)))
    s))

(defun lxs--emit (&rest parts) (dolist (p parts) (push p lxs--out)))

(defun lxs--enc-int (n)
  (cond ((<= 0 n 127) (lxs--emit (unibyte-string n)))
        ((<= -32 n -1) (lxs--emit (unibyte-string (logand n 255))))
        ((>= n 0)
         (cond ((< n #x100) (lxs--emit "\314" (lxs--be n 1)))
               ((< n #x10000) (lxs--emit "\315" (lxs--be n 2)))
               ((< n #x100000000) (lxs--emit "\316" (lxs--be n 4)))
               ((< n (ash 1 64)) (lxs--emit "\317" (lxs--be n 8)))
               (t (error "Integer too large for msgpack: %S" n))))
        (t
         (cond ((>= n -128) (lxs--emit "\320" (lxs--be n 1)))
               ((>= n -32768) (lxs--emit "\321" (lxs--be n 2)))
               ((>= n (- (ash 1 31))) (lxs--emit "\322" (lxs--be n 4)))
               ((>= n (- (ash 1 63))) (lxs--emit "\323" (lxs--be n 8)))
               (t (error "Integer too small for msgpack: %S" n))))))

(defun lxs--enc-float (x)
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
    (lxs--emit "\313" (lxs--be (logior (ash sign 63) (ash biased 52) mant) 8))))

(defun lxs--enc-str (s)
  (let* ((bytes (if (multibyte-string-p s)
                    (string-to-unibyte (encode-coding-string s 'utf-8))
                  s))
         (n (length bytes))
         (text (or (multibyte-string-p s)
                   (and (<= n 1024) (string-match-p "\\`[\0-\177]*\\'" s)))))
    (if text
        (cond ((< n 32) (lxs--emit (unibyte-string (logior #xa0 n))))
              ((< n #x100) (lxs--emit "\331" (lxs--be n 1)))
              ((< n #x10000) (lxs--emit "\332" (lxs--be n 2)))
              (t (lxs--emit "\333" (lxs--be n 4))))
      (cond ((< n #x100) (lxs--emit "\304" (lxs--be n 1)))
            ((< n #x10000) (lxs--emit "\305" (lxs--be n 2)))
            (t (lxs--emit "\306" (lxs--be n 4)))))
    (lxs--emit bytes)))

(defun lxs--key-string (k)
  (cond ((stringp k) k)
        ((keywordp k) (substring (symbol-name k) 1))
        ((symbolp k) (symbol-name k))
        (t (error "Bad msgpack map key: %S" k))))

(defun lxs--enc-map-header (n)
  (cond ((< n 16) (lxs--emit (unibyte-string (logior #x80 n))))
        ((< n #x10000) (lxs--emit "\336" (lxs--be n 2)))
        (t (lxs--emit "\337" (lxs--be n 4)))))

(defun lxs--enc (x)
  (cond ((null x) (lxs--emit "\300"))
        ((eq x t) (lxs--emit "\303"))
        ((eq x :false) (lxs--emit "\302"))
        ((integerp x) (lxs--enc-int x))
        ((floatp x) (lxs--enc-float x))
        ((stringp x) (lxs--enc-str x))
        ((vectorp x)
         (let ((n (length x)))
           (cond ((< n 16) (lxs--emit (unibyte-string (logior #x90 n))))
                 ((< n #x10000) (lxs--emit "\334" (lxs--be n 2)))
                 (t (lxs--emit "\335" (lxs--be n 4))))
           (mapc #'lxs--enc x)))
        ((hash-table-p x)
         (let (pairs)
           (maphash (lambda (k v) (when v (push (cons k v) pairs))) x)
           (lxs--enc-pairs pairs)))
        ((and (consp x) (consp (car x))) (lxs--enc-pairs x))
        (t (error "Cannot encode %S as msgpack" x))))

(defun lxs--enc-pairs (pairs)
  (let ((pairs (cl-remove-if (lambda (p) (null (cdr p))) pairs)))
    (lxs--enc-map-header (length pairs))
    (dolist (p pairs)
      (lxs--enc-str (lxs--key-string (car p)))
      (lxs--enc (cdr p)))))

(defun lxs--encode (x)
  "Encode X as one msgpack value (unibyte string)."
  (let ((lxs--out nil))
    (lxs--enc x)
    (let ((out (apply #'concat (nreverse lxs--out))))
      (if (multibyte-string-p out) (string-to-unibyte out) out))))

(defun lxs--frame (x)
  "Encode X (a map) as one protocol frame."
  (let ((payload (lxs--encode x)))
    (concat (lxs--le (length payload) 4) payload)))

;;;; msgpack decoder

(defvar lxs--s "" "Unibyte string being decoded.")
(defvar lxs--i 0 "Read position in `lxs--s'.")

(defun lxs--u (n)
  (let ((v 0) (s lxs--s) (i lxs--i))
    (dotimes (_ n)
      (setq v (+ (ash v 8) (aref s i)) i (1+ i)))
    (setq lxs--i i)
    v))

(defun lxs--sgn (n)
  (let ((v (lxs--u n)) (bits (* 8 n)))
    (if (>= v (ash 1 (1- bits))) (- v (ash 1 bits)) v)))

(defun lxs--take (n)
  (let ((i lxs--i))
    (setq lxs--i (+ i n))
    (when (> lxs--i (length lxs--s)) (signal 'args-out-of-range (list lxs--s i n)))
    (substring lxs--s i lxs--i)))

(defun lxs--dec-str (n) (decode-coding-string (lxs--take n) 'utf-8 t))

(defun lxs--dec-array (n)
  (let ((v (make-vector n nil)) (i 0))
    (while (< i n) (aset v i (lxs--dec)) (setq i (1+ i)))
    v))

(defun lxs--dec-map (n)
  (let ((h (make-hash-table :test 'equal :size (max n 1))))
    (dotimes (_ n)
      (let* ((k (lxs--dec)) (v (lxs--dec)))
        (puthash k v h)))
    h))

(defun lxs--dec-float (ebits mbits)
  (let* ((bits (+ 1 ebits mbits))
         (b (lxs--u (/ bits 8)))
         (sign (if (zerop (ash b (- (1- bits)))) 1.0 -1.0))
         (e (logand (ash b (- mbits)) (1- (ash 1 ebits))))
         (m (logand b (1- (ash 1 mbits))))
         (bias (1- (ash 1 (1- ebits)))))
    (cond ((= e (1- (ash 1 ebits))) (if (zerop m) (* sign 1.0e+INF) 0.0e+NaN))
          ((zerop e) (* sign (ldexp (float m) (- 1 bias mbits))))
          (t (* sign (ldexp (float (+ m (ash 1 mbits))) (- e bias mbits)))))))

(defun lxs--dec ()
  (let ((b (aref lxs--s lxs--i)))
    (setq lxs--i (1+ lxs--i))
    (cond ((< b #x80) b)
          ((< b #x90) (lxs--dec-map (logand b 15)))
          ((< b #xa0) (lxs--dec-array (logand b 15)))
          ((< b #xc0) (lxs--dec-str (logand b 31)))
          ((>= b #xe0) (- b 256))
          (t
           (pcase b
             (#xc0 nil) (#xc2 :false) (#xc3 t)
             (#xc4 (lxs--take (lxs--u 1)))
             (#xc5 (lxs--take (lxs--u 2)))
             (#xc6 (lxs--take (lxs--u 4)))
             (#xca (lxs--dec-float 8 23))
             (#xcb (lxs--dec-float 11 52))
             (#xcc (lxs--u 1)) (#xcd (lxs--u 2)) (#xce (lxs--u 4)) (#xcf (lxs--u 8))
             (#xd0 (lxs--sgn 1)) (#xd1 (lxs--sgn 2)) (#xd2 (lxs--sgn 4)) (#xd3 (lxs--sgn 8))
             (#xd9 (lxs--dec-str (lxs--u 1)))
             (#xda (lxs--dec-str (lxs--u 2)))
             (#xdb (lxs--dec-str (lxs--u 4)))
             (#xdc (lxs--dec-array (lxs--u 2)))
             (#xdd (lxs--dec-array (lxs--u 4)))
             (#xde (lxs--dec-map (lxs--u 2)))
             (#xdf (lxs--dec-map (lxs--u 4)))
             (_ (error "Unsupported msgpack type 0x%x" b)))))))

(defun lxs--decode (string &optional start)
  "Decode one msgpack value from unibyte STRING at START (default 0)."
  (let ((lxs--s string) (lxs--i (or start 0)))
    (lxs--dec)))

;;;; Connection

(cl-defstruct (lxs-conn (:constructor lxs--make-conn))
  proc (next-id 1) (pending (make-hash-table))
  hello chunks (nbytes 0) need
  event-fn (streams (make-hash-table)) last-error dead sending outq)

(defun lxs-get (table key) (and table (gethash key table)))

(defun lxs--disconnected-error (why)
  (let ((h (make-hash-table :test 'equal)))
    (puthash "code" "disconnected" h)
    (puthash "msg" why h)
    h))

(defun lxs--dispatch (conn f)
  (let ((id (gethash "id" f)) (ev (gethash "ev" f)))
    (cond (id
           (let ((cb (gethash id (lxs-conn-pending conn))))
             (when cb
               (remhash id (lxs-conn-pending conn))
               (funcall cb (gethash "ok" f) (gethash "err" f)))))
          ((equal ev "hello") (setf (lxs-conn-hello conn) f))
          ((and (null ev) (gethash "err" f))
           (setf (lxs-conn-last-error conn) (gethash "err" f)))
          ((gethash "stream" f)
           (let ((h (gethash (gethash "stream" f) (lxs-conn-streams conn))))
             (when h (funcall h f))))
          ((lxs-conn-event-fn conn)
           (funcall (lxs-conn-event-fn conn) conn f)))))

(defun lxs--drain (conn)
  (catch 'wait
    (while t
      (let ((need (or (lxs-conn-need conn) 4)))
        (when (< (lxs-conn-nbytes conn) need) (throw 'wait nil))
        (let* ((chunks (lxs-conn-chunks conn))
               (buf (if (cdr chunks) (apply #'concat (nreverse chunks)) (car chunks))))
          (setf (lxs-conn-chunks conn) (list buf))
          (if (null (lxs-conn-need conn))
              (let ((len (logior (aref buf 0) (ash (aref buf 1) 8)
                                 (ash (aref buf 2) 16) (ash (aref buf 3) 24))))
                (when (> len lxs-max-frame) (error "Frame too large: %d" len))
                (setf (lxs-conn-need conn) (+ 4 len)))
            (let* ((frame (lxs--decode buf 4))
                   (rest (substring buf need)))
              (setf (lxs-conn-chunks conn) (if (string-empty-p rest) nil (list rest))
                    (lxs-conn-nbytes conn) (length rest)
                    (lxs-conn-need conn) nil)
              (lxs--dispatch conn frame))))))))

(defun lxs--filter (conn str)
  (push str (lxs-conn-chunks conn))
  (cl-incf (lxs-conn-nbytes conn) (length str))
  (condition-case err (lxs--drain conn)
    (error
     (message "lxs: protocol error: %S" err)
     (when (process-live-p (lxs-conn-proc conn)) (delete-process (lxs-conn-proc conn))))))

(defun lxs--fail-all (conn why)
  (setf (lxs-conn-dead conn) why)
  (let ((pending (lxs-conn-pending conn)) cbs)
    (maphash (lambda (_ cb) (push cb cbs)) pending)
    (clrhash pending)
    (dolist (cb cbs) (funcall cb nil (lxs--disconnected-error why)))))

(defun lxs--wait (conn pred timeout)
  "Run process output until PRED returns non-nil.  Return PRED's value."
  (let ((deadline (+ (float-time) timeout)) v)
    (while (and (not (setq v (funcall pred)))
                (not (lxs-conn-dead conn))
                (< (float-time) deadline))
      (accept-process-output (lxs-conn-proc conn) 0.05))
    (or v (funcall pred))))

(defun lxs--signal (err)
  (signal 'lxs-error (list (gethash "code" err) (gethash "msg" err) err)))

(defconst lxs--send-slice 16384
  "Bytes per `process-send-string' for big frames.
Emacs stalls (about 20 ms per full pipe) whenever a write blocks, so a 4 MiB
frame sent in one call takes 1.4 s.  Measured with a 4 MiB frame through
plink: 16 KiB slices with a short `accept-process-output' in between 0.23 s,
4096 byte slices without it 0.4-1.3 s.")

(defconst lxs--send-pause 0.0003)

(defun lxs--send (conn frame)
  "Send FRAME.  Frames queued by callbacks that run while a big frame is
being sliced out are sent afterwards, never in the middle of it."
  (if (lxs-conn-sending conn)
      (setf (lxs-conn-outq conn) (nconc (lxs-conn-outq conn) (list frame)))
    (setf (lxs-conn-sending conn) t)
    (unwind-protect
        (let ((proc (lxs-conn-proc conn)))
          (while frame
            (let ((n (length frame)) (pos 0))
              (if (<= n lxs--send-slice)
                  (process-send-string proc frame)
                (while (< pos n)
                  (let ((end (min n (+ pos lxs--send-slice))))
                    (process-send-string proc (substring frame pos end))
                    (setq pos end)
                    (when (< pos n) (accept-process-output proc lxs--send-pause))))))
            (setq frame (pop (lxs-conn-outq conn)))))
      (setf (lxs-conn-sending conn) nil))))

(defun lxs-connect (command &optional event-fn)
  "Start COMMAND (a list: program and arguments) and handshake.
EVENT-FN, if non-nil, is called with (CONN FRAME) for server events."
  (let* ((conn (lxs--make-conn :event-fn event-fn))
         ;; From an lxs buffer default-directory is a remote name: spawn locally.
         (default-directory (if (file-remote-p default-directory)
                                temporary-file-directory
                              default-directory))
         (proc (make-process
                :name "lxs" :command command :connection-type 'pipe
                :coding 'no-conversion :noquery t
                :buffer nil :stderr (get-buffer-create " *lxs-stderr*")
                :filter (lambda (_p s) (lxs--filter conn s))
                :sentinel (lambda (_p ev)
                            (lxs--fail-all conn (string-trim ev))))))
    (set-process-query-on-exit-flag proc nil)
    (setf (lxs-conn-proc conn) proc)
    (lxs--send conn (lxs--frame `(("ev" . "hello") ("proto_version" . ,lxs-proto-version)
                                  ("client_version" . "lxs.el 0.1") ("caps" . []))))
    (unless (lxs--wait conn (lambda () (lxs-conn-hello conn)) lxs-timeout)
      (lxs-close conn)
      (error "lite-xl-server did not answer the handshake (see \" *lxs-stderr*\")"))
    (let ((err (gethash "err" (lxs-conn-hello conn))))
      (when err (lxs-close conn) (lxs--signal err)))
    conn))

(defun lxs-close (conn)
  (when (process-live-p (lxs-conn-proc conn))
    (delete-process (lxs-conn-proc conn))))

(defun lxs-alive-p (conn) (and (process-live-p (lxs-conn-proc conn)) t))

(defun lxs-has-cap (conn cap)
  (seq-contains-p (gethash "caps" (lxs-conn-hello conn)) cap #'equal))

(defun lxs-call (conn op args callback)
  "Send request OP with ARGS; call (CALLBACK OK ERR) when answered.
Returns the request id (usable with `lxs-cancel')."
  (if (lxs-conn-dead conn)
      (progn (funcall callback nil (lxs--disconnected-error (lxs-conn-dead conn)))
             nil)
    (let ((id (lxs-conn-next-id conn)))
      (setf (lxs-conn-next-id conn) (1+ id))
      (puthash id callback (lxs-conn-pending conn))
      (lxs--send conn (lxs--frame `(("id" . ,id) ("op" . ,op)
                                    ("args" . ,(or args (make-hash-table :test 'equal))))))
      id)))

(defun lxs-notify (conn op args)
  "Send request OP without id: no answer is produced."
  (lxs--send conn (lxs--frame `(("op" . ,op)
                                ("args" . ,(or args (make-hash-table :test 'equal)))))))

(defun lxs-cancel (conn id)
  (lxs--send conn (lxs--frame `(("cancel" . ,id)))))

(defun lxs-call-sync (conn op &optional args timeout)
  "Run OP and return its result, or signal `lxs-error' (CODE MSG ERR-TABLE)."
  (let (done ok err)
    (let ((id (lxs-call conn op args (lambda (o e) (setq ok o err e done t)))))
      (unless (lxs--wait conn (lambda () done) (or timeout lxs-timeout))
        (when id (remhash id (lxs-conn-pending conn)) (lxs-cancel conn id))
        (signal 'lxs-error (list "timeout" (format "%s timed out" op) nil))))
    (when err (lxs--signal err))
    ok))

;;;; File helpers

(defun lxs-stat (conn path &optional nofollow)
  "Stat table (hash) for PATH, or nil when it does not exist."
  (condition-case err
      (lxs-call-sync conn "stat" `(("path" . ,path) ("nofollow" . ,(and nofollow t))))
    (lxs-error (if (equal (cadr err) "ENOENT") nil (signal (car err) (cdr err))))))

(defun lxs-readdir (conn path)
  "All entries of directory PATH, as a list of stat tables with a \"name\"."
  (let ((offset 0) more entries)
    (while (progn
             (let ((r (lxs-call-sync conn "readdir"
                                     `(("path" . ,path) ("offset" . ,offset)
                                       ("limit" . 20000)))))
               (setq entries (nconc entries (append (gethash "entries" r) nil))
                     more (eq (gethash "more" r) t)
                     offset (+ offset (length (gethash "entries" r)))))
             more))
    entries))

(defun lxs-read-file (conn path)
  "Read PATH, return (DATA . ETAG) with DATA a unibyte string.
Requests are pipelined `lxs-read-window' at a time and pinned to the etag
of the initial stat, so a concurrent change gives a \"stale\" error."
  (let* ((st (or (lxs-stat conn path) (signal 'lxs-error (list "ENOENT" path nil))))
         (etag (gethash "etag" st))
         (size (gethash "size" st))
         (n (max 1 (ceiling size lxs-read-chunk)))
         (parts (make-vector n ""))
         (next 0) (done 0) (inflight 0) failure)
    (when (zerop size) (setq n 0 parts (vector)))
    (cl-labels ((pump ()
                  (while (and (< next n) (< inflight lxs-read-window) (not failure))
                    (let ((idx next))
                      (cl-incf next) (cl-incf inflight)
                      (lxs-call conn "read"
                                `(("path" . ,path) ("offset" . ,(* idx lxs-read-chunk))
                                  ("len" . ,lxs-read-chunk) ("etag" . ,etag))
                                (lambda (ok err)
                                  (cl-decf inflight) (cl-incf done)
                                  (if err (setq failure err)
                                    (aset parts idx (gethash "data" ok)))
                                  (pump)))))))
      (pump)
      (lxs--wait conn (lambda () (or failure (>= done n))) (max lxs-timeout 120)))
    (when failure (lxs--signal failure))
    (unless (>= done n) (signal 'lxs-error (list "timeout" "read timed out" nil)))
    (cons (apply #'concat (append parts nil)) etag)))

(defun lxs-write-file (conn path data &optional if-match)
  "Atomically write unibyte string DATA to PATH.  Return the new stat table.
IF-MATCH is an etag (or \"-\" for \"must not exist\"); on mismatch an
`lxs-error' with code \"conflict\" is signalled."
  (let ((args `(("path" . ,path) ("if_match" . ,if-match))))
    (if (<= (length data) lxs-write-chunk)
        (lxs-call-sync conn "write" `(("data" . ,data) ,@args))
      (let ((wid (gethash "wid" (lxs-call-sync conn "write_begin" args))) (pos 0) (n (length data)))
        (condition-case e
            (progn
              (while (< pos n)
                (let ((end (min n (+ pos lxs-write-chunk))))
                  (lxs-call-sync conn "write_chunk"
                                 `(("wid" . ,wid) ("data" . ,(substring data pos end))))
                  (setq pos end)))
              (lxs-call-sync conn "write_commit" `(("wid" . ,wid))))
          (error (ignore-errors (lxs-call-sync conn "write_abort" `(("wid" . ,wid))))
                 (signal (car e) (cdr e))))))))

(cl-defun lxs-exec (conn argv &key cwd env stdin merge-stderr (timeout lxs-timeout))
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
                         (lxs-notify conn "ack" `(("stream" . ,stream) ("n" . ,(length d)))))
                        ((equal ev "exit")
                         (setq code (gethash "code" f) killed (eq (gethash "killed" f) t)
                               done t))))))
      (lxs-call conn "exec"
                `(("argv" . ,(vconcat argv)) ("cwd" . ,cwd) ("env" . ,env)
                  ("stdin" . ,(if stdin t :false)) ("merge_stderr" . ,(and merge-stderr t)))
                (lambda (ok e)
                  (if e (setq failure e)
                    (setq stream (gethash "stream" ok))
                    (puthash stream #'handler (lxs-conn-streams conn)))))
      (lxs--wait conn (lambda () (or stream failure)) timeout)
      (when failure (lxs--signal failure))
      (unless stream (signal 'lxs-error (list "timeout" "exec timed out" nil)))
      (when stdin
        (lxs-notify conn "stdin" `(("stream" . ,stream) ("data" . ,stdin) ("close" . t))))
      (unwind-protect
          (unless (lxs--wait conn (lambda () done) timeout)
            (lxs-notify conn "kill" `(("stream" . ,stream) ("signal" . "kill")))
            (signal 'lxs-error (list "timeout" "exec timed out" nil)))
        (remhash stream (lxs-conn-streams conn))))
    (list :code code :killed killed
          :stdout (apply #'concat (nreverse out))
          :stderr (apply #'concat (nreverse err)))))

(cl-defstruct (lxs-exec-handle (:constructor lxs--make-exec-handle))
  stream pending killed)

(cl-defun lxs-exec-async (conn argv &key cwd env stdin merge-stderr on-stdout on-stderr on-exit)
  "Start ARGV on the server without waiting; return an `lxs-exec-handle'.
Callbacks run from the process filter: (ON-STDOUT DATA), (ON-STDERR DATA)
and (ON-EXIT CODE KILLED ERR) where ERR is the error table when the program
could not be started.  STDIN non-nil keeps the child's stdin open for
`lxs-exec-send'."
  (let ((h (lxs--make-exec-handle)))
    (lxs-call
     conn "exec"
     `(("argv" . ,(vconcat argv)) ("cwd" . ,cwd) ("env" . ,env)
       ("stdin" . ,(if stdin t :false)) ("merge_stderr" . ,(and merge-stderr t)))
     (lambda (ok err)
       (if err
           (when on-exit (funcall on-exit nil nil err))
         (let ((stream (gethash "stream" ok)))
           (setf (lxs-exec-handle-stream h) stream)
           ;; Registered while the response is dispatched: output frames may
           ;; follow it in the same read.
           (puthash stream
                    (lambda (f)
                      (let ((ev (gethash "ev" f)) (d (gethash "data" f)))
                        (cond ((member ev '("stdout" "stderr"))
                               (lxs-notify conn "ack" `(("stream" . ,stream) ("n" . ,(length d))))
                               (let ((cb (if (equal ev "stdout") on-stdout on-stderr)))
                                 (when cb (funcall cb d))))
                              ((equal ev "exit")
                               (remhash stream (lxs-conn-streams conn))
                               (when on-exit
                                 (funcall on-exit (gethash "code" f)
                                          (eq (gethash "killed" f) t) nil))))))
                    (lxs-conn-streams conn))
           (dolist (m (nreverse (lxs-exec-handle-pending h)))
             (lxs-notify conn "stdin" `(("stream" . ,stream) ("data" . ,(car m)) ("close" . ,(cdr m)))))
           (setf (lxs-exec-handle-pending h) nil)
           (when (lxs-exec-handle-killed h)
             (lxs-notify conn "kill" `(("stream" . ,stream) ("signal" . ,(lxs-exec-handle-killed h)))))))))
    h))

(defun lxs-exec-send (conn h data &optional close)
  "Send DATA (unibyte string) to the stdin of handle H; CLOSE ends the input."
  (let ((stream (lxs-exec-handle-stream h)))
    (if stream
        (lxs-notify conn "stdin" `(("stream" . ,stream) ("data" . ,data) ("close" . ,(and close t))))
      (push (cons data close) (lxs-exec-handle-pending h)))))

(defun lxs-exec-kill (conn h &optional signal)
  "Signal (\"term\", \"kill\" or \"int\") the program of handle H."
  (let ((stream (lxs-exec-handle-stream h)) (signal (or signal "term")))
    (if stream
        (lxs-notify conn "kill" `(("stream" . ,stream) ("signal" . ,signal)))
      (setf (lxs-exec-handle-killed h) signal))))

(provide 'lxs)
;;; lxs.el ends here
