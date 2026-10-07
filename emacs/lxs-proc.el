;;; lxs-proc.el --- Processes on lxs hosts  -*- lexical-binding: t; -*-

;; Version: 0.1
;; Package-Requires: ((emacs "28.1"))
;; Keywords: files, comm, processes

;;; Commentary:

;; `process-file', `make-process', `start-file-process' and `exec-path' (used
;; by `executable-find' with REMOTE) for a `default-directory' of the form
;; /lxs:HOST:/dir, implemented with the server's `exec' op (no new connection
;; per process).
;;
;; Asynchronous processes are local pipe processes ("bridges"): output events
;; of the remote program are fed into the pipe process, so the caller's
;; :filter, :buffer and :coding work unchanged.  Because a pipe process has no
;; child, the status/exit/kill/send functions are advised for bridged
;; processes only.  The remote program has no tty.

;;; Code:

(require 'lxs-fs)
(require 'cl-lib)
(require 'subr-x)

(defun lxs--remote-shell (program)
  (if (equal program shell-file-name) "/bin/sh" program))

(defun lxs--remote-command (program args)
  "Command list for PROGRAM and ARGS on the host.
The local shell becomes /bin/sh and its switch (cmd.exe's /c ...) becomes -c."
  (let ((shell (equal program shell-file-name)))
    (mapcar #'lxs--arg
            (cons (lxs--remote-shell program)
                  (if (and shell args (equal (car args) shell-command-switch))
                      (cons "-c" (cdr args))
                    args)))))

(defun lxs--arg (a)
  "A as a string the server accepts in argv (it refuses `bin')."
  (cond ((not (stringp a)) (format "%s" a))
        ((and (not (multibyte-string-p a)) (string-match-p "[^\0-\177]" a))
         (decode-coding-string a 'utf-8))
        (t a)))

(defun lxs--argv (program args)
  (lxs--remote-command program args))

;;;; process-file

(defun lxs--read-infile (infile)
  (cond ((null infile) nil)
        ((lxs--split infile) (car (lxs--read-bytes infile)))
        (t (lxs--read-local infile))))

(defun lxs--dest-buffer (dest)
  (cond ((eq dest t) (current-buffer))
        ((bufferp dest) dest)
        ((stringp dest) (get-buffer-create dest))
        (t nil)))

(lxs--define process-file (program &optional infile buffer _display &rest args)
  (let* ((p (lxs--path default-directory))
         (file-only (and (consp buffer) (eq (car buffer) :file)))
         (pair (and (consp buffer) (not file-only)))
         (real (if pair (car buffer) buffer))
         (err-dest (if pair (cadr buffer) t))
         (file-dest (and (or file-only (and (consp real) (eq (car real) :file)))
                         (cadr (if file-only buffer real))))
         (out-buf (and (not file-dest) (lxs--dest-buffer real)))
         (r (condition-case err
                (lxs-exec (lxs-connection (car p))
                          (lxs--argv program args)
                          :cwd (cdr p)
                          :stdin (lxs--read-infile infile)
                          :merge-stderr (eq err-dest t)
                          :timeout 3600)
              (lxs-error
               ;; like `call-process' for a program that cannot be run
               (if (equal (cadr err) "exec_failed")
                   (signal 'file-missing (list "Searching for program"
                                               "No such file or directory" program))
                 (lxs--file-error err program "Running program")))))
         (out (plist-get r :stdout)))
    (when file-dest
      (let ((coding-system-for-write 'no-conversion))
        (write-region out nil file-dest nil 'silent)))
    (when out-buf
      (with-current-buffer out-buf (insert (lxs--text out))))
    (when (stringp err-dest)
      (let ((coding-system-for-write 'no-conversion))
        (write-region (plist-get r :stderr) nil err-dest nil 'silent)))
    (when process-file-side-effects (lxs--flush (car p)))
    (if (plist-get r :killed) "Killed" (plist-get r :code))))

(defvar lxs--exec-paths (make-hash-table :test 'equal)
  "HOST -> list of the directories in the server's PATH.")

(lxs--define exec-path ()
  ;; `executable-find' with REMOTE searches these below the remote prefix.
  (let ((host (car (lxs--path default-directory))))
    (or (gethash host lxs--exec-paths)
        (puthash host
                 (let ((r (lxs-exec (lxs-connection host)
                                    (list "/bin/sh" "-c" "printf %s \"$PATH\""))))
                   (split-string (lxs--text (plist-get r :stdout)) ":" t))
                 lxs--exec-paths))))

;;;; make-process: pipe-process bridges

(defun lxs--proc-of (process)
  "The process designated by PROCESS (process, buffer or name), or nil."
  (cond ((processp process) process)
        ((null process) (get-buffer-process (current-buffer)))
        ((bufferp process) (get-buffer-process process))
        ((stringp process) (get-process process))))

(defun lxs--bridge-p (proc) (and (processp proc) (process-get proc 'lxs-conn)))

(defun lxs--decode-incremental (proc bytes coding &optional final)
  "Decode BYTES appended to PROC's undecoded remainder.
Unless FINAL, an incomplete multibyte sequence at the end is kept for later."
  (let* ((all (concat (or (process-get proc 'lxs-pending) "") bytes))
         (n (length all)) (cut n))
    (when (and (not final) coding
               (memq (coding-system-base coding) '(utf-8 utf-8-emacs prefer-utf-8 undecided)))
      ;; Hold back an incomplete UTF-8 sequence at the end.
      (let ((i (1- n)) (back 0))
        (while (and (>= i 0) (< back 3) (= (logand (aref all i) #xc0) #x80))
          (setq i (1- i) back (1+ back)))
        (when (>= i 0)
          (let* ((b (aref all i))
                 (need (cond ((>= b #xf0) 4) ((>= b #xe0) 3) ((>= b #xc0) 2) (t 1))))
            (when (< (- n i) need) (setq cut i))))))
    (process-put proc 'lxs-pending (and (< cut n) (substring all cut)))
    (decode-coding-string (substring all 0 cut) coding)))

(defun lxs--deliver (proc bytes &optional final)
  "Hand output BYTES of the remote program to PROC's filter or buffer.
FINAL flushes bytes held back as an incomplete character."
  (let ((s (lxs--decode-incremental proc bytes (process-get proc 'lxs-decoding) final)))
    (unless (string-empty-p s)
      (let ((filter (process-filter proc)))
        (if (and filter (not (eq filter 'internal-default-process-filter)))
            (funcall filter proc s)
          (internal-default-process-filter proc s))))))

(defun lxs--stderr-sink (stderr)
  "Function receiving stderr bytes for make-process' :stderr value STDERR."
  (cond ((bufferp stderr)
         (lambda (d)
           (when (buffer-live-p stderr)
             (with-current-buffer stderr
               (let ((inhibit-read-only t))
                 (save-excursion (goto-char (point-max)) (insert (lxs--text d))))))))
        ((processp stderr) (lambda (d) (lxs--deliver stderr d)))))

(defun lxs--finish (proc code killed err)
  "Run PROC's sentinel once the remote program is done."
  (unless (process-get proc 'lxs-done)
    (process-put proc 'lxs-done t)
    ;; 127 when the program could not be started, 255 (like ssh) when the
    ;; connection was lost
    (process-put proc 'lxs-code (or code (and err (if (equal (gethash "code" err) "exec_failed") 127 255))
                                    0))
    (process-put proc 'lxs-killed killed)
    (when err
      (let ((sink (process-get proc 'lxs-stderr)))
        (when sink (funcall sink (encode-coding-string
                                  (format "%s\n" (gethash "msg" err)) 'utf-8)))))
    (when (process-get proc 'lxs-pending) (lxs--deliver proc "" t))
    (let ((sentinel (process-sentinel proc))
          (event (cond (killed "killed\n")
                       ((eq 0 (process-get proc 'lxs-code)) "finished\n")
                       (t (format "exited abnormally with code %d\n"
                                  (process-get proc 'lxs-code))))))
      ;; Emacs must not run it again with "deleted" when the pipe goes away.
      (set-process-sentinel proc #'ignore)
      (process-put proc 'lxs-closed t)
      (ignore-errors (delete-process proc))
      (when (and sentinel (not (eq sentinel 'internal-default-process-sentinel)))
        (funcall sentinel proc event)))))

(lxs--define make-process (&rest args)
  (let* ((name (plist-get args :name))
         (command (plist-get args :command))
         (buffer (plist-get args :buffer))
         (coding (plist-get args :coding))
         (stderr (plist-get args :stderr))
         (p (lxs--path default-directory))
         (conn (lxs-connection (car p)))
         (buf (cond ((bufferp buffer) buffer)
                    ((stringp buffer) (get-buffer-create buffer))))
         (proc (make-pipe-process :name name :buffer buf :noquery t
                                  :filter (plist-get args :filter)
                                  :sentinel (plist-get args :sentinel)))
         (sink (lxs--stderr-sink stderr))
         handle)
    (process-put proc 'lxs-conn conn)
    (process-put proc 'lxs-host (car p))
    (process-put proc 'lxs-command command)
    (process-put proc 'lxs-stderr sink)
    (set-process-coding-system proc
                               (or (if (consp coding) (car coding) coding)
                                   (car default-process-coding-system) 'utf-8)
                               (or (if (consp coding) (cdr coding) coding)
                                   (cdr default-process-coding-system) 'utf-8))
    (setq handle
          (lxs-exec-async
           conn (lxs--remote-command (car command) (cdr command))
           :cwd (cdr p) :stdin t :merge-stderr (null stderr)
           :on-stdout (lambda (d) (lxs--deliver proc d))
           :on-stderr (lambda (d) (when sink (funcall sink d)))
           :on-exit (lambda (code killed err) (lxs--finish proc code killed err))))
    (process-put proc 'lxs-handle handle)
    proc))

(lxs--define start-file-process (name buffer program &rest args)
  (funcall (gethash 'make-process lxs--handlers)
           :name name :buffer buffer :command (cons program args)
           :filter nil :sentinel nil))

;;;; Advice: status, kill, stdin of bridged processes

(defun lxs--signal-name (sig)
  (let ((n (cond ((numberp sig) sig)
                 ((symbolp sig) (pcase (upcase (symbol-name sig))
                                  ((or "INT" "SIGINT") 2) ((or "KILL" "SIGKILL") 9)
                                  ((or "QUIT" "SIGQUIT") 3) (_ 15)))
                 (t 15))))
    (pcase n (2 "int") (9 "kill") (_ "term"))))

(defun lxs--kill-bridge (proc &optional sig)
  (unless (process-get proc 'lxs-done)
    (lxs-exec-kill (process-get proc 'lxs-conn) (process-get proc 'lxs-handle)
                   (lxs--signal-name (or sig 15)))))

(defun lxs--live-bridge-p (p)
  (and (lxs--bridge-p p) (not (process-get p 'lxs-closed))))

(defun lxs--advice-status (orig process)
  (let ((p (lxs--proc-of process)))
    (if (lxs--bridge-p p)
        (cond ((not (process-get p 'lxs-done)) 'run)
              ((process-get p 'lxs-killed) 'signal)
              (t 'exit))
      (funcall orig process))))

(defun lxs--advice-exit-status (orig process)
  (let ((p (lxs--proc-of process)))
    (if (lxs--bridge-p p)
        (if (process-get p 'lxs-done) (or (process-get p 'lxs-code) 0) 0)
      (funcall orig process))))

(defun lxs--advice-delete (orig &optional process)
  (let ((p (lxs--proc-of process)))
    (when (lxs--live-bridge-p p)
      (lxs--kill-bridge p 15)
      (process-put p 'lxs-done t)
      (process-put p 'lxs-closed t)
      (set-process-sentinel p #'ignore))
    (funcall orig process)))

(defun lxs--signal-advice (sig)
  "Advice for interrupt-process & co: SIG is the signal sent, nil to ignore."
  (lambda (orig &optional process current-group)
    (let ((p (lxs--proc-of process)))
      (if (lxs--bridge-p p)
          (progn (when sig (lxs--kill-bridge p sig)) p)
        (funcall orig process current-group)))))

(defun lxs--kill-buffer-hook ()
  "Stop the remote program when the buffer of a bridged process is killed."
  (let ((p (get-buffer-process (current-buffer))))
    (when (lxs--live-bridge-p p)
      (lxs--kill-bridge p 15)
      (process-put p 'lxs-done t)
      (process-put p 'lxs-closed t))))

(defun lxs--advice-signal (orig process sigcode &optional remote)
  (let ((p (lxs--proc-of process)))
    (if (lxs--bridge-p p)
        (progn (lxs--kill-bridge p sigcode) 0)
      (funcall orig process sigcode remote))))

(defun lxs--encode-for (p string)
  (if (multibyte-string-p string)
      (encode-coding-string string (or (process-get p 'lxs-coding) 'utf-8))
    string))

(defun lxs--advice-send-string (orig process string)
  (let ((p (lxs--proc-of process)))
    (cond ((not (lxs--bridge-p p)) (funcall orig process string))
          ((process-get p 'lxs-closed) (error "Process %s not running" (process-name p)))
          (t (lxs-exec-send (process-get p 'lxs-conn) (process-get p 'lxs-handle)
                            (lxs--encode-for p string))))))

(defun lxs--advice-send-region (orig process start end)
  (let ((p (lxs--proc-of process)))
    (if (lxs--bridge-p p)
        (lxs--advice-send-string nil p (buffer-substring-no-properties start end))
      (funcall orig process start end))))

(defun lxs--advice-send-eof (orig &optional process)
  (let ((p (lxs--proc-of process)))
    (cond ((not (lxs--bridge-p p)) (funcall orig process))
          ((process-get p 'lxs-closed) nil)
          (t (lxs-exec-send (process-get p 'lxs-conn) (process-get p 'lxs-handle) "" t)))))

(defun lxs--advice-coding (orig process &optional decoding encoding)
  "Bridged processes decode and encode themselves: remember the systems."
  (let ((p (lxs--proc-of process)))
    (when (lxs--bridge-p p)
      (process-put p 'lxs-decoding decoding)
      (process-put p 'lxs-coding encoding))
    (funcall orig process decoding encoding)))

(defun lxs--advice-command (orig process)
  (let ((p (lxs--proc-of process)))
    (if (lxs--bridge-p p) (process-get p 'lxs-command) (funcall orig process))))

(defun lxs--advice-accept (orig &optional process seconds millisec just-this-one)
  "Output of a bridged process arrives on the connection's process."
  (let ((p (and process (not (eq process t)) (lxs--proc-of process))))
    (if (lxs--bridge-p p)
        (funcall orig (lxs-conn-proc (process-get p 'lxs-conn)) seconds millisec just-this-one)
      (funcall orig process seconds millisec just-this-one))))

(defvar lxs--signal-advices nil)

(defun lxs-proc-install ()
  "Install the advice that makes bridged processes behave like real ones."
  (dolist (a '((interrupt-process . 2) (kill-process . 9) (quit-process . 3)
               (stop-process) (continue-process)))
    (let ((fn (or (alist-get (car a) lxs--signal-advices)
                  (setf (alist-get (car a) lxs--signal-advices)
                        (lxs--signal-advice (cdr a))))))
      (advice-add (car a) :around fn)))
  (add-hook 'kill-buffer-hook #'lxs--kill-buffer-hook)
  (dolist (a '((process-status . lxs--advice-status)
               (process-exit-status . lxs--advice-exit-status)
               (delete-process . lxs--advice-delete)
               (signal-process . lxs--advice-signal)
               (process-send-string . lxs--advice-send-string)
               (process-send-region . lxs--advice-send-region)
               (process-send-eof . lxs--advice-send-eof)
               (process-command . lxs--advice-command)
               (set-process-coding-system . lxs--advice-coding)
               (accept-process-output . lxs--advice-accept)))
    (advice-add (car a) :around (cdr a))))

(lxs-proc-install)

(provide 'lxs-proc)
;;; lxs-proc.el ends here
