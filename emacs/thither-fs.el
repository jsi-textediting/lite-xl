;;; thither-fs.el --- File name handler for /thither:HOST:/path  -*- lexical-binding: t; -*-

;; Version: 0.1
;; Package-Requires: ((emacs "28.1"))
;; Keywords: files, comm, processes

;;; Commentary:

;; Makes names of the form /thither:HOST:/absolute/path behave like local files by
;; answering Emacs file operations with thither-server requests (see thither.el).
;; Process operations (process-file, make-process, ...) are in thither-proc.el.
;;
;; Connections are created on first use, one per HOST, through
;; `thither-command-function'.  Metadata (stat, readdir, realpath) is cached for
;; `thither-cache-ttl' seconds and flushed by every operation that writes.

;;; Code:

(require 'thither)
(require 'cl-lib)
(require 'subr-x)
(require 'files-x)

(defgroup thither-fs nil "File name handler for thither-server." :group 'thither)

(defcustom thither-command-function #'thither-default-command
  "Function of one argument, HOST, returning the server command list."
  :type 'function)

(defcustom thither-cache-ttl 3
  "Seconds metadata (stat, readdir, realpath) is reused."
  :type 'number)

(defconst thither-file-name-regexp "\\`/thither:[^:/]+:")

(defun thither-default-command (host)
  (list "ssh" "-T" host "thither-server" "--stdio"))

;;;; Names

(defun thither--split (name)
  "Return (HOST . LOCALNAME) for an thither file NAME, or nil."
  (when (and (stringp name) (string-match "\\`/thither:\\([^:/]+\\):" name))
    (cons (match-string 1 name) (substring name (match-end 0)))))

(defun thither--make (host local) (concat "/thither:" host ":" local))

(defun thither--parse (name)
  (or (thither--split name) (error "Not an thither file name: %s" name)))

(defun thither--tilde (host local)
  "Expand a leading ~ of LOCAL with HOST's home directory."
  (cond ((string= local "") (thither--home host))
        ((string= local "~") (thither--home host))
        ((string-prefix-p "~/" local)
         (concat (directory-file-name (thither--home host)) (substring local 1)))
        (t local)))

(defun thither--normalize (host local)
  "Absolute, normalized LOCAL (no ., .., // ; trailing slash kept)."
  (let* ((local (thither--tilde host local))
         (trail (and (> (length local) 1) (string-suffix-p "/" local)))
         parts)
    (dolist (p (split-string local "/" t))
      (cond ((string= p "."))
            ((string= p "..") (pop parts))
            (t (push p parts))))
    (let ((s (concat "/" (mapconcat #'identity (nreverse parts) "/"))))
      (if (and trail (not (string= s "/"))) (concat s "/") s))))

(defun thither--path (file)
  "Return (HOST . ABSOLUTE-LOCALNAME) for the thither name FILE."
  (let ((p (thither--parse file)))
    (cons (car p) (thither--normalize (car p) (cdr p)))))

;;;; Connections and cache

(defvar thither--connections (make-hash-table :test 'equal))
(defvar thither--cache (make-hash-table :test 'equal))

(defun thither-connection (host)
  "The live connection for HOST, connecting if needed."
  (let ((c (gethash host thither--connections)))
    (if (and c (thither-alive-p c))
        c
      (setq c (condition-case err
                  (thither-connect (funcall thither-command-function host))
                (error (signal 'file-error
                               (list "Cannot connect to thither host" host
                                     (error-message-string err))))))
      (puthash host c thither--connections)
      (thither--flush host)
      c)))

(defun thither-disconnect (host)
  (let ((c (gethash host thither--connections)))
    (when c (thither-close c) (remhash host thither--connections) (thither--flush host))))

(defun thither--home (host)
  (gethash "home" (thither-conn-hello (thither-connection host))))

(defvar thither--host-infos (make-hash-table :test 'eq :weakness 'key)
  "Connection -> result of the server's `host_info' (account, PATH, ...).")

(defun thither--host-info (host)
  "The server's `host_info' for HOST (fetched once per connection)."
  (let ((c (thither-connection host)))
    (or (gethash c thither--host-infos)
        (puthash c (thither--io (concat "/thither:" host ":") "Querying host"
                     (thither-call-sync c "host_info"))
                 thither--host-infos))))

(defun thither--flush (host)
  (let (dead)
    (maphash (lambda (k _) (when (equal (car k) host) (push k dead))) thither--cache)
    (dolist (k dead) (remhash k thither--cache))))

(defun thither--cached (host kind path fresh fn)
  (let* ((key (list host kind path))
         (hit (and (not fresh) (gethash key thither--cache))))
    (if (and hit (< (- (float-time) (car hit)) thither-cache-ttl))
        (cdr hit)
      (let ((v (funcall fn)))
        (puthash key (cons (float-time) v) thither--cache)
        v))))

;;;; Text

(defun thither--text (bytes &optional coding)
  "Decode the unibyte string BYTES (output of the host) as text."
  (decode-coding-string bytes (or coding coding-system-for-read 'utf-8)))

;;;; Errors

(defun thither--file-error (err file what)
  "Re-signal the `thither-error' ERR as the matching Emacs file error."
  (let* ((code (cadr err)) (msg (or (caddr err) code)))
    (cond ((member code '("ENOENT" "ENOTDIR"))
           (signal 'file-missing (list what "No such file or directory" file)))
          ((equal code "EEXIST")
           (signal 'file-already-exists (list what "File exists" file)))
          ((member code '("EACCES" "EPERM"))
           (signal 'permission-denied (list what "Permission denied" file)))
          ((equal code "EISDIR") (signal 'file-error (list what "Is a directory" file)))
          ((equal code "conflict") (signal 'file-error (list what "File changed on the host" file)))
          ((equal code "unknown_op")
           (signal 'file-error
                   (list what (format "thither-server on the host is too old (%s); upgrade it" msg)
                         file)))
          (t (signal 'file-error (list what msg file))))))

(defmacro thither--io (file what &rest body)
  "Run BODY, turning `thither-error' into the matching file error for FILE."
  (declare (indent 2))
  `(condition-case err (progn ,@body)
     (thither-error (thither--file-error err ,file ,what))))

(defun thither--missing-p (err)
  (member (cadr err) '("ENOENT" "ENOTDIR" "EACCES" "ELOOP")))

;;;; Stat

(defun thither--stat (host path &optional nofollow fresh)
  "Stat table of PATH on HOST, or nil when it is not there."
  (let ((v (thither--cached
            host (if nofollow 'lstat 'stat) path fresh
            (lambda ()
              (condition-case err
                  (thither-call-sync (thither-connection host) "stat"
                                 `(("path" . ,path) ("nofollow" . ,(and nofollow t))))
                (thither-error (if (thither--missing-p err) :none (signal (car err) (cdr err)))))))))
    (and (not (eq v :none)) v)))

(defun thither--mode-string (type mode)
  (let ((bits "rwxrwxrwx") (s (make-string 10 ?-)))
    (aset s 0 (pcase type ("dir" ?d) ("symlink" ?l) (_ ?-)))
    (dotimes (i 9)
      (when (/= 0 (logand mode (ash 1 (- 8 i)))) (aset s (1+ i) (aref bits i))))
    (when (/= 0 (logand mode #o4000)) (aset s 3 (if (eq (aref s 3) ?x) ?s ?S)))
    (when (/= 0 (logand mode #o2000)) (aset s 6 (if (eq (aref s 6) ?x) ?s ?S)))
    (when (/= 0 (logand mode #o1000)) (aset s 9 (if (eq (aref s 9) ?x) ?t ?T)))
    s))

(defun thither--time (st key)
  (time-convert (cons (or (gethash key st) 0) 1000000000) 'list))

(defun thither--attributes (st &optional lstat)
  "The 12 element `file-attributes' list for stat table ST."
  (let* ((type (gethash "type" st))
         (link (and (gethash "is_link" st) (gethash "link" st)))
         (mtime (thither--time st "mtime_ns")))
    (list (cond ((and lstat link) link) ((equal type "dir") t) (t nil))
          1 (or (gethash "uid" st) 0) (or (gethash "gid" st) 0)
          mtime mtime mtime
          (or (gethash "size" st) 0)
          (thither--mode-string (if (and lstat link) "symlink" type) (or (gethash "mode" st) 0))
          t (or (gethash "ino" st) 0) 0)))

;;;; Handler

(defvar thither--handlers (make-hash-table :test 'eq))

(defmacro thither--define (op args &rest body)
  "Define the handler for file operation OP."
  (declare (indent 2))
  `(puthash ',op (lambda ,args ,@body) thither--handlers))

(defun thither--real (op args)
  "Run OP on ARGS with this handler disabled."
  ;; Every handler is inhibited: TRAMP's matches /thither:host: names too and
  ;; would reject the unknown method.
  (let ((inhibit-file-name-handlers
         (append (mapcar #'cdr file-name-handler-alist)
                 (and (eq inhibit-file-name-operation op) inhibit-file-name-handlers)))
        (inhibit-file-name-operation op))
    (apply op args)))

(defun thither-file-name-handler (operation &rest args)
  (let ((fn (gethash operation thither--handlers)))
    (if fn (apply fn args) (thither--real operation args))))

;;;###autoload
(defun thither-fs-enable ()
  "Register the /thither:HOST:/ file name handler."
  (unless (rassq #'thither-file-name-handler file-name-handler-alist)
    (push (cons thither-file-name-regexp #'thither-file-name-handler) file-name-handler-alist)))

;;;; Name operations

(thither--define expand-file-name (name &optional dir)
  (let* ((dir (or dir default-directory))
         (n (thither--split name)))
    (cond (n (thither--make (car n) (thither--normalize (car n) (cdr n))))
          ((or (file-name-absolute-p name) (string-prefix-p "~" name))
           (thither--real 'expand-file-name (list name nil)))
          (t (let ((d (thither--parse dir)))
               (thither--make (car d) (thither--normalize
                                   (car d) (concat (file-name-as-directory (cdr d)) name))))))))

(thither--define directory-file-name (dir)
  ;; the host root keeps its slash: "/thither:h:" would be the home directory
  (let ((n (thither--split dir)))
    (if (and n (string-match-p "\\`/+\\'" (cdr n)))
        (thither--make (car n) "/")
      (thither--real 'directory-file-name (list dir)))))

(thither--define file-name-directory (file)
  (let ((n (thither--split file)))
    (if (and n (not (string-match-p "/" (cdr n))))
        (thither--make (car n) "")
      (thither--real 'file-name-directory (list file)))))

(thither--define substitute-in-file-name (file)
  ;; "//" and "/~" restart the name on the same host, as with TRAMP
  (let ((n (thither--split file)))
    (if (not n)
        (thither--real 'substitute-in-file-name (list file))
      (let ((local (thither--real 'substitute-in-file-name (list (cdr n)))))
        (if (thither--split local) local (thither--make (car n) local))))))

(thither--define file-remote-p (file &optional identification connected)
  (let ((p (thither--split file)))
    (when (and p (or (not connected)
                     (let ((c (gethash (car p) thither--connections))) (and c (thither-alive-p c)))))
      (pcase identification
        ('method "thither")
        ('host (car p))
        ('localname (cdr p))
        ('user nil)
        ('hop nil)
        (_ (concat "/thither:" (car p) ":"))))))

(thither--define unhandled-file-name-directory (_filename) (expand-file-name "~/"))
(thither--define file-name-case-insensitive-p (_f) nil)
(thither--define file-locked-p (_f) nil)
(thither--define lock-file (_f) nil)
(thither--define unlock-file (_f) nil)
(thither--define vc-registered (_f) nil)

(thither--define make-auto-save-file-name ()
  (expand-file-name (concat "thither-auto-" (md5 (or buffer-file-name (buffer-name))) "#")
                    temporary-file-directory))

;;;; Queries

(defun thither--st (file &optional nofollow fresh)
  (let ((p (thither--path file))) (thither--stat (car p) (cdr p) nofollow fresh)))

(thither--define file-exists-p (f) (and (thither--st f) t))
(defun thither--type (f)
  (let ((st (thither--st f))) (and st (gethash "type" st))))

(thither--define file-directory-p (f) (equal "dir" (thither--type f)))
(thither--define file-regular-p (f) (equal "file" (thither--type f)))
(thither--define file-symlink-p (f)
  (let ((st (thither--st f t))) (and st (gethash "is_link" st) (gethash "link" st))))

(defun thither--access-p (f bit)
  "Non-nil when the server's user may do BIT (4 read, 2 write, 1 execute) on F.
The server answers with access(2), so ACLs, read-only mounts and root are right."
  (when (thither--st f)
    (let ((p (thither--path f)))
      (eq t (thither--cached
             (car p) 'access (cons (cdr p) bit) nil
             (lambda ()
               (condition-case err
                   (thither-call-sync (thither-connection (car p)) "access"
                                  `(("path" . ,(cdr p)) ("mode" . ,bit)))
                 (thither-error (if (thither--missing-p err) :false
                              (thither--file-error err f "Checking access"))))))))))

(thither--define file-readable-p (f) (and (thither--access-p f 4) t))
(thither--define file-executable-p (f) (and (thither--access-p f 1) t))
(thither--define file-accessible-directory-p (f)
  (and (equal "dir" (thither--type f)) (thither--access-p f 1) t))
(thither--define file-writable-p (f)
  (if (thither--st f)
      (and (thither--access-p f 2) t)
    (let ((dir (file-name-directory (directory-file-name (expand-file-name f)))))
      (and dir (not (equal dir f)) (file-directory-p dir) (file-writable-p dir)))))

(thither--define file-modes (f &optional _flag)
  (let ((st (thither--st f))) (and st (logand (or (gethash "mode" st) 0) #o7777))))

(thither--define file-attributes (f &optional _id-format)
  (let ((st (thither--st f t))) (and st (thither--attributes st t))))

(thither--define file-newer-than-file-p (f1 f2)
  (let ((a (file-attributes f1)) (b (file-attributes f2)))
    (cond ((null a) nil)
          ((null b) t)
          (t (time-less-p (file-attribute-modification-time b)
                          (file-attribute-modification-time a))))))

(thither--define file-truename (f)
  (let* ((p (thither--path f)) (host (car p)))
    (if (not (thither--stat host (cdr p)))
        (thither--make host (cdr p))
      (let ((real (thither--cached host 'realpath (cdr p) nil
                               (lambda ()
                                 (condition-case nil
                                     (thither-call-sync (thither-connection host) "realpath"
                                                    `(("path" . ,(cdr p))))
                                   (thither-error (cdr p)))))))
        (thither--make host (if (and (string-suffix-p "/" f) (not (string= real "/")))
                            (concat real "/") real))))))

;;;; Listing

(defun thither--readdir (host path &optional fresh)
  "List of stat tables (with \"name\") for directory PATH."
  (thither--cached host 'readdir path fresh
               (lambda ()
                 (thither-readdir (thither-connection host) path))))

(defun thither--readdir-io (file)
  (let ((p (thither--path file)))
    (thither--io file "Reading directory"
      (thither--readdir (car p) (cdr p)))))

(defun thither--entry-names (entries)
  (let ((names (mapcar (lambda (e) (gethash "name" e)) entries)))
    names))

(thither--define directory-files (dir &optional full match nosort count)
  (let* ((entries (thither--readdir-io dir))
         (names (append '("." "..") (thither--entry-names entries)))
         (names (if match (cl-remove-if-not (lambda (n) (string-match-p match n)) names) names))
         (names (if nosort names (sort names #'string<)))
         (names (if (and count (< count (length names))) (seq-take names count) names)))
    (if full
        (let ((d (file-name-as-directory (thither--expand-name dir))))
          (mapcar (lambda (n) (concat d n)) names))
      names)))

(defun thither--expand-name (f) (expand-file-name f))

(thither--define directory-files-and-attributes (dir &optional full match nosort id-format count)
  (let* ((p (thither--path dir))
         (entries (thither--readdir-io dir))
         (self (thither--stat (car p) (cdr p)))
         (up (thither--stat (car p) (thither--normalize (car p) (concat (cdr p) "/.."))))
         (all (append (and self (list (cons "." (thither--attributes self))))
                      (and up (list (cons ".." (thither--attributes up))))
                      (mapcar (lambda (e) (cons (gethash "name" e) (thither--attributes e t)))
                              entries)))
         (all (if match (cl-remove-if-not (lambda (e) (string-match-p match (car e))) all) all))
         (all (if nosort all (sort all (lambda (a b) (string< (car a) (car b))))))
         (all (if (and count (< count (length all))) (seq-take all count) all)))
    (ignore id-format)
    (if full
        (let ((d (file-name-as-directory (thither--expand-name dir))))
          (mapcar (lambda (e) (cons (concat d (car e)) (cdr e))) all))
      all)))

(defun thither--completion-names (dir)
  (append '("./" "../")
          (mapcar (lambda (e)
                    (let ((n (gethash "name" e)))
                      (if (equal (gethash "type" e) "dir") (concat n "/") n)))
                  (thither--readdir-io dir))))

(thither--define file-name-all-completions (file dir)
  (let ((case-fold-search nil))
    (cl-remove-if-not (lambda (n) (string-prefix-p file n completion-ignore-case))
                      (thither--completion-names dir))))

(thither--define file-name-completion (file dir &optional predicate)
  (let* ((all (thither--completion-names dir))
         (all (if predicate
                  (cl-remove-if-not (lambda (n) (funcall predicate (expand-file-name n dir)))
                                    all)
                all))
         (ignored (and completion-ignored-extensions
                       (concat (regexp-opt completion-ignored-extensions) "\\'")))
         (kept (if ignored
                   (cl-remove-if (lambda (n) (and (not (string-suffix-p "/" n))
                                                  (string-match-p ignored n)))
                                 all)
                 all))
         ;; like Emacs: ignored suffixes only lose when something else matches
         (names (if (and ignored (try-completion file kept)) kept all)))
    (try-completion file names)))

;;;; Reading and writing

(defvar-local thither--visited-etag nil
  "Etag of the remote file this buffer was read from or saved to.")

(defun thither--temp-file (file)
  (make-temp-file "thither-" nil (file-name-extension file t)))

(defun thither--read-bytes (file)
  "Return (DATA . ETAG) of the thither FILE."
  (let ((p (thither--path file)))
    (thither--io file "Opening input file"
      (let ((st (thither--stat (car p) (cdr p) nil t)))
        (when (and st (equal "dir" (gethash "type" st)))
          (signal 'file-error (list "Read error" "Is a directory" file))))
      (thither-read-file (thither-connection (car p)) (cdr p)))))

(thither--define insert-file-contents (filename &optional visit beg end replace)
  (barf-if-buffer-read-only)
  (let* ((res (condition-case err (thither--read-bytes filename)
                (file-missing
                 ;; Like the C function: a visited missing file still names the buffer.
                 (when visit
                   (setq buffer-file-name (thither--expand-name filename)
                         thither--visited-etag nil)
                   (set-buffer-modified-p nil))
                 (signal (car err) (cdr err)))))
         (tmp (thither--temp-file filename))
         ret)
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'no-conversion))
            (write-region (car res) nil tmp nil 'silent))
          (setq ret (thither--real 'insert-file-contents (list tmp visit beg end replace))))
      (ignore-errors (delete-file tmp)))
    (when visit
      (setq buffer-file-name (thither--expand-name filename)
            thither--visited-etag (cdr res))
      (setq buffer-read-only (not (file-writable-p filename)))
      (set-buffer-modified-p nil))
    (list (thither--expand-name filename) (cadr ret))))

(thither--define file-local-copy (file)
  (let ((res (thither--read-bytes file)) (tmp (thither--temp-file file)))
    (let ((coding-system-for-write 'no-conversion))
      (write-region (car res) nil tmp nil 'silent))
    tmp))

(defun thither--region-bytes (start end)
  "Bytes of the region (or string START), encoded as `write-region' would."
  (let ((tmp (make-temp-file "thither-")) (coding-system-for-write coding-system-for-write))
    (unwind-protect
        (progn
          (write-region start end tmp nil 'silent)
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally tmp)
            (buffer-string)))
      (ignore-errors (delete-file tmp)))))

(thither--define write-region (start end filename &optional append visit lockname mustbenew)
  (ignore lockname)
  (when (numberp append) (error "thither: numeric APPEND is not supported"))
  (let* ((name (thither--expand-name filename))
         (p (thither--path filename))
         (whole (or (and (null start) (null end))
                    (and (integerp start) (= start (point-min)) (= end (point-max)))))
         (data (if (and (stringp start) (not (multibyte-string-p start)))
                   start
                 (thither--region-bytes start end)))
         ;; Etag the buffer was read from: a save over a changed file conflicts.
         (expect (cond ((eq mustbenew 'excl) "-")
                       ((and whole (equal buffer-file-name name)) thither--visited-etag))))
    (when (and mustbenew (not (eq mustbenew 'excl)) (thither--stat (car p) (cdr p) nil t)
               (not (y-or-n-p (format "File %s exists; overwrite? " name))))
      (signal 'file-already-exists (list "File exists" name)))
    (when append
      ;; only a missing file counts as empty; the old contents pin the etag
      (let ((old (and (thither--stat (car p) (cdr p) nil t)
                      (thither--io filename "Opening output file"
                        (thither-read-file (thither-connection (car p)) (cdr p))))))
        (setq data (concat (or (car old) "") data) expect (if old (cdr old) "-"))))
    (let* ((st (thither--io filename "Opening output file"
                 (condition-case err
                     (prog1 (thither-write-file (thither-connection (car p)) (cdr p) data expect)
                       (thither--flush (car p)))
                   (thither-error
                    (thither--flush (car p))
                    (if (and (eq mustbenew 'excl) (equal (cadr err) "conflict"))
                        (signal 'file-already-exists (list "File exists" name))
                      (signal (car err) (cdr err)))))))
           ;; VISIT a string: the buffer visits that name (file-precious-flag
           ;; writes a temp file that is then renamed over it)
           (visited (cond ((eq visit t) name)
                          ((stringp visit) (expand-file-name visit)))))
      (when visited
        (setq buffer-file-name visited
              thither--visited-etag (and (thither--same-host visited name) (gethash "etag" st)))
        (set-buffer-modified-p nil))
      (when (and (or (null visit) (eq visit t) (stringp visit)) (not noninteractive))
        (message "Wrote %s" (or visited name)))
      nil)))

(thither--define verify-visited-file-modtime (&optional buf)
  (with-current-buffer (or buf (current-buffer))
    (if (or (null thither--visited-etag) (null buffer-file-name)
            (not (thither--split buffer-file-name)))
        t
      (let ((st (thither--st buffer-file-name nil t)))
        (and st (equal (gethash "etag" st) thither--visited-etag))))))

(thither--define set-visited-file-modtime (&optional _time)
  (when (and buffer-file-name (thither--split buffer-file-name))
    (let ((st (thither--st buffer-file-name nil t)))
      (setq thither--visited-etag (and st (gethash "etag" st))))))

(thither--define visited-file-modtime ()
  (if thither--visited-etag 0 0))

;;;; Mutation

(defun thither--call (host op args file what)
  (prog1 (thither--io file what (thither-call-sync (thither-connection host) op args))
    (thither--flush host)))

(thither--define make-directory (dir &optional parents)
  (let ((p (thither--path dir)))
    (thither--call (car p) "mkdir" `(("path" . ,(directory-file-name (cdr p))) ("parents" . ,(and parents t)))
               dir "Creating directory")
    nil))

(thither--define delete-file (f &optional _trash)
  (let ((p (thither--path f)))
    (condition-case err
        (thither--call (car p) "remove" `(("path" . ,(cdr p))) f "Deleting file")
      (file-missing nil)
      (error (signal (car err) (cdr err))))
    nil))

(thither--define delete-directory (dir &optional recursive _trash)
  (let ((p (thither--path dir)))
    (thither--call (car p) "remove" `(("path" . ,(directory-file-name (cdr p)))
                                  ("recursive" . ,(and recursive t)))
               dir "Removing directory")
    nil))

(defun thither--confirm-overwrite (newname ok)
  (when (file-exists-p newname)
    (cond ((eq ok t))
          ((numberp ok)
           (unless (yes-or-no-p (format "File %s already exists; overwrite? " newname))
             (signal 'file-already-exists (list "File already exists" newname))))
          (t (signal 'file-already-exists (list "File already exists" newname))))))

(defun thither--same-host (a b)
  (let ((pa (thither--split a)) (pb (thither--split b)))
    (and pa pb (equal (car pa) (car pb)))))

(thither--define rename-file (file newname &optional ok)
  (let ((newname (if (directory-name-p newname)
                     (expand-file-name (file-name-nondirectory file) newname)
                   newname)))
    (thither--confirm-overwrite newname ok)
    (if (thither--same-host file newname)
        (let ((a (thither--path file)) (b (thither--path newname)))
          (thither--call (car a) "rename" `(("from" . ,(cdr a)) ("to" . ,(cdr b)) ("overwrite" . t))
                     file "Renaming"))
      (copy-file file newname t t)
      (if (file-directory-p file) (delete-directory file t) (delete-file file)))
    nil))

(defun thither--read-local (file)
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(thither--define copy-file (file newname &optional ok keep-time _uid _perm)
  (let ((newname (if (directory-name-p newname)
                     (expand-file-name (file-name-nondirectory file) newname)
                   newname)))
    (thither--confirm-overwrite newname ok)
    (cond
     ((thither--same-host file newname)
      (let ((a (thither--path file)) (b (thither--path newname)))
        (thither--call (car a) "copy" `(("from" . ,(cdr a)) ("to" . ,(cdr b))
                                    ("keep_time" . ,(and keep-time t)))
                   file "Copying")))
     ((thither--split newname)
      (let ((b (thither--path newname))
            (data (if (thither--split file) (car (thither--read-bytes file)) (thither--read-local file))))
        (thither--io newname "Copying" (thither-write-file (thither-connection (car b)) (cdr b) data))
        (thither--flush (car b))))
     (t
      (let ((res (thither--read-bytes file)))
        (let ((coding-system-for-write 'no-conversion))
          (write-region (car res) nil newname nil 'silent)))))
    nil))

(thither--define make-symbolic-link (target linkname &optional ok)
  (let ((p (thither--path linkname)))
    (when (and (not (eq ok t)) (thither--stat (car p) (cdr p) t t))
      (signal 'file-already-exists (list "File exists" linkname)))
    (thither--call (car p) "symlink" `(("target" . ,(or (file-remote-p target 'localname) target))
                                   ("path" . ,(cdr p)) ("overwrite" . t))
               linkname "Making symbolic link")
    nil))

(thither--define add-name-to-file (file newname &optional ok)
  (unless (thither--same-host file newname)
    (signal 'file-error (list "Adding new name" "Hard links cannot cross hosts" newname)))
  (let ((a (thither--path file)) (b (thither--path newname)))
    (thither--confirm-overwrite newname ok)
    (thither--call (car a) "link" `(("from" . ,(cdr a)) ("to" . ,(cdr b)) ("overwrite" . t))
               file "Adding new name")
    nil))

(thither--define set-file-modes (f mode &optional _flag)
  (let ((p (thither--path f)))
    (thither--call (car p) "chmod" `(("path" . ,(cdr p)) ("mode" . ,mode)) f "Doing chmod")
    nil))

(thither--define set-file-times (f &optional time _flag)
  (let ((p (thither--path f)))
    ;; nil TIME: now, by the server's clock
    (thither--call (car p) "utime"
               `(("path" . ,(cdr p))
                 ("mtime_ns" . ,(and time (car (time-convert time 1000000000)))))
               f "Setting file times")
    t))

;;;; Directory listings for dired

(defconst thither--glob-chars "[*?[]")

(thither--define insert-directory (file switches &optional wildcard full-directory-p)
  (let* ((p (thither--path file))
         (switches (cond ((stringp switches) (split-string switches))
                         ((listp switches) switches)))
         (switches (cl-remove-if (lambda (s) (string-prefix-p "--dired" s)) switches))
         (name (cdr p))
         (cmd
          (cond
           ((and wildcard (string-match-p thither--glob-chars (file-name-nondirectory name)))
            ;; let the remote shell expand the pattern, as Tramp does
            (list "/bin/sh" "-c"
                  (concat "ls " (mapconcat #'shell-quote-argument switches " ") " -- "
                          (shell-quote-argument (or (file-name-directory name) "/"))
                          (file-name-nondirectory name))))
           (full-directory-p
            `("ls" ,@switches "--" ,(file-name-as-directory name)))
           (t `("ls" ,@switches "--" ,name))))
         (r (thither-exec (thither-connection (car p)) cmd :env '(("LC_ALL" . "C")))))
    (insert (decode-coding-string (plist-get r :stdout) 'utf-8))
    (unless (zerop (or (plist-get r :code) 0))
      (let ((err (string-trim (decode-coding-string (plist-get r :stderr) 'utf-8))))
        (when (string-match-p "No such file" err)
          (signal 'file-missing (list "Reading directory" "No such file or directory" file)))
        (message "%s" err)))
    nil))

(provide 'thither-fs)
;;; thither-fs.el ends here
