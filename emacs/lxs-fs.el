;;; lxs-fs.el --- File name handler for /lxs:HOST:/path  -*- lexical-binding: t; -*-

;; Version: 0.1
;; Package-Requires: ((emacs "28.1"))
;; Keywords: files, comm, processes

;;; Commentary:

;; Makes names of the form /lxs:HOST:/absolute/path behave like local files by
;; answering Emacs file operations with lite-xl-server requests (see lxs.el).
;; Process operations (process-file, make-process, ...) are in lxs-proc.el.
;;
;; Connections are created on first use, one per HOST, through
;; `lxs-command-function'.  Metadata (stat, readdir, realpath) is cached for
;; `lxs-cache-ttl' seconds and flushed by every operation that writes.

;;; Code:

(require 'lxs)
(require 'cl-lib)
(require 'subr-x)

(defgroup lxs-fs nil "File name handler for lite-xl-server." :group 'lxs)

(defcustom lxs-command-function #'lxs-default-command
  "Function of one argument, HOST, returning the server command list."
  :type 'function)

(defcustom lxs-cache-ttl 3
  "Seconds metadata (stat, readdir, realpath) is reused."
  :type 'number)

(defconst lxs-file-name-regexp "\\`/lxs:[^:/]+:")

(defun lxs-default-command (host)
  (list "ssh" "-T" host "lite-xl-server" "--stdio"))

;;;; Names

(defun lxs--split (name)
  "Return (HOST . LOCALNAME) for an lxs file NAME, or nil."
  (when (and (stringp name) (string-match "\\`/lxs:\\([^:/]+\\):" name))
    (cons (match-string 1 name) (substring name (match-end 0)))))

(defun lxs--make (host local) (concat "/lxs:" host ":" local))

(defun lxs--parse (name)
  (or (lxs--split name) (error "Not an lxs file name: %s" name)))

(defun lxs--tilde (host local)
  "Expand a leading ~ of LOCAL with HOST's home directory."
  (cond ((string= local "") (lxs--home host))
        ((string= local "~") (lxs--home host))
        ((string-prefix-p "~/" local)
         (concat (directory-file-name (lxs--home host)) (substring local 1)))
        (t local)))

(defun lxs--normalize (host local)
  "Absolute, normalized LOCAL (no ., .., // ; trailing slash kept)."
  (let* ((local (lxs--tilde host local))
         (trail (and (> (length local) 1) (string-suffix-p "/" local)))
         parts)
    (dolist (p (split-string local "/" t))
      (cond ((string= p "."))
            ((string= p "..") (pop parts))
            (t (push p parts))))
    (let ((s (concat "/" (mapconcat #'identity (nreverse parts) "/"))))
      (if (and trail (not (string= s "/"))) (concat s "/") s))))

(defun lxs--path (file)
  "Return (HOST . ABSOLUTE-LOCALNAME) for the lxs name FILE."
  (let ((p (lxs--parse file)))
    (cons (car p) (lxs--normalize (car p) (cdr p)))))

;;;; Connections and cache

(defvar lxs--connections (make-hash-table :test 'equal))
(defvar lxs--cache (make-hash-table :test 'equal))

(defun lxs-connection (host)
  "The live connection for HOST, connecting if needed."
  (let ((c (gethash host lxs--connections)))
    (if (and c (lxs-alive-p c))
        c
      (setq c (condition-case err
                  (lxs-connect (funcall lxs-command-function host))
                (error (signal 'file-error
                               (list "Cannot connect to lxs host" host
                                     (error-message-string err))))))
      (puthash host c lxs--connections)
      (lxs--flush host)
      c)))

(defun lxs-disconnect (host)
  (let ((c (gethash host lxs--connections)))
    (when c (lxs-close c) (remhash host lxs--connections) (lxs--flush host))))

(defun lxs--home (host)
  (gethash "home" (lxs-conn-hello (lxs-connection host))))

(defun lxs--flush (host)
  (let (dead)
    (maphash (lambda (k _) (when (equal (car k) host) (push k dead))) lxs--cache)
    (dolist (k dead) (remhash k lxs--cache))))

(defun lxs--cached (host kind path fresh fn)
  (let* ((key (list host kind path))
         (hit (and (not fresh) (gethash key lxs--cache))))
    (if (and hit (< (- (float-time) (car hit)) lxs-cache-ttl))
        (cdr hit)
      (let ((v (funcall fn)))
        (puthash key (cons (float-time) v) lxs--cache)
        v))))

;;;; Text

(defun lxs--text (bytes &optional coding)
  "Decode the unibyte string BYTES (output of the host) as text."
  (decode-coding-string bytes (or coding coding-system-for-read 'utf-8)))

;;;; Errors

(defun lxs--file-error (err file what)
  "Re-signal the `lxs-error' ERR as the matching Emacs file error."
  (let* ((code (cadr err)) (msg (or (caddr err) code)))
    (cond ((member code '("ENOENT" "ENOTDIR"))
           (signal 'file-missing (list what "No such file or directory" file)))
          ((equal code "EEXIST")
           (signal 'file-already-exists (list what "File exists" file)))
          ((member code '("EACCES" "EPERM"))
           (signal 'permission-denied (list what "Permission denied" file)))
          ((equal code "EISDIR") (signal 'file-error (list what "Is a directory" file)))
          ((equal code "conflict") (signal 'file-error (list what "File changed on the host" file)))
          (t (signal 'file-error (list what msg file))))))

(defmacro lxs--io (file what &rest body)
  "Run BODY, turning `lxs-error' into the matching file error for FILE."
  (declare (indent 2))
  `(condition-case err (progn ,@body)
     (lxs-error (lxs--file-error err ,file ,what))))

(defun lxs--missing-p (err)
  (member (cadr err) '("ENOENT" "ENOTDIR" "EACCES" "ELOOP")))

;;;; Stat

(defun lxs--stat (host path &optional nofollow fresh)
  "Stat table of PATH on HOST, or nil when it is not there."
  (let ((v (lxs--cached
            host (if nofollow 'lstat 'stat) path fresh
            (lambda ()
              (condition-case err
                  (lxs-call-sync (lxs-connection host) "stat"
                                 `(("path" . ,path) ("nofollow" . ,(and nofollow t))))
                (lxs-error (if (lxs--missing-p err) :none (signal (car err) (cdr err)))))))))
    (and (not (eq v :none)) v)))

(defun lxs--mode-string (type mode)
  (let ((bits "rwxrwxrwx") (s (make-string 10 ?-)))
    (aset s 0 (pcase type ("dir" ?d) ("symlink" ?l) (_ ?-)))
    (dotimes (i 9)
      (when (/= 0 (logand mode (ash 1 (- 8 i)))) (aset s (1+ i) (aref bits i))))
    (when (/= 0 (logand mode #o4000)) (aset s 3 (if (eq (aref s 3) ?x) ?s ?S)))
    (when (/= 0 (logand mode #o2000)) (aset s 6 (if (eq (aref s 6) ?x) ?s ?S)))
    (when (/= 0 (logand mode #o1000)) (aset s 9 (if (eq (aref s 9) ?x) ?t ?T)))
    s))

(defun lxs--time (st key)
  (time-convert (cons (or (gethash key st) 0) 1000000000) 'list))

(defun lxs--attributes (st &optional lstat)
  "The 12 element `file-attributes' list for stat table ST."
  (let* ((type (gethash "type" st))
         (link (and (gethash "is_link" st) (gethash "link" st)))
         (mtime (lxs--time st "mtime_ns")))
    (list (cond ((and lstat link) link) ((equal type "dir") t) (t nil))
          1 (or (gethash "uid" st) 0) (or (gethash "gid" st) 0)
          mtime mtime mtime
          (or (gethash "size" st) 0)
          (lxs--mode-string (if (and lstat link) "symlink" type) (or (gethash "mode" st) 0))
          t (or (gethash "ino" st) 0) 0)))

;;;; Handler

(defvar lxs--handlers (make-hash-table :test 'eq))

(defmacro lxs--define (op args &rest body)
  "Define the handler for file operation OP."
  (declare (indent 2))
  `(puthash ',op (lambda ,args ,@body) lxs--handlers))

(defun lxs--real (op args)
  "Run OP on ARGS with this handler disabled."
  ;; Every handler is inhibited: TRAMP's matches /lxs:host: names too and
  ;; would reject the unknown method.
  (let ((inhibit-file-name-handlers
         (append (mapcar #'cdr file-name-handler-alist)
                 (and (eq inhibit-file-name-operation op) inhibit-file-name-handlers)))
        (inhibit-file-name-operation op))
    (apply op args)))

(defun lxs-file-name-handler (operation &rest args)
  (let ((fn (gethash operation lxs--handlers)))
    (if fn (apply fn args) (lxs--real operation args))))

;;;###autoload
(defun lxs-fs-enable ()
  "Register the /lxs:HOST:/ file name handler."
  (unless (rassq #'lxs-file-name-handler file-name-handler-alist)
    (push (cons lxs-file-name-regexp #'lxs-file-name-handler) file-name-handler-alist)))

;;;; Name operations

(lxs--define expand-file-name (name &optional dir)
  (let* ((dir (or dir default-directory))
         (n (lxs--split name)))
    (cond (n (lxs--make (car n) (lxs--normalize (car n) (cdr n))))
          ((or (file-name-absolute-p name) (string-prefix-p "~" name))
           (lxs--real 'expand-file-name (list name nil)))
          (t (let ((d (lxs--parse dir)))
               (lxs--make (car d) (lxs--normalize
                                   (car d) (concat (file-name-as-directory (cdr d)) name))))))))

(lxs--define directory-file-name (dir)
  ;; the host root keeps its slash: "/lxs:h:" would be the home directory
  (let ((n (lxs--split dir)))
    (if (and n (string-match-p "\\`/+\\'" (cdr n)))
        (lxs--make (car n) "/")
      (lxs--real 'directory-file-name (list dir)))))

(lxs--define file-name-directory (file)
  (let ((n (lxs--split file)))
    (if (and n (not (string-match-p "/" (cdr n))))
        (lxs--make (car n) "")
      (lxs--real 'file-name-directory (list file)))))

(lxs--define substitute-in-file-name (file)
  ;; "//" and "/~" restart the name on the same host, as with TRAMP
  (let ((n (lxs--split file)))
    (if (not n)
        (lxs--real 'substitute-in-file-name (list file))
      (let ((local (lxs--real 'substitute-in-file-name (list (cdr n)))))
        (if (lxs--split local) local (lxs--make (car n) local))))))

(lxs--define file-remote-p (file &optional identification connected)
  (let ((p (lxs--split file)))
    (when (and p (or (not connected)
                     (let ((c (gethash (car p) lxs--connections))) (and c (lxs-alive-p c)))))
      (pcase identification
        ('method "lxs")
        ('host (car p))
        ('localname (cdr p))
        ('user nil)
        ('hop nil)
        (_ (concat "/lxs:" (car p) ":"))))))

(lxs--define unhandled-file-name-directory (_filename) (expand-file-name "~/"))
(lxs--define file-name-case-insensitive-p (_f) nil)
(lxs--define file-locked-p (_f) nil)
(lxs--define lock-file (_f) nil)
(lxs--define unlock-file (_f) nil)
(lxs--define vc-registered (_f) nil)

(lxs--define make-auto-save-file-name ()
  (expand-file-name (concat "lxs-auto-" (md5 (or buffer-file-name (buffer-name))) "#")
                    temporary-file-directory))

;;;; Queries

(defun lxs--st (file &optional nofollow fresh)
  (let ((p (lxs--path file))) (lxs--stat (car p) (cdr p) nofollow fresh)))

(lxs--define file-exists-p (f) (and (lxs--st f) t))
(defun lxs--type (f)
  (let ((st (lxs--st f))) (and st (gethash "type" st))))

(lxs--define file-directory-p (f) (equal "dir" (lxs--type f)))
(lxs--define file-regular-p (f) (equal "file" (lxs--type f)))
(lxs--define file-symlink-p (f)
  (let ((st (lxs--st f t))) (and st (gethash "is_link" st) (gethash "link" st))))

(defvar lxs--ids (make-hash-table :test 'equal)
  "HOST -> (UID . GIDS) of the user the server runs as.")

(defun lxs--user-ids (host)
  (or (gethash host lxs--ids)
      (puthash host
               (let* ((r (lxs-exec (lxs-connection host)
                                   (list "/bin/sh" "-c" "id -u; id -G")))
                      (lines (split-string (lxs--text (plist-get r :stdout)) "\n" t)))
                 (cons (string-to-number (or (car lines) "-1"))
                       (mapcar #'string-to-number (split-string (or (cadr lines) "")))))
               lxs--ids)))

(defun lxs--access-p (f bit)
  "Non-nil when the server's user may do BIT (4 read, 2 write, 1 execute) on F."
  (let ((st (lxs--st f)))
    (when st
      (let* ((host (car (lxs--parse f)))
             (ids (lxs--user-ids host))
             (mode (or (gethash "mode" st) 0))
             (uid (car ids)))
        (cond ((eql uid 0)
               ;; root: execute needs some x bit, except on directories
               (or (/= bit 1) (equal (gethash "type" st) "dir")
                   (/= 0 (logand mode #o111))))
              ((eql (gethash "uid" st) uid) (/= 0 (logand mode (ash bit 6))))
              ((memql (gethash "gid" st) (cdr ids)) (/= 0 (logand mode (ash bit 3))))
              (t (/= 0 (logand mode bit))))))))

(lxs--define file-readable-p (f) (and (lxs--access-p f 4) t))
(lxs--define file-executable-p (f) (and (lxs--access-p f 1) t))
(lxs--define file-accessible-directory-p (f)
  (and (equal "dir" (lxs--type f)) (lxs--access-p f 1) t))
(lxs--define file-writable-p (f)
  (if (lxs--st f)
      (and (lxs--access-p f 2) t)
    (let ((dir (file-name-directory (directory-file-name (expand-file-name f)))))
      (and dir (not (equal dir f)) (file-directory-p dir) (file-writable-p dir)))))

(lxs--define file-modes (f &optional _flag)
  (let ((st (lxs--st f))) (and st (logand (or (gethash "mode" st) 0) #o7777))))

(lxs--define file-attributes (f &optional _id-format)
  (let ((st (lxs--st f t))) (and st (lxs--attributes st t))))

(lxs--define file-newer-than-file-p (f1 f2)
  (let ((a (file-attributes f1)) (b (file-attributes f2)))
    (cond ((null a) nil)
          ((null b) t)
          (t (time-less-p (file-attribute-modification-time b)
                          (file-attribute-modification-time a))))))

(lxs--define file-truename (f)
  (let* ((p (lxs--path f)) (host (car p)))
    (if (not (lxs--stat host (cdr p)))
        (lxs--make host (cdr p))
      (let ((real (lxs--cached host 'realpath (cdr p) nil
                               (lambda ()
                                 (condition-case nil
                                     (lxs-call-sync (lxs-connection host) "realpath"
                                                    `(("path" . ,(cdr p))))
                                   (lxs-error (cdr p)))))))
        (lxs--make host (if (and (string-suffix-p "/" f) (not (string= real "/")))
                            (concat real "/") real))))))

;;;; Listing

(defun lxs--readdir (host path &optional fresh)
  "List of stat tables (with \"name\") for directory PATH."
  (lxs--cached host 'readdir path fresh
               (lambda ()
                 (lxs-readdir (lxs-connection host) path))))

(defun lxs--readdir-io (file)
  (let ((p (lxs--path file)))
    (lxs--io file "Reading directory"
      (lxs--readdir (car p) (cdr p)))))

(defun lxs--entry-names (entries)
  (let ((names (mapcar (lambda (e) (gethash "name" e)) entries)))
    names))

(lxs--define directory-files (dir &optional full match nosort count)
  (let* ((entries (lxs--readdir-io dir))
         (names (append '("." "..") (lxs--entry-names entries)))
         (names (if match (cl-remove-if-not (lambda (n) (string-match-p match n)) names) names))
         (names (if nosort names (sort names #'string<)))
         (names (if (and count (< count (length names))) (seq-take names count) names)))
    (if full
        (let ((d (file-name-as-directory (lxs--expand-name dir))))
          (mapcar (lambda (n) (concat d n)) names))
      names)))

(defun lxs--expand-name (f) (expand-file-name f))

(lxs--define directory-files-and-attributes (dir &optional full match nosort id-format count)
  (let* ((p (lxs--path dir))
         (entries (lxs--readdir-io dir))
         (self (lxs--stat (car p) (cdr p)))
         (up (lxs--stat (car p) (lxs--normalize (car p) (concat (cdr p) "/.."))))
         (all (append (and self (list (cons "." (lxs--attributes self))))
                      (and up (list (cons ".." (lxs--attributes up))))
                      (mapcar (lambda (e) (cons (gethash "name" e) (lxs--attributes e t)))
                              entries)))
         (all (if match (cl-remove-if-not (lambda (e) (string-match-p match (car e))) all) all))
         (all (if nosort all (sort all (lambda (a b) (string< (car a) (car b))))))
         (all (if (and count (< count (length all))) (seq-take all count) all)))
    (ignore id-format)
    (if full
        (let ((d (file-name-as-directory (lxs--expand-name dir))))
          (mapcar (lambda (e) (cons (concat d (car e)) (cdr e))) all))
      all)))

(defun lxs--completion-names (dir)
  (append '("./" "../")
          (mapcar (lambda (e)
                    (let ((n (gethash "name" e)))
                      (if (equal (gethash "type" e) "dir") (concat n "/") n)))
                  (lxs--readdir-io dir))))

(lxs--define file-name-all-completions (file dir)
  (let ((case-fold-search nil))
    (cl-remove-if-not (lambda (n) (string-prefix-p file n completion-ignore-case))
                      (lxs--completion-names dir))))

(lxs--define file-name-completion (file dir &optional predicate)
  (let* ((all (lxs--completion-names dir))
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

(defvar-local lxs--visited-etag nil
  "Etag of the remote file this buffer was read from or saved to.")

(defun lxs--temp-file (file)
  (make-temp-file "lxs-" nil (file-name-extension file t)))

(defun lxs--read-bytes (file)
  "Return (DATA . ETAG) of the lxs FILE."
  (let ((p (lxs--path file)))
    (lxs--io file "Opening input file"
      (let ((st (lxs--stat (car p) (cdr p) nil t)))
        (when (and st (equal "dir" (gethash "type" st)))
          (signal 'file-error (list "Read error" "Is a directory" file))))
      (lxs-read-file (lxs-connection (car p)) (cdr p)))))

(lxs--define insert-file-contents (filename &optional visit beg end replace)
  (barf-if-buffer-read-only)
  (let* ((res (condition-case err (lxs--read-bytes filename)
                (file-missing
                 ;; Like the C function: a visited missing file still names the buffer.
                 (when visit
                   (setq buffer-file-name (lxs--expand-name filename)
                         lxs--visited-etag nil)
                   (set-buffer-modified-p nil))
                 (signal (car err) (cdr err)))))
         (tmp (lxs--temp-file filename))
         ret)
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'no-conversion))
            (write-region (car res) nil tmp nil 'silent))
          (setq ret (lxs--real 'insert-file-contents (list tmp visit beg end replace))))
      (ignore-errors (delete-file tmp)))
    (when visit
      (setq buffer-file-name (lxs--expand-name filename)
            lxs--visited-etag (cdr res))
      (setq buffer-read-only (not (file-writable-p filename)))
      (set-buffer-modified-p nil))
    (list (lxs--expand-name filename) (cadr ret))))

(lxs--define file-local-copy (file)
  (let ((res (lxs--read-bytes file)) (tmp (lxs--temp-file file)))
    (let ((coding-system-for-write 'no-conversion))
      (write-region (car res) nil tmp nil 'silent))
    tmp))

(defun lxs--region-bytes (start end)
  "Bytes of the region (or string START), encoded as `write-region' would."
  (let ((tmp (make-temp-file "lxs-")) (coding-system-for-write coding-system-for-write))
    (unwind-protect
        (progn
          (write-region start end tmp nil 'silent)
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally tmp)
            (buffer-string)))
      (ignore-errors (delete-file tmp)))))

(lxs--define write-region (start end filename &optional append visit lockname mustbenew)
  (ignore lockname)
  (when (numberp append) (error "lxs: numeric APPEND is not supported"))
  (let* ((name (lxs--expand-name filename))
         (p (lxs--path filename))
         (whole (or (and (null start) (null end))
                    (and (integerp start) (= start (point-min)) (= end (point-max)))))
         (data (if (and (stringp start) (not (multibyte-string-p start)))
                   start
                 (lxs--region-bytes start end)))
         ;; Etag the buffer was read from: a save over a changed file conflicts.
         (expect (cond ((eq mustbenew 'excl) "-")
                       ((and whole (equal buffer-file-name name)) lxs--visited-etag))))
    (when (and mustbenew (not (eq mustbenew 'excl)) (lxs--stat (car p) (cdr p) nil t)
               (not (y-or-n-p (format "File %s exists; overwrite? " name))))
      (signal 'file-already-exists (list "File exists" name)))
    (when append
      ;; only a missing file counts as empty; the old contents pin the etag
      (let ((old (and (lxs--stat (car p) (cdr p) nil t)
                      (lxs--io filename "Opening output file"
                        (lxs-read-file (lxs-connection (car p)) (cdr p))))))
        (setq data (concat (or (car old) "") data) expect (if old (cdr old) "-"))))
    (let* ((st (lxs--io filename "Opening output file"
                 (condition-case err
                     (prog1 (lxs-write-file (lxs-connection (car p)) (cdr p) data expect)
                       (lxs--flush (car p)))
                   (lxs-error
                    (lxs--flush (car p))
                    (if (and (eq mustbenew 'excl) (equal (cadr err) "conflict"))
                        (signal 'file-already-exists (list "File exists" name))
                      (signal (car err) (cdr err)))))))
           ;; VISIT a string: the buffer visits that name (file-precious-flag
           ;; writes a temp file that is then renamed over it)
           (visited (cond ((eq visit t) name)
                          ((stringp visit) (expand-file-name visit)))))
      (when visited
        (setq buffer-file-name visited
              lxs--visited-etag (and (lxs--same-host visited name) (gethash "etag" st)))
        (set-buffer-modified-p nil))
      (when (and (or (null visit) (eq visit t) (stringp visit)) (not noninteractive))
        (message "Wrote %s" (or visited name)))
      nil)))

(lxs--define verify-visited-file-modtime (&optional buf)
  (with-current-buffer (or buf (current-buffer))
    (if (or (null lxs--visited-etag) (null buffer-file-name)
            (not (lxs--split buffer-file-name)))
        t
      (let ((st (lxs--st buffer-file-name nil t)))
        (and st (equal (gethash "etag" st) lxs--visited-etag))))))

(lxs--define set-visited-file-modtime (&optional _time)
  (when (and buffer-file-name (lxs--split buffer-file-name))
    (let ((st (lxs--st buffer-file-name nil t)))
      (setq lxs--visited-etag (and st (gethash "etag" st))))))

(lxs--define visited-file-modtime ()
  (if lxs--visited-etag 0 0))

;;;; Mutation

(defun lxs--call (host op args file what)
  (prog1 (lxs--io file what (lxs-call-sync (lxs-connection host) op args))
    (lxs--flush host)))

(defun lxs--run (host argv file what)
  "Run ARGV on HOST, signal a file error unless it succeeds."
  (let ((r (lxs-exec (lxs-connection host) argv)))
    (lxs--flush host)
    (unless (eq 0 (plist-get r :code))
      (signal 'file-error (list what (string-trim (decode-coding-string (plist-get r :stderr) 'utf-8))
                                file)))
    r))

(lxs--define make-directory (dir &optional parents)
  (let ((p (lxs--path dir)))
    (lxs--call (car p) "mkdir" `(("path" . ,(directory-file-name (cdr p))) ("parents" . ,(and parents t)))
               dir "Creating directory")
    nil))

(lxs--define delete-file (f &optional _trash)
  (let ((p (lxs--path f)))
    (condition-case err
        (lxs--call (car p) "remove" `(("path" . ,(cdr p))) f "Deleting file")
      (file-missing nil)
      (error (signal (car err) (cdr err))))
    nil))

(lxs--define delete-directory (dir &optional recursive _trash)
  (let ((p (lxs--path dir)))
    (if recursive
        (lxs--call (car p) "remove" `(("path" . ,(directory-file-name (cdr p))) ("recursive" . t))
                   dir "Removing directory")
      (lxs--run (car p) (list "rmdir" "--" (directory-file-name (cdr p))) dir "Removing directory"))
    nil))

(defun lxs--confirm-overwrite (newname ok)
  (when (file-exists-p newname)
    (cond ((eq ok t))
          ((numberp ok)
           (unless (yes-or-no-p (format "File %s already exists; overwrite? " newname))
             (signal 'file-already-exists (list "File already exists" newname))))
          (t (signal 'file-already-exists (list "File already exists" newname))))))

(defun lxs--same-host (a b)
  (let ((pa (lxs--split a)) (pb (lxs--split b)))
    (and pa pb (equal (car pa) (car pb)))))

(lxs--define rename-file (file newname &optional ok)
  (let ((newname (if (directory-name-p newname)
                     (expand-file-name (file-name-nondirectory file) newname)
                   newname)))
    (lxs--confirm-overwrite newname ok)
    (if (lxs--same-host file newname)
        (let ((a (lxs--path file)) (b (lxs--path newname)))
          (lxs--call (car a) "rename" `(("from" . ,(cdr a)) ("to" . ,(cdr b)) ("overwrite" . t))
                     file "Renaming"))
      (copy-file file newname t t)
      (if (file-directory-p file) (delete-directory file t) (delete-file file)))
    nil))

(defun lxs--read-local (file)
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(lxs--define copy-file (file newname &optional ok keep-time _uid _perm)
  (let ((newname (if (directory-name-p newname)
                     (expand-file-name (file-name-nondirectory file) newname)
                   newname)))
    (lxs--confirm-overwrite newname ok)
    (cond
     ((lxs--same-host file newname)
      (let ((a (lxs--path file)) (b (lxs--path newname)))
        (lxs--run (car a) `("cp" "-f" ,@(and keep-time '("-p")) "--" ,(cdr a) ,(cdr b))
                  file "Copying")))
     ((lxs--split newname)
      (let ((b (lxs--path newname))
            (data (if (lxs--split file) (car (lxs--read-bytes file)) (lxs--read-local file))))
        (lxs--io newname "Copying" (lxs-write-file (lxs-connection (car b)) (cdr b) data))
        (lxs--flush (car b))))
     (t
      (let ((res (lxs--read-bytes file)))
        (let ((coding-system-for-write 'no-conversion))
          (write-region (car res) nil newname nil 'silent)))))
    nil))

(lxs--define make-symbolic-link (target linkname &optional ok)
  (let ((p (lxs--path linkname)))
    (when (and (not (eq ok t)) (lxs--stat (car p) (cdr p) t t))
      (signal 'file-already-exists (list "File exists" linkname)))
    (lxs--run (car p) (list "ln" "-sfn" "--" (or (file-remote-p target 'localname) target) (cdr p))
              linkname "Making symbolic link")
    nil))

(lxs--define add-name-to-file (file newname &optional ok)
  (let ((a (lxs--path file)) (b (lxs--path newname)))
    (lxs--confirm-overwrite newname ok)
    (lxs--run (car a) (list "ln" "-f" "--" (cdr a) (cdr b)) file "Adding name")
    nil))

(lxs--define set-file-modes (f mode &optional _flag)
  (let ((p (lxs--path f)))
    (lxs--run (car p) (list "chmod" (format "%o" mode) "--" (cdr p)) f "Doing chmod")
    nil))

(lxs--define set-file-times (f &optional time _flag)
  (let ((p (lxs--path f)))
    (lxs--run (car p) `("touch" ,@(and time (list "-d" (format-time-string "@%s" time))) "--" ,(cdr p))
              f "Setting file times")
    t))

;;;; Directory listings for dired

(defconst lxs--glob-chars "[*?[]")

(lxs--define insert-directory (file switches &optional wildcard full-directory-p)
  (let* ((p (lxs--path file))
         (switches (cond ((stringp switches) (split-string switches))
                         ((listp switches) switches)))
         (switches (cl-remove-if (lambda (s) (string-prefix-p "--dired" s)) switches))
         (name (cdr p))
         (cmd
          (cond
           ((and wildcard (string-match-p lxs--glob-chars (file-name-nondirectory name)))
            ;; let the remote shell expand the pattern, as Tramp does
            (list "/bin/sh" "-c"
                  (concat "ls " (mapconcat #'shell-quote-argument switches " ") " -- "
                          (shell-quote-argument (or (file-name-directory name) "/"))
                          (file-name-nondirectory name))))
           (full-directory-p
            `("ls" ,@switches "--" ,(file-name-as-directory name)))
           (t `("ls" ,@switches "--" ,name))))
         (r (lxs-exec (lxs-connection (car p)) cmd :env '(("LC_ALL" . "C")))))
    (insert (decode-coding-string (plist-get r :stdout) 'utf-8))
    (unless (zerop (or (plist-get r :code) 0))
      (let ((err (string-trim (decode-coding-string (plist-get r :stderr) 'utf-8))))
        (when (string-match-p "No such file" err)
          (signal 'file-missing (list "Reading directory" "No such file or directory" file)))
        (message "%s" err)))
    nil))

(provide 'lxs-fs)
;;; lxs-fs.el ends here
