;; -*- coding: utf-8; lexical-binding: t; -*-

(defconst emacs-flymake-eslint--home
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory which `emacs-flymake-eslint' installed.")
(defconst emacs-flymake-eslint--js-file
  (expand-file-name "../js/index.mjs" emacs-flymake-eslint--home)
  "Node program entry of `emacs-flymake-eslint'.")
(defconst emacs-flymake-eslint--stdout-name " *emacs-flymake-eslint output*"
  "Standard output buffer name of `emacs-flymake-eslint'.")
(defconst emacs-flymake-eslint--stderr-name " *emacs-flymake-eslint stderr*"
  "Standard error buffer name of `emacs-flymake-eslint'.")

(defvar emacs-flymake-eslint--process nil
  "Linter process.
All buffers use the same process.")

(defvar emacs-flymake-eslint--report-fn-map (make-hash-table :test #'equal)
  "File path and flymake report function map.")

(defun emacs-flymake-eslint--buffer (buffer-name)
  (or (get-buffer buffer-name) (generate-new-buffer buffer-name)))
(defun emacs-flymake-eslint--stdout-buffer ()
  (emacs-flymake-eslint--buffer emacs-flymake-eslint--stdout-name))
(defun emacs-flymake-eslint--stderr-buffer ()
  (emacs-flymake-eslint--buffer emacs-flymake-eslint--stderr-name))

(defun emacs-flymake-eslint--log-process-exit (buffer)
  (with-current-buffer buffer
    (goto-char (point-max))
    (insert "====================== process exit ======================\n")))

(defun emacs-flymake-eslint--kill-process ()
  (when (process-live-p emacs-flymake-eslint--process)
    (kill-process emacs-flymake-eslint--process))

  (let ((proc-buffer
         (when (processp emacs-flymake-eslint--process)
           (process-buffer emacs-flymake-eslint--process))))
    (when proc-buffer (kill-buffer proc-buffer)))

  (setq emacs-flymake-eslint--process nil))

(defun emacs-flymake-eslint--detect-node-cmd ()
  (locate-file "node" exec-path))

(defun emacs-flymake-eslint--parse-message (msg buffer)
  (let* ((ruleId (alist-get 'ruleId msg))
         (severity (alist-get 'severity msg))
         (message (alist-get 'message msg))
         (line (alist-get 'line msg))
         (column (alist-get 'column msg))
         (endLine (alist-get 'endLine msg))
         (endColumn (alist-get 'endColumn msg))
         (start-region (flymake-diag-region buffer line column))
         (end-region (when (numberp endLine)
                       (flymake-diag-region buffer endLine endColumn)))
         begin end msg-text type type-symbol)
    (if end-region
        (setq begin (car start-region)
              end (car end-region))
      (setq begin (car start-region)
            end (cdr start-region)))
    (if (equal severity 1)
        (setq type "warning"
              type-symbol :warning)
      (setq type "error"
            type-symbol :error))
    (setq msg-text (format "%s: %s [%s]" type message ruleId))
    (flymake-make-diagnostic buffer begin end type-symbol msg-text
                             (list :rule-name ruleId))))

(defun emacs-flymake-eslint--filter (stdout-output stdout-buffer stderr-buffer)
  (condition-case err
      (let* ((obj (json-parse-string stdout-output
                                     :object-type 'alist
                                     :null-object nil))
             (filepath  (alist-get 'file obj))
             (buffer (find-buffer-visiting filepath))
             cost messages report-fn diags)
        (when (and filepath buffer
                   (hash-table-p emacs-flymake-eslint--report-fn-map))
          (setq cost        (alist-get 'cost obj)
                messages    (alist-get 'messages obj)
                report-fn   (gethash filepath emacs-flymake-eslint--report-fn-map))
          (with-current-buffer stdout-buffer
            (goto-char (point-max))
            (when (> (point) 1)
              (insert "-----------------------------------------\n"))
            (insert (format "file: %s\ncost: %sms\n" filepath cost)))
          (setq diags (mapcar (lambda (msg)
                                (emacs-flymake-eslint--parse-message msg buffer))
                              messages))
          (when (functionp report-fn) (funcall report-fn diags))
          (remhash filepath emacs-flymake-eslint--report-fn-map)))
    (t (with-current-buffer stderr-buffer
         (goto-char (point-max))
         (insert (format "\nerror: %s\ntype: %s, origin: |%s|"
                         err (type-of stdout-output) stdout-output)))
       (message "emacs-flymake-eslint error: %s" err))))

(defun emacs-flymake-eslint--create-process ()
  (let ((node (emacs-flymake-eslint--detect-node-cmd))
        buffer stderr)
    (when (and node (file-exists-p emacs-flymake-eslint--js-file))
      (setq buffer (emacs-flymake-eslint--stdout-buffer)
            stderr (emacs-flymake-eslint--stderr-buffer))
      (setq emacs-flymake-eslint--process
            (make-process
             :name "emacs-flymake-eslint"
             :connection-type 'pipe
             :noquery t
             :buffer buffer
             :stderr stderr
             :command (list "node" emacs-flymake-eslint--js-file)
             :filter (lambda (process output)
                       (mapcar (lambda (json-string)
                                 (emacs-flymake-eslint--filter
                                  json-string buffer stderr))
                               (string-split output "[\n\r]+" t "[ \t\f\v]+")))
             :sentinel (lambda (process event)
                         (when (eq 'exit (process-status process))
                           (when (bufferp buffer) (kill-buffer buffer))
                           (when (bufferp stderr)
                             (emacs-flymake-eslint--log-process-exit stderr)))
                         (when (hash-table-p emacs-flymake-eslint--report-fn-map)
                           (clrhash emacs-flymake-eslint--report-fn-map))
                         )
             )))))

(defun emacs-flymake-eslint--init-process ()
  (emacs-flymake-eslint--kill-process)
  (setq emacs-flymake-eslint--process (emacs-flymake-eslint--create-process)))

(defun emacs-flymake-eslint--get-process ()
  (unless (process-live-p emacs-flymake-eslint--process)
    (emacs-flymake-eslint--init-process))
  emacs-flymake-eslint--process)

(defun emacs-flymake-eslint--send-json (process &rest json-items)
  (process-send-string
   process
   (format "%s\n" (json-serialize json-items))))

(defun emacs-flymake-eslint-lint-file (filepath &optional buffer)
  "Lint file by a node process which run eslint instance."
  (let ((process (emacs-flymake-eslint--get-process))
        (code (when (bufferp buffer)
                (with-current-buffer buffer (buffer-string)))))
    (when (and (stringp code)
               (process-live-p process))
      (emacs-flymake-eslint--send-json
       process
       :cmd "lint" :file filepath :code code))))

(defun emacs-flymake-eslint-kill-buffer-hook ()
  "Hook function run after buffer killed."
  (let ((filepath (buffer-file-name))
        (process (when (process-live-p emacs-flymake-eslint--process)
                   emacs-flymake-eslint--process)))
    (when (and process filepath
               (bound-and-true-p flymake-mode)
               (member 'emacs-flymake-eslint--checker
                       flymake-diagnostic-functions))
      (emacs-flymake-eslint--send-json
       process
       :cmd "close" :file filepath))))

(defun emacs-flymake-eslint-after-file-save ()
  "Hook function run after file saved."
  (let ((filepath buffer-file-name)
        (process (when (process-live-p emacs-flymake-eslint--process)
                   emacs-flymake-eslint--process)))
    (when (and filepath process (file-regular-p filepath))
      (emacs-flymake-eslint--send-json
       process
       :cmd "save" :file filepath))))

(defun emacs-flymake-eslint--checker (report-fn &rest _ignore)
  (let ((filepath (buffer-file-name)))
    (when filepath
      (emacs-flymake-eslint-lint-file filepath (current-buffer))
      (puthash filepath report-fn emacs-flymake-eslint--report-fn-map))))

(defun emacs-flymake-eslint-enable ()
  "Enable `emacs-flymake-eslint' in current buffer."
  (interactive)
  (when (emacs-flymake-eslint--detect-node-cmd)
    (unless (bound-and-true-p flymake-mode) (flymake-mode 1))
    (add-hook 'flymake-diagnostic-functions #'emacs-flymake-eslint--checker nil t)
    (add-hook 'kill-buffer-hook #'emacs-flymake-eslint-kill-buffer-hook nil t)
    (add-hook 'kill-buffer-hook #'emacs-flymake-eslint-kill-buffer-hook)
    (add-hook 'after-save-hook #'emacs-flymake-eslint-after-file-save)
    (add-hook 'after-revert-hook #'emacs-flymake-eslint-after-file-save)))

(defun emacs-flymake-eslint-disable ()
  "Disable `emacs-flymake-eslint' in current buffer."
  (interactive)
  (when (and (bound-and-true-p flymake-mode)
             flymake-mode
             (emacs-flymake-eslint--detect-node-cmd))
    (remove-hook 'flymake-diagnostic-functions #'emacs-flymake-eslint--checker)
    (remove-hook 'flymake-diagnostic-functions #'emacs-flymake-eslint--checker t)))

(defun emacs-flymake-eslint-stop ()
  "Kill node process of `emacs-flymake-eslint' and disable in current buffer."
  (interactive)
  (when (process-live-p emacs-flymake-eslint--process)
    (emacs-flymake-eslint--send-json
     emacs-flymake-eslint--process
     :cmd "exit"))
  (let ((buffer (get-buffer emacs-flymake-eslint--stderr-name)))
    (when (bufferp buffer) (kill-buffer buffer)))
  (remove-hook 'flymake-diagnostic-functions #'emacs-flymake-eslint--checker)
  (remove-hook 'flymake-diagnostic-functions #'emacs-flymake-eslint--checker t)
  (remove-hook 'kill-buffer-hook #'emacs-flymake-eslint-kill-buffer-hook)
  (remove-hook 'kill-buffer-hook #'emacs-flymake-eslint-kill-buffer-hook t)
  (remove-hook 'after-save-hook #'emacs-flymake-eslint-after-file-save)
  (remove-hook 'after-revert-hook #'emacs-flymake-eslint-after-file-save))

(defun emacs-flymake-eslint-log ()
  "Log current info of node process."
  (interactive)
  (when (process-live-p emacs-flymake-eslint--process)
    (emacs-flymake-eslint--send-json
     emacs-flymake-eslint--process
     :cmd "log")))


(provide 'emacs-flymake-eslint)
