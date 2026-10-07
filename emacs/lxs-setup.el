;;; lxs-setup.el --- Opt-in setup for /lxs:HOST:/path files  -*- lexical-binding: t; -*-

;; Version: 0.1
;; Package-Requires: ((emacs "28.1"))
;; Keywords: files, comm, processes

;;; Commentary:

;; (require 'lxs-setup) registers the file name handler, builds the server
;; command line per host (plink on Windows, ssh elsewhere) and adapts the
;; packages that misbehave on remote files:
;;
;;   - `consult-ripgrep' falls back to `consult-grep' and `consult-fd' to
;;     `consult-find' when the host lacks rg / fd;
;;   - lsp-mode and flycheck are not started in lxs buffers (they would need a
;;     server connection of their own).
;;
;; Open files with C-x C-f /lxs:HOST:/path or M-x `lxs-find-file'.

;;; Code:

(require 'lxs-fs)
(require 'lxs-proc)

(declare-function consult-grep "consult")
(declare-function consult-find "consult")

(defgroup lxs-setup nil "Setup for lite-xl-server remote files." :group 'lxs)

(defcustom lxs-server-program "lite-xl-server"
  "Server program on the remote host (a path, or a name found in PATH)."
  :type 'string)

(defcustom lxs-host-options nil
  "Per host overrides, an alist of (HOST . PLIST).
PLIST keys: :server (program on that host), :server-args (extra arguments
such as (\"--root\" \"/home/me\")), :command (a function of HOST returning
the complete command list, replacing everything else)."
  :type '(alist :key-type string :value-type plist))

(defcustom lxs-hosts nil
  "Host names offered by `lxs-find-file'."
  :type '(repeat string))

(defcustom lxs-disable-remote-tools t
  "Non-nil: do not start lsp-mode and flycheck in lxs buffers."
  :type 'boolean)

(defun lxs--host-option (host key)
  (plist-get (cdr (assoc host lxs-host-options)) key))

(defun lxs--posix-quote (arg)
  "ARG quoted for the POSIX shell that runs the remote command.
Plain words (a leading ~ included, so it still expands) are left alone.  Not
`shell-quote-argument': on Windows that quotes for cmd.exe."
  (if (and (not (string-empty-p arg)) (string-match-p "\\`~?[-A-Za-z0-9_./=:,+@%]*\\'" arg))
      arg
    (concat "'" (replace-regexp-in-string "'" "'\\''" arg t t) "'")))

(defun lxs-launch-command (host)
  "Command list that runs the server on HOST over plink or ssh."
  (let ((custom (lxs--host-option host :command)))
    (if custom
        (funcall custom host)
      (append (if (eq system-type 'windows-nt)
                  (list (or (executable-find "plink") "plink") "-ssh" "-batch" "-T" host)
                (list "ssh" "-T" host))
              ;; ssh and plink join these with spaces for the remote shell
              (mapcar #'lxs--posix-quote
                      (append (list (or (lxs--host-option host :server) lxs-server-program))
                              (lxs--host-option host :server-args)
                              (list "--stdio")))))))

;;;###autoload
(progn
  ;; Registered when the autoloads are loaded (package.el), or by the :init
  ;; forms shown in the README (use-package with :load-path), so that a
  ;; /lxs:HOST:/ name loads this file on first use.
  (autoload 'lxs-file-name-handler "lxs-setup")
  (add-to-list 'file-name-handler-alist
               (cons "\\`/lxs:[^:/]+:" #'lxs-file-name-handler)))

;;;###autoload
(defun lxs-find-file (host)
  "Visit a file on HOST (a PuTTY session or ssh host) with lite-xl-server."
  (interactive
   (list (completing-read "lxs host: "
                          (delete-dups (append lxs-hosts (hash-table-keys lxs--connections))))))
  (find-file (read-file-name "Find file: " (format "/lxs:%s:~/" host))))

;;;###autoload
(defun lxs-disconnect-all ()
  "Close every server connection (they are reopened on demand)."
  (interactive)
  (dolist (h (hash-table-keys lxs--connections)) (lxs-disconnect h)))

;;;; Tools that cannot work on remote files

(defun lxs--remote-buffer-p ()
  (and buffer-file-name (lxs--split buffer-file-name)))

(defun lxs--skip-when-remote (orig &rest args)
  (unless (and lxs-disable-remote-tools (lxs--remote-buffer-p))
    (apply orig args)))

(defun lxs--lsp-advice ()
  (dolist (f '(lsp lsp-deferred))
    (when (fboundp f) (advice-add f :around #'lxs--skip-when-remote))))

(with-eval-after-load 'lsp-mode (lxs--lsp-advice))
(with-eval-after-load 'flycheck
  (advice-add 'flycheck-may-enable-mode :around
              (lambda (orig &rest args)
                (and (not (and lxs-disable-remote-tools (lxs--remote-buffer-p)))
                     (apply orig args)))))

;;;; Searching: fall back when the host lacks rg / fd

(defun lxs--remote-dir-p ()
  (and (lxs--split default-directory) t))

(defun lxs--fallback-advice (tool fallback)
  "Advice for a consult command: use FALLBACK on lxs hosts without TOOL."
  (lambda (orig &rest args)
    (if (and (lxs--remote-dir-p) (not (executable-find tool t)))
        (progn (message "lxs: %s not found on the host, using %s" tool fallback)
               (apply fallback args))
      (apply orig args))))

(with-eval-after-load 'consult
  (advice-add 'consult-ripgrep :around (lxs--fallback-advice "rg" #'consult-grep))
  (advice-add 'consult-fd :around (lxs--fallback-advice "fd" #'consult-find)))

;;;; Enable

;; keep a value the user set before loading this file
(when (eq lxs-command-function #'lxs-default-command)
  (setq lxs-command-function #'lxs-launch-command))
(lxs-fs-enable)

(provide 'lxs-setup)
;;; lxs-setup.el ends here
