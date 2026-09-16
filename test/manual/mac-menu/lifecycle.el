;;; lifecycle.el --- manual macOS native-menu lifecycle fixture -*- lexical-binding: t; -*-

;; This is an opt-in, interactive fixture.  It deliberately does not enable
;; EMACS_MAC_NATIVE_MENUS itself; set that in the environment when launching.

(require 'cl-lib)
(require 'easymenu)

(defgroup mac-menu-lifecycle nil
  "Manual fixture for the macOS native menu lifecycle."
  :group 'environment)

(defvar mac-menu-lifecycle--buffers nil)
(defvar mac-menu-lifecycle--frames nil)
(defvar mac-menu-lifecycle--log-buffer nil)
(defvar mac-menu-lifecycle--worker nil)
(defvar mac-menu-lifecycle--worker-stop nil)
(defvar mac-menu-lifecycle--serial 0)
(defvar-local mac-menu-lifecycle--menu nil)
(defvar-local mac-menu-lifecycle--menu-version 1)
(defvar-local mac-menu-lifecycle--fixture-map nil)
(defvar-local mac-menu-lifecycle--variant nil)

(defun mac-menu-lifecycle--log (format-string &rest args)
  "Append a timestamped event to the fixture's visible log buffer."
  (when (buffer-live-p mac-menu-lifecycle--log-buffer)
    (with-current-buffer mac-menu-lifecycle--log-buffer
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (format-time-string "%H:%M:%S.%3N "))
        (insert (apply #'format format-string args) "\n")
        (goto-char (point-max))))))

(defun mac-menu-lifecycle--action (which)
  "Record actual delivery of menu action WHICH in the selected buffer."
  (interactive)
  (mac-menu-lifecycle--log "ACTION %s buffer=%s frame=%s version=%s"
                           which (buffer-name) (frame-parameter nil 'name)
                           mac-menu-lifecycle--menu-version)
  (message "mac-menu-lifecycle: delivered %s" which))

(defun mac-menu-lifecycle-action-a ()
  (interactive)
  (mac-menu-lifecycle--action "A"))

(defun mac-menu-lifecycle-action-b ()
  (interactive)
  (mac-menu-lifecycle--action "B"))

(defun mac-menu-lifecycle-action-changed ()
  (interactive)
  (mac-menu-lifecycle--action "CHANGED"))

(defun mac-menu-lifecycle--menu-items ()
  (list (format "Lifecycle %s (v%s)"
                mac-menu-lifecycle--variant mac-menu-lifecycle--menu-version)
        (if (= mac-menu-lifecycle--menu-version 1)
            (if (equal mac-menu-lifecycle--variant "A")
                ["Deliver A" mac-menu-lifecycle-action-a t]
              ["Deliver B" mac-menu-lifecycle-action-b t])
          ["Deliver changed command" mac-menu-lifecycle-action-changed t])
        ["Change menu for next opening" mac-menu-lifecycle-change-menu t]
        ["Open the other fixture buffer" mac-menu-lifecycle-switch-buffer t]
        ["Show this log" mac-menu-lifecycle-show-log t]
        ["Create a dedicated frame" mac-menu-lifecycle-open-frame t]
        "-"
        ["Start optional worker" mac-menu-lifecycle-start-worker
         (not (mac-menu-lifecycle-worker-running-p))]
        ["Stop optional worker" mac-menu-lifecycle-stop-worker
         (mac-menu-lifecycle-worker-running-p)]
        ["Clear fixture" mac-menu-lifecycle-clear t]))

(defun mac-menu-lifecycle--install-menu ()
  (when (keymapp mac-menu-lifecycle--menu)
    (define-key mac-menu-lifecycle--fixture-map
      [menu-bar mac-menu-lifecycle] nil))
  (let ((items (mac-menu-lifecycle--menu-items)))
    (setq mac-menu-lifecycle--menu (easy-menu-create-menu
                                    (car items) (cdr items)))
    (define-key mac-menu-lifecycle--fixture-map
      [menu-bar mac-menu-lifecycle]
      (easy-menu-binding mac-menu-lifecycle--menu (car items)))))

(defun mac-menu-lifecycle-change-menu ()
  "Change this buffer's menu, for comparison on its next opening."
  (interactive)
  (setq mac-menu-lifecycle--menu-version (1+ mac-menu-lifecycle--menu-version))
  (mac-menu-lifecycle--install-menu)
  (mac-menu-lifecycle--log "MENU-CHANGED buffer=%s version=%s"
                           (buffer-name) mac-menu-lifecycle--menu-version)
  (message "Menu changed to version %s; open it again" mac-menu-lifecycle--menu-version))

(defun mac-menu-lifecycle-show-log ()
  (interactive)
  (when (buffer-live-p mac-menu-lifecycle--log-buffer)
    (display-buffer mac-menu-lifecycle--log-buffer)))

(defun mac-menu-lifecycle-switch-buffer ()
  "Select the other generated buffer, preserving the current frame."
  (interactive)
  (let* ((buffers (cl-remove-if-not #'buffer-live-p mac-menu-lifecycle--buffers))
         (choice (completing-read "Fixture buffer: " (mapcar #'buffer-name buffers)
                                  nil t nil nil (buffer-name (car buffers)))))
    (pop-to-buffer choice)
    (mac-menu-lifecycle--log "SWITCH buffer=%s frame=%s"
                             (buffer-name) (frame-parameter nil 'name))))

(defun mac-menu-lifecycle-worker-running-p ()
  (and (threadp mac-menu-lifecycle--worker)
       (thread-live-p mac-menu-lifecycle--worker)))

(defun mac-menu-lifecycle-start-worker ()
  "Start the optional worker; it is never started by fixture setup."
  (interactive)
  (if (not (fboundp 'make-thread))
      (message "Threads are unavailable in this build")
    (unless (mac-menu-lifecycle-worker-running-p)
      (setq mac-menu-lifecycle--worker-stop nil)
      (setq mac-menu-lifecycle--worker
            (make-thread
             (lambda ()
               (while (not mac-menu-lifecycle--worker-stop)
                 (sleep-for 0.2)))
             "mac-menu-lifecycle-worker"))
      (mac-menu-lifecycle--log "WORKER-STARTED"))))

(defun mac-menu-lifecycle-stop-worker ()
  (interactive)
  (when (mac-menu-lifecycle-worker-running-p)
    (setq mac-menu-lifecycle--worker-stop t)
    (thread-join mac-menu-lifecycle--worker)
    (setq mac-menu-lifecycle--worker nil)
    (mac-menu-lifecycle--log "WORKER-STOPPED")))

(defun mac-menu-lifecycle-open-frame ()
  "Create a frame owned by this fixture for frame-switch testing."
  (interactive)
  (let* ((buffers (cl-remove-if-not #'buffer-live-p
                                    mac-menu-lifecycle--buffers))
         (buffer (nth (mod (length mac-menu-lifecycle--frames)
                           (max 1 (length buffers)))
                      buffers))
         (frame (make-frame
                 `((name . ,(format "mac-menu-lifecycle-frame-%s-%s"
                                    (emacs-pid)
                                    (cl-incf mac-menu-lifecycle--serial)))))))
    (push frame mac-menu-lifecycle--frames)
    (select-frame-set-input-focus frame)
    (when buffer
      (switch-to-buffer buffer))
    (mac-menu-lifecycle--log "FRAME-CREATED frame=%s buffer=%s"
                             (frame-parameter frame 'name)
                             (and buffer (buffer-name buffer)))))

(defun mac-menu-lifecycle-clear ()
  "Stop the worker and remove only objects created by this fixture."
  (interactive)
  (mac-menu-lifecycle-stop-worker)
  (dolist (buffer mac-menu-lifecycle--buffers)
    (when (buffer-live-p buffer) (kill-buffer buffer)))
  (dolist (frame mac-menu-lifecycle--frames)
    (when (frame-live-p frame) (delete-frame frame)))
  (when (buffer-live-p mac-menu-lifecycle--log-buffer)
    (kill-buffer mac-menu-lifecycle--log-buffer))
  (setq mac-menu-lifecycle--buffers nil
        mac-menu-lifecycle--frames nil
        mac-menu-lifecycle--log-buffer nil)
  (message "mac-menu-lifecycle: cleared"))

(defun mac-menu-lifecycle--make-buffer (suffix)
  (let ((buffer (generate-new-buffer
                 (format "*mac-menu-lifecycle-%s-%s-%s*" suffix (emacs-pid)
                         (cl-incf mac-menu-lifecycle--serial)))))
    (with-current-buffer buffer
      (special-mode)
      (let ((inhibit-read-only t))
        (insert (format "Fixture buffer %s.  Use the Lifecycle menu and verify ACTION lines in the log.\n"
                        suffix)))
      (setq-local mac-menu-lifecycle--variant suffix)
      (setq-local mac-menu-lifecycle--menu-version 1)
      (setq-local mac-menu-lifecycle--fixture-map (make-sparse-keymap))
      (use-local-map mac-menu-lifecycle--fixture-map)
      (local-set-key (kbd "C-c m c") #'mac-menu-lifecycle-change-menu)
      (local-set-key (kbd "C-c m f") #'mac-menu-lifecycle-open-frame)
      (local-set-key (kbd "C-c m l") #'mac-menu-lifecycle-show-log)
      (local-set-key (kbd "C-c m q") #'mac-menu-lifecycle-clear)
      (mac-menu-lifecycle--install-menu))
    (push buffer mac-menu-lifecycle--buffers)
    buffer))

(defun mac-menu-lifecycle-start ()
  "Create the two uniquely named buffers and the visible event log."
  (interactive)
  (mac-menu-lifecycle-clear)
  (setq mac-menu-lifecycle--log-buffer (generate-new-buffer
                                        (format "*mac-menu-lifecycle-log-%s*" (emacs-pid))))
  (with-current-buffer mac-menu-lifecycle--log-buffer
    (special-mode)
    (let ((inhibit-read-only t))
      (insert "mac-menu-lifecycle log; ACTION means command delivery, not appearance.\n")))
  (let ((a (mac-menu-lifecycle--make-buffer "A"))
        (b (mac-menu-lifecycle--make-buffer "B")))
    (display-buffer mac-menu-lifecycle--log-buffer)
    (pop-to-buffer a)
    (mac-menu-lifecycle--log "READY buffers=%s,%s frame=%s"
                             (buffer-name a) (buffer-name b)
                             (frame-parameter nil 'name))
    (message "mac-menu-lifecycle ready; use C-c m f for another frame, C-c m q to clear")))

(provide 'mac-menu-lifecycle-lifecycle)
;;; lifecycle.el ends here
