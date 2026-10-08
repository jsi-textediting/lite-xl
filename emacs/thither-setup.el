;;; thither-setup.el --- Opt-in setup for /thither:HOST:/path files  -*- lexical-binding: t; -*-

;; Version: 0.1
;; Package-Requires: ((emacs "28.1"))
;; Keywords: files, comm, processes

;;; Commentary:

;; (require 'thither-setup) registers the file name handler, builds the server
;; command line per host (plink on Windows, ssh elsewhere) and adapts the
;; packages that misbehave on remote files:
;;
;;   - `consult-ripgrep' falls back to `consult-grep' and `consult-fd' to
;;     `consult-find' when the host lacks rg / fd;
;;   - lsp-mode and flycheck are not started in thither buffers (they would need a
;;     server connection of their own).
;;
;; Open files with C-x C-f /thither:HOST:/path or M-x `thither-find-file'.

;;; Code:

(require 'thither-fs)
(require 'thither-proc)

(declare-function consult-grep "consult")
(declare-function consult-find "consult")

(defgroup thither-setup nil "Setup for thither-server remote files." :group 'thither)

(defcustom thither-server-program "thither-server"
  "Server program on the remote host (a path, or a name found in PATH)."
  :type 'string)

(defcustom thither-host-options nil
  "Per host overrides, an alist of (HOST . PLIST).
PLIST keys: :server (program on that host), :server-args (extra arguments
such as (\"--root\" \"/home/me\")), :command (a function of HOST returning
the complete command list, replacing everything else)."
  :type '(alist :key-type string :value-type plist))

(defcustom thither-hosts nil
  "Host names offered by `thither-find-file'."
  :type '(repeat string))

(defcustom thither-disable-remote-tools t
  "Non-nil: do not start lsp-mode and flycheck in thither buffers."
  :type 'boolean)

(defun thither--host-option (host key)
  (plist-get (cdr (assoc host thither-host-options)) key))

(defun thither--posix-quote (arg)
  "ARG quoted for the POSIX shell that runs the remote command.
Plain words (a leading ~ included, so it still expands) are left alone.  Not
`shell-quote-argument': on Windows that quotes for cmd.exe."
  (if (and (not (string-empty-p arg)) (string-match-p "\\`~?[-A-Za-z0-9_./=:,+@%]*\\'" arg))
      arg
    (concat "'" (replace-regexp-in-string "'" "'\\''" arg t t) "'")))

(defun thither-launch-command (host)
  "Command list that runs the server on HOST over plink or ssh."
  (let ((custom (thither--host-option host :command)))
    (if custom
        (funcall custom host)
      (append (if (eq system-type 'windows-nt)
                  (list (or (executable-find "plink") "plink") "-ssh" "-batch" "-T" host)
                (list "ssh" "-T" host))
              ;; ssh and plink join these with spaces for the remote shell
              (mapcar #'thither--posix-quote
                      (append (list (or (thither--host-option host :server) thither-server-program))
                              (thither--host-option host :server-args)
                              (list "--stdio")))))))

;;;###autoload
(progn
  ;; Registered when the autoloads are loaded (package.el), or by the :init
  ;; forms shown in the README (use-package with :load-path), so that a
  ;; /thither:HOST:/ name loads this file on first use.
  (autoload 'thither-file-name-handler "thither-setup")
  (add-to-list 'file-name-handler-alist
               (cons "\\`/thither:[^:/]+:" #'thither-file-name-handler)))

;;;###autoload
(defun thither-find-file (host)
  "Visit a file on HOST (a PuTTY session or ssh host) with thither-server."
  (interactive
   (list (completing-read "thither host: "
                          (delete-dups (append thither-hosts (hash-table-keys thither--connections))))))
  (find-file (read-file-name "Find file: " (format "/thither:%s:~/" host))))

;;;###autoload
(defun thither-disconnect-all ()
  "Close every server connection (they are reopened on demand)."
  (interactive)
  (dolist (h (hash-table-keys thither--connections)) (thither-disconnect h)))

;;;; Tools that cannot work on remote files

(defun thither--remote-buffer-p ()
  (and buffer-file-name (thither--split buffer-file-name)))

(defun thither--skip-when-remote (orig &rest args)
  (unless (and thither-disable-remote-tools (thither--remote-buffer-p))
    (apply orig args)))

(defun thither--lsp-advice ()
  (dolist (f '(lsp lsp-deferred))
    (when (fboundp f) (advice-add f :around #'thither--skip-when-remote))))

(with-eval-after-load 'lsp-mode (thither--lsp-advice))
(with-eval-after-load 'flycheck
  (advice-add 'flycheck-may-enable-mode :around
              (lambda (orig &rest args)
                (and (not (and thither-disable-remote-tools (thither--remote-buffer-p)))
                     (apply orig args)))))

;;;; Searching: fall back when the host lacks rg / fd

(defun thither--remote-dir-p ()
  (and (thither--split default-directory) t))

(defun thither--fallback-advice (tool fallback)
  "Advice for a consult command: use FALLBACK on thither hosts without TOOL."
  (lambda (orig &rest args)
    (if (and (thither--remote-dir-p) (not (executable-find tool t)))
        (progn (message "thither: %s not found on the host, using %s" tool fallback)
               (apply fallback args))
      (apply orig args))))

(with-eval-after-load 'consult
  (advice-add 'consult-ripgrep :around (thither--fallback-advice "rg" #'consult-grep))
  (advice-add 'consult-fd :around (thither--fallback-advice "fd" #'consult-find)))

;;;; Enable

;; keep a value the user set before loading this file
(when (eq thither-command-function #'thither-default-command)
  (setq thither-command-function #'thither-launch-command))
(thither-fs-enable)

(provide 'thither-setup)
;;; thither-setup.el ends here
