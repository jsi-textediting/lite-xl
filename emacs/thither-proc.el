;;; thither-proc.el --- Processes on thither hosts  -*- lexical-binding: t; -*-

;; Version: 0.1
;; Package-Requires: ((emacs "28.1"))
;; Keywords: files, comm, processes

;;; Commentary:

;; `process-file', `make-process', `start-file-process' and `exec-path' (used
;; by `executable-find' with REMOTE) for a `default-directory' of the form
;; /thither:HOST:/dir, implemented with the server's `exec' op (no new connection
;; per process).
;;
;; Asynchronous processes are local pipe processes ("bridges"): output events
;; of the remote program are fed into the pipe process, so the caller's
;; :filter, :buffer and :coding work unchanged.  Because a pipe process has no
;; child, the status/exit/kill/send functions are advised for bridged
;; processes only.  The remote program has no tty.

;;; Code:

(require 'thither-fs)
(require 'cl-lib)
(require 'subr-x)

(defun thither--remote-shell (program)
  (if (equal program shell-file-name) "/bin/sh" program))

(defun thither--remote-command (program args)
  "Command list for PROGRAM and ARGS on the host.
The local shell becomes /bin/sh and its switch (cmd.exe's /c ...) becomes -c."
  (let ((shell (equal program shell-file-name)))
    (mapcar #'thither--arg
            (cons (thither--remote-shell program)
                  (if (and shell args (equal (car args) shell-command-switch))
                      (cons "-c" (cdr args))
                    args)))))

(defun thither--arg (a)
  "A as a string the server accepts in argv (it refuses `bin')."
  (cond ((not (stringp a)) (format "%s" a))
        ((and (not (multibyte-string-p a)) (string-match-p "[^\0-\177]" a))
         (decode-coding-string a 'utf-8))
        (t a)))

(defun thither--argv (program args)
  (thither--remote-command program args))

;;;; process-file

(defun thither--read-infile (infile)
  (cond ((null infile) nil)
        ((thither--split infile) (car (thither--read-bytes infile)))
        (t (thither--read-local infile))))

(defun thither--dest-buffer (dest)
  (cond ((eq dest t) (current-buffer))
        ((bufferp dest) dest)
        ((stringp dest) (get-buffer-create dest))
        (t nil)))

(thither--define process-file (program &optional infile buffer _display &rest args)
  (let* ((p (thither--path default-directory))
         (file-only (and (consp buffer) (eq (car buffer) :file)))
         (pair (and (consp buffer) (not file-only)))
         (real (if pair (car buffer) buffer))
         (err-dest (if pair (cadr buffer) t))
         (file-dest (and (or file-only (and (consp real) (eq (car real) :file)))
                         (cadr (if file-only buffer real))))
         (out-buf (and (not file-dest) (thither--dest-buffer real)))
         (r (condition-case err
                (thither-exec (thither-connection (car p))
                          (thither--argv program args)
                          :cwd (cdr p)
                          :stdin (thither--read-infile infile)
                          :merge-stderr (eq err-dest t)
                          :timeout 3600)
              (thither-error
               ;; like `call-process' for a program that cannot be run
               (if (equal (cadr err) "exec_failed")
                   (signal 'file-missing (list "Searching for program"
                                               "No such file or directory" program))
                 (thither--file-error err program "Running program")))))
         (out (plist-get r :stdout)))
    (when file-dest
      (let ((coding-system-for-write 'no-conversion))
        (write-region out nil file-dest nil 'silent)))
    (when out-buf
      (with-current-buffer out-buf (insert (thither--text out))))
    (when (stringp err-dest)
      (let ((coding-system-for-write 'no-conversion))
        (write-region (plist-get r :stderr) nil err-dest nil 'silent)))
    (when process-file-side-effects (thither--flush (car p)))
    (if (plist-get r :killed) "Killed" (plist-get r :code))))

(thither--define exec-path ()
  ;; `executable-find' with REMOTE searches these below the remote prefix:
  ;; the PATH the server (and so every program it runs) has.
  (append (gethash "path" (thither--host-info (car (thither--path default-directory)))) nil))

;;;; make-process: pipe-process bridges

(defun thither--proc-of (process)
  "The process designated by PROCESS (process, buffer or name), or nil."
  (cond ((processp process) process)
        ((null process) (get-buffer-process (current-buffer)))
        ((bufferp process) (get-buffer-process process))
        ((stringp process) (get-process process))))

(defun thither--bridge-p (proc) (and (processp proc) (process-get proc 'thither-conn)))

(defun thither--decode-incremental (proc bytes coding &optional final)
  "Decode BYTES appended to PROC's undecoded remainder.
Unless FINAL, an incomplete multibyte sequence at the end is kept for later."
  (let* ((all (concat (or (process-get proc 'thither-pending) "") bytes))
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
    (process-put proc 'thither-pending (and (< cut n) (substring all cut)))
    (decode-coding-string (substring all 0 cut) coding)))

(defun thither--deliver (proc bytes &optional final)
  "Hand output BYTES of the remote program to PROC's filter or buffer.
FINAL flushes bytes held back as an incomplete character."
  (let ((s (thither--decode-incremental proc bytes (process-get proc 'thither-decoding) final)))
    (unless (string-empty-p s)
      (let ((filter (process-filter proc)))
        (if (and filter (not (eq filter 'internal-default-process-filter)))
            (funcall filter proc s)
          (internal-default-process-filter proc s))))))

(defun thither--stderr-sink (stderr)
  "Function receiving stderr bytes for make-process' :stderr value STDERR."
  (cond ((bufferp stderr)
         (lambda (d)
           (when (buffer-live-p stderr)
             (with-current-buffer stderr
               (let ((inhibit-read-only t))
                 (save-excursion (goto-char (point-max)) (insert (thither--text d))))))))
        ((processp stderr) (lambda (d) (thither--deliver stderr d)))))

(defun thither--finish (proc code killed err)
  "Run PROC's sentinel once the remote program is done."
  (unless (process-get proc 'thither-done)
    (process-put proc 'thither-done t)
    ;; 127 when the program could not be started, 255 (like ssh) when the
    ;; connection was lost
    (process-put proc 'thither-code (or code (and err (if (equal (gethash "code" err) "exec_failed") 127 255))
                                    0))
    (process-put proc 'thither-killed killed)
    (when err
      (let ((sink (process-get proc 'thither-stderr)))
        (when sink (funcall sink (encode-coding-string
                                  (format "%s\n" (gethash "msg" err)) 'utf-8)))))
    (when (process-get proc 'thither-pending) (thither--deliver proc "" t))
    (let ((sentinel (process-sentinel proc))
          (event (cond (killed "killed\n")
                       ((eq 0 (process-get proc 'thither-code)) "finished\n")
                       (t (format "exited abnormally with code %d\n"
                                  (process-get proc 'thither-code))))))
      ;; Emacs must not run it again with "deleted" when the pipe goes away.
      (set-process-sentinel proc #'ignore)
      (process-put proc 'thither-closed t)
      (ignore-errors (delete-process proc))
      (when (and sentinel (not (eq sentinel 'internal-default-process-sentinel)))
        (funcall sentinel proc event)))))

(thither--define make-process (&rest args)
  (let* ((name (plist-get args :name))
         (command (plist-get args :command))
         (buffer (plist-get args :buffer))
         (coding (plist-get args :coding))
         (stderr (plist-get args :stderr))
         (p (thither--path default-directory))
         (conn (thither-connection (car p)))
         (buf (cond ((bufferp buffer) buffer)
                    ((stringp buffer) (get-buffer-create buffer))))
         (proc (make-pipe-process :name name :buffer buf :noquery t
                                  :filter (plist-get args :filter)
                                  :sentinel (plist-get args :sentinel)))
         (sink (thither--stderr-sink stderr))
         handle)
    (process-put proc 'thither-conn conn)
    (process-put proc 'thither-host (car p))
    (process-put proc 'thither-command command)
    (process-put proc 'thither-stderr sink)
    (set-process-coding-system proc
                               (or (if (consp coding) (car coding) coding)
                                   (car default-process-coding-system) 'utf-8)
                               (or (if (consp coding) (cdr coding) coding)
                                   (cdr default-process-coding-system) 'utf-8))
    (setq handle
          (thither-exec-async
           conn (thither--remote-command (car command) (cdr command))
           :cwd (cdr p) :stdin t :merge-stderr (null stderr)
           :on-stdout (lambda (d) (thither--deliver proc d))
           :on-stderr (lambda (d) (when sink (funcall sink d)))
           :on-exit (lambda (code killed err) (thither--finish proc code killed err))))
    (process-put proc 'thither-handle handle)
    proc))

(thither--define start-file-process (name buffer program &rest args)
  (funcall (gethash 'make-process thither--handlers)
           :name name :buffer buffer :command (cons program args)
           :filter nil :sentinel nil))

;;;; Advice: status, kill, stdin of bridged processes

(defun thither--signal-name (sig)
  (let ((n (cond ((numberp sig) sig)
                 ((symbolp sig) (pcase (upcase (symbol-name sig))
                                  ((or "INT" "SIGINT") 2) ((or "KILL" "SIGKILL") 9)
                                  ((or "QUIT" "SIGQUIT") 3) (_ 15)))
                 (t 15))))
    (pcase n (2 "int") (9 "kill") (_ "term"))))

(defun thither--kill-bridge (proc &optional sig)
  (unless (process-get proc 'thither-done)
    (thither-exec-kill (process-get proc 'thither-conn) (process-get proc 'thither-handle)
                   (thither--signal-name (or sig 15)))))

(defun thither--live-bridge-p (p)
  (and (thither--bridge-p p) (not (process-get p 'thither-closed))))

(defun thither--advice-status (orig process)
  (let ((p (thither--proc-of process)))
    (if (thither--bridge-p p)
        (cond ((not (process-get p 'thither-done)) 'run)
              ((process-get p 'thither-killed) 'signal)
              (t 'exit))
      (funcall orig process))))

(defun thither--advice-exit-status (orig process)
  (let ((p (thither--proc-of process)))
    (if (thither--bridge-p p)
        (if (process-get p 'thither-done) (or (process-get p 'thither-code) 0) 0)
      (funcall orig process))))

(defun thither--advice-delete (orig &optional process)
  (let ((p (thither--proc-of process)))
    (when (thither--live-bridge-p p)
      (thither--kill-bridge p 15)
      (process-put p 'thither-done t)
      (process-put p 'thither-closed t)
      (set-process-sentinel p #'ignore))
    (funcall orig process)))

(defun thither--signal-advice (sig)
  "Advice for interrupt-process & co: SIG is the signal sent, nil to ignore."
  (lambda (orig &optional process current-group)
    (let ((p (thither--proc-of process)))
      (if (thither--bridge-p p)
          (progn (when sig (thither--kill-bridge p sig)) p)
        (funcall orig process current-group)))))

(defun thither--kill-buffer-hook ()
  "Stop the remote program when the buffer of a bridged process is killed."
  (let ((p (get-buffer-process (current-buffer))))
    (when (thither--live-bridge-p p)
      (thither--kill-bridge p 15)
      (process-put p 'thither-done t)
      (process-put p 'thither-closed t))))

(defun thither--advice-signal (orig process sigcode &optional remote)
  (let ((p (thither--proc-of process)))
    (if (thither--bridge-p p)
        (progn (thither--kill-bridge p sigcode) 0)
      (funcall orig process sigcode remote))))

(defun thither--encode-for (p string)
  (if (multibyte-string-p string)
      (encode-coding-string string (or (process-get p 'thither-coding) 'utf-8))
    string))

(defun thither--advice-send-string (orig process string)
  (let ((p (thither--proc-of process)))
    (cond ((not (thither--bridge-p p)) (funcall orig process string))
          ((process-get p 'thither-closed) (error "Process %s not running" (process-name p)))
          (t (thither-exec-send (process-get p 'thither-conn) (process-get p 'thither-handle)
                            (thither--encode-for p string))))))

(defun thither--advice-send-region (orig process start end)
  (let ((p (thither--proc-of process)))
    (if (thither--bridge-p p)
        (thither--advice-send-string nil p (buffer-substring-no-properties start end))
      (funcall orig process start end))))

(defun thither--advice-send-eof (orig &optional process)
  (let ((p (thither--proc-of process)))
    (cond ((not (thither--bridge-p p)) (funcall orig process))
          ((process-get p 'thither-closed) nil)
          (t (thither-exec-send (process-get p 'thither-conn) (process-get p 'thither-handle) "" t)))))

(defun thither--advice-coding (orig process &optional decoding encoding)
  "Bridged processes decode and encode themselves: remember the systems."
  (let ((p (thither--proc-of process)))
    (when (thither--bridge-p p)
      (process-put p 'thither-decoding decoding)
      (process-put p 'thither-coding encoding))
    (funcall orig process decoding encoding)))

(defun thither--advice-command (orig process)
  (let ((p (thither--proc-of process)))
    (if (thither--bridge-p p) (process-get p 'thither-command) (funcall orig process))))

(defun thither--advice-accept (orig &optional process seconds millisec just-this-one)
  "Output of a bridged process arrives on the connection's process."
  (let ((p (and process (not (eq process t)) (thither--proc-of process))))
    (if (thither--bridge-p p)
        (funcall orig (thither-conn-proc (process-get p 'thither-conn)) seconds millisec just-this-one)
      (funcall orig process seconds millisec just-this-one))))

(defvar thither--signal-advices nil)

(defun thither-proc-install ()
  "Install the advice that makes bridged processes behave like real ones."
  (dolist (a '((interrupt-process . 2) (kill-process . 9) (quit-process . 3)
               (stop-process) (continue-process)))
    (let ((fn (or (alist-get (car a) thither--signal-advices)
                  (setf (alist-get (car a) thither--signal-advices)
                        (thither--signal-advice (cdr a))))))
      (advice-add (car a) :around fn)))
  (add-hook 'kill-buffer-hook #'thither--kill-buffer-hook)
  (dolist (a '((process-status . thither--advice-status)
               (process-exit-status . thither--advice-exit-status)
               (delete-process . thither--advice-delete)
               (signal-process . thither--advice-signal)
               (process-send-string . thither--advice-send-string)
               (process-send-region . thither--advice-send-region)
               (process-send-eof . thither--advice-send-eof)
               (process-command . thither--advice-command)
               (set-process-coding-system . thither--advice-coding)
               (accept-process-output . thither--advice-accept)))
    (advice-add (car a) :around (cdr a))))

(thither-proc-install)

(provide 'thither-proc)
;;; thither-proc.el ends here
