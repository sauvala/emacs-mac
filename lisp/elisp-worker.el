;;; elisp-worker.el --- Async Emacs Lisp worker processes  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This library provides a small process-backed worker for isolated Emacs
;; Lisp jobs.  It is intended as a foundation for moving expensive,
;; snapshot-friendly editor work, such as parsing and fontification
;; preparation, out of the interactive Emacs process while keeping commits to
;; live buffers on the main Lisp thread.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup elisp-worker nil
  "Asynchronous Emacs Lisp worker processes."
  :group 'lisp)

(defcustom elisp-worker-response-dispatch-budget 0.005
  "Maximum seconds spent dispatching worker responses per timer.
The default is a small positive budget so bursts of worker responses yield
back to the command loop.  If nil, drain responses in one callback.  When
this is a positive number, process at least one response and then yield once
the budget is exhausted."
  :type '(choice (const :tag "Drain responses in one callback" nil)
                 (number :tag "Seconds"))
  :safe (lambda (value)
          (or (null value)
              (and (numberp value) (>= value 0))))
  :version "32.1"
  :group 'elisp-worker)

(defcustom elisp-worker-response-dispatch-defer-on-input t
  "Non-nil means worker response dispatch yields while input is pending.
When this is non-nil, worker filters dispatch at least one completed
response and then leave remaining responses for a later timer turn if
input is pending."
  :type 'boolean
  :safe #'booleanp
  :version "32.1"
  :group 'elisp-worker)

(defcustom elisp-worker-response-parse-budget 0.005
  "Maximum seconds spent parsing worker responses per filter call.
The default is a small positive budget so bursts of worker output yield
back to the command loop before callback dispatch.  If nil, parse all
available complete responses in one process-filter call.  When this is a
positive number, parse at least one complete response and then yield once
the budget is exhausted."
  :type '(choice (const :tag "Parse all available responses" nil)
                 (number :tag "Seconds"))
  :safe (lambda (value)
          (or (null value)
              (and (numberp value) (>= value 0))))
  :version "32.1"
  :group 'elisp-worker)

(defcustom elisp-worker-response-parse-defer-on-input t
  "Non-nil means worker response parsing yields while input is pending.
When this is non-nil, worker filters parse at least one completed
response and then leave remaining raw output for a later timer turn if
input is pending."
  :type 'boolean
  :safe #'booleanp
  :version "32.1"
  :group 'elisp-worker)

(defcustom elisp-worker-request-submit-budget 0.005
  "Maximum seconds spent submitting queued worker requests per timer.
The default is a small positive budget so bursts of worker requests yield
back to the command loop before all forms are serialized and sent.  If nil,
drain queued requests in one callback.  When this is a positive number,
submit at least one request and then yield once the budget is exhausted."
  :type '(choice (const :tag "Submit all queued requests" nil)
                 (number :tag "Seconds"))
  :safe (lambda (value)
          (or (null value)
              (and (numberp value) (>= value 0))))
  :version "32.1"
  :group 'elisp-worker)

(defcustom elisp-worker-request-submit-defer-on-input t
  "Non-nil means worker request submission yields while input is pending.
When this is non-nil, `elisp-worker-async-eval' submits the first request
eagerly, but leaves later burst requests for timer turns while input is
pending."
  :type 'boolean
  :safe #'booleanp
  :version "32.1"
  :group 'elisp-worker)

(cl-defstruct (elisp-worker
               (:constructor elisp-worker--make))
  process
  stderr-buffer
  (callbacks nil)
  (pending-requests nil)
  (pending-responses nil)
  submit-timer
  dispatch-timer
  parse-timer
  (partial-output "")
  (next-id 0))

(cl-defstruct (elisp-worker-pool
               (:constructor elisp-worker-pool--make))
  workers
  (cursor 0)
  target-size
  name
  grow-timer)

(defconst elisp-worker--loaded-file (or load-file-name buffer-file-name)
  "File from which `elisp-worker' was loaded.")

(defun elisp-worker--program ()
  "Return the Emacs executable used to start worker processes."
  (concat invocation-directory invocation-name))

(defun elisp-worker--library-file ()
  "Return the file used to load this library in a worker process."
  (or elisp-worker--loaded-file
      (locate-library "elisp-worker")
      (error "Cannot locate elisp-worker library file")))

(defun elisp-worker--command ()
  "Return the command used to start a worker process."
  (let ((library-file (elisp-worker--library-file)))
    (list (elisp-worker--program)
          "-Q" "--batch"
          "--eval"
          (prin1-to-string
           `(progn
              (load ,library-file nil t)
              (elisp-worker--stdio-server))))))

(defun elisp-worker--sentinel (process event)
  "Handle worker PROCESS lifecycle event EVENT."
  (let ((worker (process-get process 'elisp-worker)))
    (when (and worker
               (not (process-live-p process))
               (not (process-get process 'elisp-worker-shutting-down)))
      (mapc (lambda (entry)
              (when-let* ((error-fn (plist-get (cdr entry) :error-fn)))
                (funcall error-fn
                         (format "Worker process exited: %s"
                                 (string-trim-right event))
                         nil)))
            (elisp-worker-callbacks worker))
      (when (timerp (elisp-worker-dispatch-timer worker))
        (cancel-timer (elisp-worker-dispatch-timer worker)))
      (when (timerp (elisp-worker-parse-timer worker))
        (cancel-timer (elisp-worker-parse-timer worker)))
      (when (timerp (elisp-worker-submit-timer worker))
        (cancel-timer (elisp-worker-submit-timer worker)))
      (setf (elisp-worker-callbacks worker) nil
            (elisp-worker-pending-requests worker) nil
            (elisp-worker-pending-responses worker) nil
            (elisp-worker-submit-timer worker) nil
            (elisp-worker-dispatch-timer worker) nil
            (elisp-worker-parse-timer worker) nil))))

(defun elisp-worker--request-submit-budget ()
  "Return the active worker request submission budget, or nil."
  (and (numberp elisp-worker-request-submit-budget)
       (> elisp-worker-request-submit-budget 0)
       elisp-worker-request-submit-budget))

(defun elisp-worker--ensure-submit-timer (worker)
  "Ensure WORKER has one active request submission timer."
  (unless (timerp (elisp-worker-submit-timer worker))
    (setf (elisp-worker-submit-timer worker)
          (run-at-time 0 nil #'elisp-worker--submit-pending-requests
                       worker))))

(defun elisp-worker--send-request (worker request)
  "Serialize and send queued REQUEST to WORKER."
  (process-send-string
   (elisp-worker-process worker)
   (let ((print-escape-newlines t))
     (concat (prin1-to-string request) "\n"))))

(defun elisp-worker--submit-pending-requests (worker)
  "Submit queued requests for WORKER within the responsiveness budget."
  (when (timerp (elisp-worker-submit-timer worker))
    (cancel-timer (elisp-worker-submit-timer worker)))
  (setf (elisp-worker-submit-timer worker) nil)
  (let ((requests (elisp-worker-pending-requests worker))
        (budget (elisp-worker--request-submit-budget))
        (started (float-time))
        (submitted 0))
    (while (and requests
                (or (zerop submitted)
                    (and (not (and elisp-worker-request-submit-defer-on-input
                                   (input-pending-p)))
                         (or (not budget)
                             (< (- (float-time) started) budget)))))
      (let ((request (pop requests)))
        (setf (elisp-worker-pending-requests worker) requests)
        (setq submitted (1+ submitted))
        (elisp-worker--send-request worker request)))
    (when (elisp-worker-pending-requests worker)
      (elisp-worker--ensure-submit-timer worker))
    (list :submitted submitted
          :remaining (length (elisp-worker-pending-requests worker)))))

(defun elisp-worker--dispatch-response (worker response)
  "Dispatch one worker RESPONSE for WORKER."
  (let* ((id (plist-get response :id))
         (status (plist-get response :status))
         (callback (alist-get id (elisp-worker-callbacks worker))))
    (setf (elisp-worker-callbacks worker)
          (assq-delete-all id (elisp-worker-callbacks worker)))
    (pcase status
      ('ok
       (when-let* ((success-fn (plist-get callback :success-fn)))
         (funcall success-fn (plist-get response :value))))
      ('error
       (when-let* ((error-fn (plist-get callback :error-fn)))
         (funcall error-fn
                  (plist-get response :message)
                  (plist-get response :data)))))))

(defun elisp-worker--response-dispatch-budget ()
  "Return the active worker response dispatch budget, or nil."
  (and (numberp elisp-worker-response-dispatch-budget)
       (> elisp-worker-response-dispatch-budget 0)
       elisp-worker-response-dispatch-budget))

(defun elisp-worker--ensure-dispatch-timer (worker)
  "Ensure WORKER has one active response dispatch timer."
  (unless (timerp (elisp-worker-dispatch-timer worker))
    (setf (elisp-worker-dispatch-timer worker)
          (run-at-time 0 nil #'elisp-worker--dispatch-pending-responses
                       worker))))

(defun elisp-worker--dispatch-pending-responses (worker)
  "Dispatch queued responses for WORKER within the responsiveness budget."
  (when (timerp (elisp-worker-dispatch-timer worker))
    (cancel-timer (elisp-worker-dispatch-timer worker)))
  (setf (elisp-worker-dispatch-timer worker) nil)
  (let ((responses (elisp-worker-pending-responses worker))
        (budget (elisp-worker--response-dispatch-budget))
        (started (float-time))
        (processed 0))
    (while (and responses
                (or (zerop processed)
                    (and (not (and elisp-worker-response-dispatch-defer-on-input
                                   (input-pending-p)))
                         (or (not budget)
                             (< (- (float-time) started) budget)))))
      (let ((response (pop responses)))
        (setf (elisp-worker-pending-responses worker) responses)
        (setq processed (1+ processed))
        (elisp-worker--dispatch-response worker response)))
    (when (elisp-worker-pending-responses worker)
      (elisp-worker--ensure-dispatch-timer worker))
    (list :processed processed
          :remaining (length (elisp-worker-pending-responses worker)))))

(defun elisp-worker--response-parse-budget ()
  "Return the active worker response parse budget, or nil."
  (and (numberp elisp-worker-response-parse-budget)
       (> elisp-worker-response-parse-budget 0)
       elisp-worker-response-parse-budget))

(defun elisp-worker--ensure-parse-timer (worker)
  "Ensure WORKER has one active response parse timer."
  (unless (timerp (elisp-worker-parse-timer worker))
    (setf (elisp-worker-parse-timer worker)
          (run-at-time 0 nil #'elisp-worker--filter
                       (elisp-worker-process worker) ""))))

(defun elisp-worker--filter (process string)
  "Parse worker PROCESS output from STRING."
  (let* ((worker (process-get process 'elisp-worker))
         (parse-timer (elisp-worker-parse-timer worker)))
    (if (and (timerp parse-timer)
             (not (string-empty-p string)))
        (setf (elisp-worker-partial-output worker)
              (concat (elisp-worker-partial-output worker) string))
      (when (timerp parse-timer)
        (cancel-timer parse-timer)
        (setf (elisp-worker-parse-timer worker) nil))
      (let* ((output (concat (elisp-worker-partial-output worker) string))
             (budget (elisp-worker--response-parse-budget))
             (started (float-time))
             (parsed 0)
             line responses yielded)
        (while (and (not yielded)
                    (string-match "\n" output))
          (setq line (substring output 0 (match-beginning 0))
                output (substring output (match-end 0)))
          (while (string-prefix-p "Lisp expression: " line)
            (setq line (substring line (length "Lisp expression: "))))
          (unless (string-empty-p line)
            (setq parsed (1+ parsed))
            (condition-case err
                (push (car (read-from-string line)) responses)
              (error
               (message "Failed to parse elisp-worker response: %s"
                        (error-message-string err)))))
          (setq yielded
                (and (> parsed 0)
                     (string-match-p "\n" output)
                     (or (and elisp-worker-response-parse-defer-on-input
                              (input-pending-p))
                         (and budget
                              (>= (- (float-time) started) budget))))))
        (setf (elisp-worker-partial-output worker) output)
        (when (and (not (string-empty-p output))
                   (string-match-p "\n" output))
          (elisp-worker--ensure-parse-timer worker))
        (when responses
          (setf (elisp-worker-pending-responses worker)
                (nconc (elisp-worker-pending-responses worker)
                       (nreverse responses)))
          (elisp-worker--dispatch-pending-responses worker))))))

(defun elisp-worker-start (&optional name)
  "Start and return an asynchronous Emacs Lisp worker.
Optional NAME is used for the underlying process and buffers."
  (let* ((name (or name "elisp-worker"))
         (worker (elisp-worker--make))
         (buffer (generate-new-buffer (format " *%s output*" name)))
         (stderr-buffer (generate-new-buffer (format " *%s stderr*" name)))
         (process (make-process
                   :name name
                   :buffer buffer
                   :stderr stderr-buffer
                   :command (elisp-worker--command)
                   :connection-type 'pipe
                   :coding 'utf-8-unix
                   :filter #'elisp-worker--filter
                   :sentinel #'elisp-worker--sentinel
                   :noquery t)))
    (setf (elisp-worker-process worker) process)
    (setf (elisp-worker-stderr-buffer worker) stderr-buffer)
    (process-put process 'elisp-worker worker)
    worker))

(cl-defun elisp-worker-async-eval (worker form &key success-fn error-fn)
  "Evaluate FORM in WORKER and return the worker request id.
SUCCESS-FN, when non-nil, is called with the resulting value.  ERROR-FN,
when non-nil, is called with two arguments: an error message and an error
data object.  FORM and its result must be printable and readable."
  (let ((process (elisp-worker-process worker)))
    (unless (process-live-p process)
      (error "Worker process is not live"))
    (cl-incf (elisp-worker-next-id worker))
    (let ((id (elisp-worker-next-id worker)))
      (push (cons id (list :success-fn success-fn
                           :error-fn error-fn))
            (elisp-worker-callbacks worker))
      (setf (elisp-worker-pending-requests worker)
            (nconc (elisp-worker-pending-requests worker)
                   (list (list :op 'eval :id id :form form))))
      (if (and elisp-worker-request-submit-defer-on-input
               (input-pending-p)
               (> (length (elisp-worker-callbacks worker)) 1))
          (elisp-worker--ensure-submit-timer worker)
        (elisp-worker--submit-pending-requests worker))
      id)))

(defun elisp-worker-shutdown (worker)
  "Shut down WORKER and clean up its process buffers."
  (when-let* ((process (and worker (elisp-worker-process worker))))
    (process-put process 'elisp-worker-shutting-down t)
    (when (process-live-p process)
      (delete-process process))
    (when-let* ((buffer (process-buffer process)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))
    (when-let* ((buffer (elisp-worker-stderr-buffer worker)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))
    (when (timerp (elisp-worker-dispatch-timer worker))
      (cancel-timer (elisp-worker-dispatch-timer worker)))
    (when (timerp (elisp-worker-parse-timer worker))
      (cancel-timer (elisp-worker-parse-timer worker)))
    (when (timerp (elisp-worker-submit-timer worker))
      (cancel-timer (elisp-worker-submit-timer worker)))
    (setf (elisp-worker-callbacks worker) nil
          (elisp-worker-pending-requests worker) nil
          (elisp-worker-pending-responses worker) nil
          (elisp-worker-submit-timer worker) nil
          (elisp-worker-dispatch-timer worker) nil
          (elisp-worker-parse-timer worker) nil
          (elisp-worker-process worker) nil
          (elisp-worker-stderr-buffer worker) nil)))

(defun elisp-worker-pool-start (size &optional name)
  "Start and return an Emacs Lisp worker pool with SIZE workers.
Optional NAME is used as the process name prefix."
  (unless (and (integerp size) (> size 0))
    (error "Worker pool size must be a positive integer"))
  (let ((name (or name "elisp-worker-pool")))
    (elisp-worker-pool--make
     :workers (cl-loop for i from 1 to size
                       collect (elisp-worker-start
                                (format "%s-%d" name i)))
     :target-size size
     :name name)))

(defun elisp-worker-pool--schedule-grow (pool)
  "Schedule POOL to start one more worker on a later timer turn."
  (setf (elisp-worker-pool-grow-timer pool)
        (run-at-time 0 nil #'elisp-worker-pool--grow pool)))

(defun elisp-worker-pool--grow (pool)
  "Start one missing worker for POOL and reschedule if needed."
  (setf (elisp-worker-pool-grow-timer pool) nil)
  (let ((target-size (elisp-worker-pool-target-size pool))
        (workers (elisp-worker-pool-workers pool)))
    (when (and target-size (< (length workers) target-size))
      (let* ((next-index (1+ (length workers)))
             (name (or (elisp-worker-pool-name pool)
                       "elisp-worker-pool")))
        (setf (elisp-worker-pool-workers pool)
              (append workers
                      (list (elisp-worker-start
                             (format "%s-%d" name next-index))))))
      (when (< (length (elisp-worker-pool-workers pool)) target-size)
        (elisp-worker-pool--schedule-grow pool)))))

(defun elisp-worker-pool-start-lazy (size &optional name)
  "Start and return a worker pool that grows to SIZE over timer turns.
One worker is started immediately so callers can submit work right away.
Remaining workers are started one at a time from timers, avoiding a burst of
process startup work on the calling command."
  (unless (and (integerp size) (> size 0))
    (error "Worker pool size must be a positive integer"))
  (let* ((name (or name "elisp-worker-pool"))
         (pool (elisp-worker-pool--make
                :workers (list (elisp-worker-start
                                (format "%s-1" name)))
                :target-size size
                :name name)))
    (when (> size 1)
      (elisp-worker-pool--schedule-grow pool))
    pool))

(defun elisp-worker-pool--next-worker (pool)
  "Return the next worker from POOL and advance its cursor."
  (let* ((workers (elisp-worker-pool-workers pool))
         (length (length workers))
         (cursor (mod (elisp-worker-pool-cursor pool) length))
         (best-index cursor)
         (best-load nil))
    (dotimes (offset length)
      (let* ((index (mod (+ cursor offset) length))
             (worker (nth index workers))
             (load (+ (length (elisp-worker-callbacks worker))
                      (length (elisp-worker-pending-requests worker))
                      (length (elisp-worker-pending-responses worker)))))
        (when (or (null best-load) (< load best-load))
          (setq best-load load
                best-index index))))
    (setf (elisp-worker-pool-cursor pool) (mod (1+ best-index) length))
    (nth best-index workers)))

(cl-defun elisp-worker-pool-async-eval
    (pool form &key success-fn error-fn)
  "Evaluate FORM asynchronously on the next worker in POOL.
SUCCESS-FN and ERROR-FN are interpreted as in
`elisp-worker-async-eval'."
  (elisp-worker-async-eval
   (elisp-worker-pool--next-worker pool)
   form
   :success-fn success-fn
   :error-fn error-fn))

(defun elisp-worker-pool-shutdown (pool)
  "Shut down all workers in POOL."
  (when (timerp (elisp-worker-pool-grow-timer pool))
    (cancel-timer (elisp-worker-pool-grow-timer pool)))
  (mapc #'elisp-worker-shutdown (elisp-worker-pool-workers pool))
  (setf (elisp-worker-pool-workers pool) nil
        (elisp-worker-pool-grow-timer pool) nil))

(defun elisp-worker--write-response (response)
  "Write one worker protocol RESPONSE to standard output."
  (let ((print-escape-newlines t))
    (prin1 response)
    (terpri)
    (flush-standard-output)))

(defun elisp-worker--stdio-server ()
  "Run a line-oriented worker protocol on standard input and output."
  (while t
    (condition-case err
        (let* ((request (let ((standard-output 'external-debugging-output))
                          (read t)))
               (op (plist-get request :op))
               (id (plist-get request :id)))
          (pcase op
            ('eval
             (condition-case eval-err
                 (elisp-worker--write-response
                  (list :id id
                        :status 'ok
                        :value (eval (plist-get request :form) t)))
               (error
                (elisp-worker--write-response
                 (list :id id
                       :status 'error
                       :message (error-message-string eval-err)
                       :data eval-err)))))
            (_
             (elisp-worker--write-response
              (list :id id
                    :status 'error
                    :message (format "Unknown worker operation: %S" op)
                    :data nil)))))
      (end-of-file
       (kill-emacs 0))
      (error
       (elisp-worker--write-response
        (list :id nil
              :status 'error
              :message (error-message-string err)
              :data err))))))

(provide 'elisp-worker)

;;; elisp-worker.el ends here
