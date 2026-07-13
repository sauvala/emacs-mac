;;; multi-cursor.el --- Native multiple-cursor sessions  -*- lexical-binding: t; -*-

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

;; This library owns the buffer-local session state used by native
;; multiple cursors.  Editing commands and redisplay support are added in
;; later stages; this implementation defines cursor records, their lifecycle,
;; and the public API for managing secondary selections.

;;; Code:

(require 'cl-lib)

(defgroup multi-cursor nil
  "Edit a buffer through multiple native cursors."
  :group 'editing)

(defcustom multi-cursor-max-cursors 1000
  "Maximum number of cursors, including the ordinary primary cursor.

Nil means that no explicit limit is imposed."
  :type '(choice (const :tag "No limit" nil)
                 (integer :tag "Maximum cursors"))
  :group 'multi-cursor)

(defcustom multi-cursor-edit-lines-short-lines 'eol
  "How `multi-cursor-edit-lines' handles lines shorter than point's column.

The value `eol' puts a cursor at end of line, `skip' ignores the line,
`pad' inserts spaces up to the desired column, and `error' rejects the
operation before changing the buffer or cursor session."
  :type '(choice (const eol) (const skip) (const pad) (const error))
  :group 'multi-cursor)

(cl-defstruct (multi-cursor--cursor
               (:constructor multi-cursor--cursor-create))
  id point mark mark-active direction goal-column last-yank)

(defvar-local multi-cursor--cursors nil
  "Secondary cursor records owned by the current buffer.")

(defvar-local multi-cursor--next-id 0
  "Next secondary cursor identifier in the current buffer.")

(defconst multi-cursor--movement-commands
  '(forward-char backward-char
    forward-word backward-word
    move-beginning-of-line move-end-of-line
    next-logical-line previous-logical-line)
  "Commands implemented by the native multiple-cursor movement broadcaster.")

(defconst multi-cursor--valid-policies
  '(broadcast-movement batch-edit run-once custom-handler unsupported)
  "Policies accepted by `multi-cursor-register-command'.")

(defvar multi-cursor--command-policies (make-hash-table :test #'eq)
  "Global command policy registry for native multiple cursors.")

(defvar multi-cursor--dispatching nil
  "Non-nil while a command is running through the multiple-cursor dispatcher.")

;;;###autoload
(defun multi-cursor-register-command (command policy &optional handler)
  "Register COMMAND with POLICY and optional HANDLER.

HANDLER is required for `batch-edit' and `custom-handler'.  It receives
COMMAND, the raw prefix, KEYS, RECORD-FLAG, and SPECIAL, in that order.
Handlers which accept interactive input or honor RECORD-FLAG are responsible
for capturing that input once and updating the variable `command-history'.
Registering `broadcast-movement' without a handler is limited to the vetted
built-in movement commands; an explicit handler owns any third-party command's
no-edit, no-prompt, and no-buffer-switch contract."
  (unless (commandp command)
    (error "Not an interactive command: %S" command))
  (unless (memq policy multi-cursor--valid-policies)
    (error "Invalid multiple-cursor policy: %S" policy))
  (when (and (memq policy '(batch-edit custom-handler))
             (not (functionp handler)))
    (error "Policy %S requires a handler" policy))
  (when (and handler (not (functionp handler)))
    (error "Invalid multiple-cursor handler: %S" handler))
  (when (and handler (memq policy '(run-once unsupported)))
    (error "Policy %S does not accept a handler" policy))
  (when (and (eq policy 'broadcast-movement)
             (null handler)
             (not (memq command multi-cursor--movement-commands)))
    (error "%S is not a vetted multiple-cursor movement command" command))
  (puthash command (cons policy handler) multi-cursor--command-policies)
  command)

(defun multi-cursor--defer-delete-selection-p (command)
  "Return non-nil when delete-selection must defer for COMMAND.

This predicate only reads the policy registry and session state, so it is
safe to call from `delete-selection-pre-hook'.  Batch and custom handlers
own selection replacement.  Unsupported and unknown commands must reach the
dispatcher without the pre-command hook modifying the primary region."
  (and multi-cursor-mode
       (symbolp command)
       (let ((entry (gethash command multi-cursor--command-policies)))
         (or (null entry)
             (memq (car entry)
                   '(batch-edit custom-handler unsupported))))))

(defun multi-cursor--dispatch-policy
    (policy handler command record-flag keys special)
  "Execute COMMAND according to POLICY and optional HANDLER."
  (pcase policy
    ('run-once
     (call-interactively command record-flag keys))
    ((or 'batch-edit 'custom-handler)
     (funcall handler command current-prefix-arg keys record-flag special))
    ('broadcast-movement
     (if handler
         (funcall handler command current-prefix-arg keys record-flag special)
       (multi-cursor--broadcast-movement command record-flag)))
    ('unsupported
     (user-error "%S is not multiple-cursor safe" command))
    (_
     (error "Invalid multiple-cursor policy: %S" policy))))

(defun multi-cursor--command-execute (command record-flag keys special)
  "Dispatch COMMAND with RECORD-FLAG, KEYS, and SPECIAL by its policy."
  (let ((entry (gethash command multi-cursor--command-policies)))
    (unless entry
      (user-error "%S is not multiple-cursor safe" command))
    (let ((multi-cursor--dispatching t))
      (multi-cursor--dispatch-policy
       (car entry) (cdr entry) command record-flag keys special))))

(defvar-local multi-cursor--restriction-before-command nil
  "Restriction bounds and modification tick captured before a command.")

(defun multi-cursor--release-cursor (cursor)
  "Detach every marker owned by CURSOR."
  (set-marker (multi-cursor--cursor-point cursor) nil)
  (when (multi-cursor--cursor-mark cursor)
    (set-marker (multi-cursor--cursor-mark cursor) nil)))

(defun multi-cursor--same-state-p (left right)
  "Return non-nil when LEFT and RIGHT describe the same cursor state."
  (and (= (marker-position (multi-cursor--cursor-point left))
          (marker-position (multi-cursor--cursor-point right)))
       (let ((left-mark (multi-cursor--cursor-mark left))
             (right-mark (multi-cursor--cursor-mark right)))
         (if (and left-mark right-mark)
             (= (marker-position left-mark) (marker-position right-mark))
           (eq left-mark right-mark)))
       (eq (multi-cursor--cursor-mark-active left)
           (multi-cursor--cursor-mark-active right))
       (eq (multi-cursor--cursor-direction left)
           (multi-cursor--cursor-direction right))))

(defun multi-cursor--cursor-less-p (left right)
  "Return non-nil when LEFT sorts before RIGHT by point, then mark."
  (let ((left-point (marker-position (multi-cursor--cursor-point left)))
        (right-point (marker-position (multi-cursor--cursor-point right))))
    (if (/= left-point right-point)
        (< left-point right-point)
      (let ((left-mark (or (and (multi-cursor--cursor-mark left)
                                (marker-position
                                 (multi-cursor--cursor-mark left)))
                           -1))
            (right-mark (or (and (multi-cursor--cursor-mark right)
                                 (marker-position
                                  (multi-cursor--cursor-mark right)))
                            -1)))
        (if (/= left-mark right-mark)
            (< left-mark right-mark)
          (< (multi-cursor--cursor-id left)
             (multi-cursor--cursor-id right)))))))

(defun multi-cursor--at-state-p (cursor point mark mark-active direction)
  "Return non-nil when CURSOR matches POINT, MARK, MARK-ACTIVE and DIRECTION."
  (and (= (marker-position (multi-cursor--cursor-point cursor)) point)
       (let ((cursor-mark (multi-cursor--cursor-mark cursor)))
         (if cursor-mark
             (and mark (= (marker-position cursor-mark) mark))
           (null mark)))
       (eq (multi-cursor--cursor-mark-active cursor) mark-active)
       (eq (multi-cursor--cursor-direction cursor) direction)))

(defun multi-cursor--normalize ()
  "Sort secondary cursors and release duplicate cursor states."
  (let (normalized previous)
    (dolist (cursor (sort multi-cursor--cursors
                          #'multi-cursor--cursor-less-p))
      (if (or (= (marker-position (multi-cursor--cursor-point cursor))
                 (point))
              (and previous (multi-cursor--same-state-p previous cursor)))
          (multi-cursor--release-cursor cursor)
        (push cursor normalized)
        (setq previous cursor)))
    (setq multi-cursor--cursors (nreverse normalized))))

(defun multi-cursor--normalized-cursors ()
  "Normalize and return the current buffer's secondary cursor records."
  (multi-cursor--normalize)
  (copy-sequence multi-cursor--cursors))

(defun multi-cursor--sorted-cursors ()
  "Return a non-destructively sorted copy of the secondary cursor list."
  (sort (copy-sequence multi-cursor--cursors)
        #'multi-cursor--cursor-less-p))

(defun multi-cursor--add-cursor (point mark mark-active)
  "Add a secondary cursor at POINT with MARK and MARK-ACTIVE.

POINT and MARK are positions in the current buffer.  An exact duplicate
cursor state reuses the existing cursor record."
  (unless multi-cursor-mode
    (user-error "Multiple Cursor mode is not active"))
  (let* ((point-position (if (markerp point) (marker-position point) point))
         (mark-position (and mark
                             (if (markerp mark) (marker-position mark) mark)))
         (active (and mark-active t))
         (direction (cond ((null mark-position) nil)
                          ((< point-position mark-position) 'backward)
                          ((> point-position mark-position) 'forward)
                          (t nil)))
         (existing
          (cl-find-if (lambda (candidate)
                        (multi-cursor--at-state-p
                         candidate point-position mark-position
                         active direction))
                      multi-cursor--cursors)))
    (or existing
        (let ((cursor (multi-cursor--create-cursor
                       point-position mark-position active direction)))
          (multi-cursor--normalize)
          cursor))))

(defun multi-cursor--create-cursor (point mark active direction)
  "Create an unnormalized cursor with POINT, MARK, ACTIVE, and DIRECTION."
  (let ((cursor
         (multi-cursor--cursor-create
          :id (cl-incf multi-cursor--next-id)
          :point (copy-marker point)
          :mark (and mark (copy-marker mark))
          :mark-active active
          :direction direction)))
    (push cursor multi-cursor--cursors)
    cursor))

(defun multi-cursor--position (value name)
  "Return VALUE as an accessible current buffer position named NAME.

Signal `user-error' if VALUE is not an integer or a marker in the
current buffer, or if it is outside the accessible portion."
  (let ((position
         (cond
          ((integerp value) value)
          ((markerp value)
           (unless (eq (marker-buffer value) (current-buffer))
             (user-error "%s marker is not in the current buffer" name))
           (marker-position value))
          (t (user-error "%s is not an integer or marker" name)))))
    (unless (and (integerp position)
                 (<= (point-min) position (point-max)))
      (user-error "%s is outside the accessible buffer" name))
    position))

(defun multi-cursor--state-at (point mark mark-active)
  "Return an existing cursor matching POINT, MARK, and MARK-ACTIVE."
  (let ((active (and mark-active t))
        (direction (cond ((null mark) nil)
                         ((< point mark) 'backward)
                         ((> point mark) 'forward)
                         (t nil))))
    (cl-find-if (lambda (cursor)
                  (multi-cursor--at-state-p
                   cursor point mark active direction))
                multi-cursor--cursors)))

;;;###autoload
(defun multi-cursor-add-selection (point &optional mark mark-active)
  "Add a secondary selection at POINT with optional MARK.

MARK-ACTIVE non-nil records an active selection.  POINT and MARK may
be integers or markers in the accessible portion of the current buffer.
Return its stable numeric identifier.  An exact duplicate returns the
existing cursor's identifier."
  (let* ((point-position (multi-cursor--position point "Point"))
         (mark-position (and mark (multi-cursor--position mark "Mark"))))
    (when (and mark-active (null mark-position))
      (user-error "An active selection requires a mark"))
    (when (= point-position (point))
      (user-error "The primary cursor is already at that position"))
    (when (bound-and-true-p multiple-cursors-mode)
      (user-error
       "The external Multiple Cursors mode is active in this buffer"))
    (unless (or (null multi-cursor-max-cursors)
                (and (integerp multi-cursor-max-cursors)
                     (> multi-cursor-max-cursors 0)))
      (user-error "The multiple cursor limit must be nil or positive"))
    (multi-cursor--cursor-id
     (or (multi-cursor--state-at point-position mark-position mark-active)
         (progn
           (when (and multi-cursor-max-cursors
                      (>= (multi-cursor-count) multi-cursor-max-cursors))
             (user-error "Multiple cursor limit of %d reached"
                         multi-cursor-max-cursors))
           (unless multi-cursor-mode
             (multi-cursor-mode 1))
           (multi-cursor--add-cursor
            point-position mark-position mark-active))))))

(defun multi-cursor-add-at-point (&optional position)
  "Add a secondary cursor at POSITION, defaulting to point.

Signal `user-error' if POSITION is the ordinary primary point."
  (multi-cursor-add-selection (if (null position) (point) position)))

(defun multi-cursor-remove-at-point (&optional position)
  "Remove all secondary cursors at POSITION, defaulting to point.

Return the number of cursor records removed.  If this removes the last
secondary cursor, also end `multi-cursor-mode'."
  (interactive)
  (let ((target (multi-cursor--position
                 (if (null position) (point) position) "Position"))
        kept
        (removed 0))
    (dolist (cursor multi-cursor--cursors)
      (if (= (marker-position (multi-cursor--cursor-point cursor)) target)
          (progn
            (cl-incf removed)
            (multi-cursor--release-cursor cursor))
        (push cursor kept)))
    (setq multi-cursor--cursors (nreverse kept))
    (when (and multi-cursor-mode (null multi-cursor--cursors))
      (multi-cursor-mode -1))
    removed))

;;;###autoload
(defun multi-cursor-remove-all ()
  "Remove every secondary cursor and end `multi-cursor-mode'.

Return the number of cursor records removed."
  (interactive)
  (let ((count (length multi-cursor--cursors)))
    (if multi-cursor-mode
        (multi-cursor-mode -1)
      (multi-cursor--clear))
    count))

(defun multi-cursor-count ()
  "Return the cursor count, including the ordinary primary cursor."
  (1+ (length multi-cursor--cursors)))

(defun multi-cursor-selections ()
  "Return detached snapshots of the secondary cursor selections.

Each snapshot is a newly allocated plist containing integer positions;
mutating it cannot affect the underlying cursor record."
  (mapcar
   (lambda (cursor)
     (list :id (multi-cursor--cursor-id cursor)
           :point (marker-position (multi-cursor--cursor-point cursor))
           :mark (and (multi-cursor--cursor-mark cursor)
                      (marker-position (multi-cursor--cursor-mark cursor)))
           :mark-active (multi-cursor--cursor-mark-active cursor)
           :direction (multi-cursor--cursor-direction cursor)))
   (multi-cursor--sorted-cursors)))

(defun multi-cursor--ensure-capacity (additional)
  "Signal `user-error' unless ADDITIONAL cursors fit the configured limit."
  (when (bound-and-true-p multiple-cursors-mode)
    (user-error
     "The external Multiple Cursors mode is active in this buffer"))
  (unless (or (null multi-cursor-max-cursors)
              (and (integerp multi-cursor-max-cursors)
                   (> multi-cursor-max-cursors 0)))
    (user-error "The multiple cursor limit must be nil or positive"))
  (when (and multi-cursor-max-cursors
             (> (+ (multi-cursor-count) additional)
                multi-cursor-max-cursors))
    (user-error "Multiple cursor limit of %d reached"
                multi-cursor-max-cursors)))

(defun multi-cursor--state-key (point mark active)
  "Return an equal hash key for cursor POINT, MARK, and ACTIVE state."
  (list point mark (and active t)
        (cond ((null mark) nil)
              ((< point mark) 'backward)
              ((> point mark) 'forward)
              (t nil))))

(defun multi-cursor--state-table ()
  "Return an equal hash table mapping cursor states to internal records."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (cursor multi-cursor--cursors)
      (puthash
       (multi-cursor--state-key
        (marker-position (multi-cursor--cursor-point cursor))
        (and (multi-cursor--cursor-mark cursor)
             (marker-position (multi-cursor--cursor-mark cursor)))
        (multi-cursor--cursor-mark-active cursor))
       cursor table))
    table))

(defun multi-cursor--add-states (states)
  "Add normalized cursor STATES in bulk and return their stable IDs.

Each state is a list of POINT, optional MARK, and MARK-ACTIVE flag."
  (let ((table (multi-cursor--state-table))
        (additional 0)
        ids)
    (dolist (state states)
      (pcase-let ((`(,point ,mark ,active) state))
        (let ((key (multi-cursor--state-key point mark active)))
          (unless (gethash key table)
            (cl-incf additional)
            (puthash key :new table)))))
    (multi-cursor--ensure-capacity additional)
    (unless multi-cursor-mode
      (multi-cursor-mode 1))
    (dolist (state states)
      (pcase-let* ((`(,point ,mark ,mark-active) state)
                   (active (and mark-active t))
                   (key (multi-cursor--state-key point mark active))
                   (entry (gethash key table))
                   (cursor (if (eq entry :new)
                               (let ((new
                                      (multi-cursor--create-cursor
                                       point mark active (nth 3 key))))
                                 (puthash key new table)
                                 new)
                             entry)))
        (push (multi-cursor--cursor-id cursor) ids)))
    (multi-cursor--normalize)
    (nreverse ids)))

(defun multi-cursor--line-target (delta)
  "Return the position DELTA logical lines away at the current column."
  (let ((column (current-column)))
    (save-excursion
      (unless (= (forward-line delta) 0)
        (user-error "No line in that direction"))
      (multi-cursor--move-to-logical-column column))))

(defun multi-cursor--move-to-logical-column (column &optional pad)
  "Move physically to logical COLUMN, padding a short line when PAD is non-nil.

If COLUMN falls inside a tab or wide character, stop before that character."
  (move-to-column column)
  (cond
   ((< (current-column) column)
    (when pad
      (move-to-column column t)))
   ((> (current-column) column)
    (backward-char 1)))
  (point))

(defun multi-cursor--add-line-cursor (position column)
  "Add a cursor at POSITION with logical goal COLUMN and return its ID."
  (let* ((id (multi-cursor-add-at-point position))
         (cursor (cl-find id multi-cursor--cursors
                          :key #'multi-cursor--cursor-id)))
    (setf (multi-cursor--cursor-goal-column cursor) column)
    id))

;;;###autoload
(defun multi-cursor-add-above ()
  "Add a secondary cursor one logical line above point."
  (interactive)
  (multi-cursor--add-line-cursor
   (multi-cursor--line-target -1) (current-column)))

;;;###autoload
(defun multi-cursor-add-below ()
  "Add a secondary cursor one logical line below point."
  (interactive)
  (multi-cursor--add-line-cursor
   (multi-cursor--line-target 1) (current-column)))

(defun multi-cursor--edit-line-targets (column start end primary-line)
  "Return line-start markers between START and END except PRIMARY-LINE.

Signal before returning if COLUMN encounters a short line under the
`error' policy."
  (unless (memq multi-cursor-edit-lines-short-lines '(eol skip pad error))
    (user-error "Invalid short-line policy: %S"
                multi-cursor-edit-lines-short-lines))
  (let (targets)
    (save-excursion
      (goto-char start)
      (beginning-of-line)
      (let ((last-line (save-excursion
                         (goto-char end)
                         (line-beginning-position))))
        (while (<= (line-beginning-position) last-line)
          (let* ((line (line-beginning-position))
                 (reached (save-excursion
                            (move-to-column column)
                            (current-column)))
                 (short (< reached column)))
            (unless (= line primary-line)
              (when (and short
                         (eq multi-cursor-edit-lines-short-lines 'error))
                (mapc (lambda (marker) (set-marker marker nil)) targets)
                (user-error "Short line encountered"))
              (unless (and short
                           (eq multi-cursor-edit-lines-short-lines 'skip))
                (push (copy-marker line) targets))))
          (forward-line 1))))
    (nreverse targets)))

(defun multi-cursor--new-line-target-count (targets column)
  "Return how many TARGETS would add a new caret at COLUMN."
  (let ((table (multi-cursor--state-table)))
    (cl-count-if
     (lambda (line)
       (save-excursion
         (goto-char line)
         (let ((position (multi-cursor--move-to-logical-column column)))
           (or (and (eq multi-cursor-edit-lines-short-lines 'pad)
                    (< (current-column) column))
               (null (gethash (multi-cursor--state-key position nil nil)
                              table))))))
     targets)))

;;;###autoload
(defun multi-cursor-edit-lines ()
  "Add one cursor to each logical line covered by the active region.

Cursors use point's logical column.  The option
`multi-cursor-edit-lines-short-lines' controls short lines."
  (interactive)
  (unless (use-region-p)
    (user-error "An active region is required"))
  (let* ((column (current-column))
         (primary-line (line-beginning-position))
         (start (region-beginning))
         (end (region-end))
         (targets (multi-cursor--edit-line-targets
                   column start end primary-line))
         positions
         ids)
    (unwind-protect
        (progn
          (unless targets
            (user-error "The region covers no additional lines"))
          (multi-cursor--ensure-capacity
           (multi-cursor--new-line-target-count targets column))
          (setq positions
                (if (eq multi-cursor-edit-lines-short-lines 'pad)
                    (atomic-change-group
                      (mapcar
                       (lambda (line)
                         (save-excursion
                           (goto-char line)
                           (multi-cursor--move-to-logical-column column t)))
                       targets))
                  (mapcar
                   (lambda (line)
                     (save-excursion
                       (goto-char line)
                       (multi-cursor--move-to-logical-column column)))
                   targets)))
          (setq ids
                (multi-cursor--add-states
                 (mapcar (lambda (position) (list position nil nil))
                         positions)))
          (dolist (id ids)
            (setf (multi-cursor--cursor-goal-column
                   (cl-find id multi-cursor--cursors
                            :key #'multi-cursor--cursor-id))
                  column))
          (deactivate-mark)
          ids)
      (mapc (lambda (marker) (set-marker marker nil)) targets))))

(defun multi-cursor--occurrence-source ()
  "Return source text, bounds, direction, and fallback status."
  (if (use-region-p)
      (let ((beg (region-beginning))
            (end (region-end)))
        (list :text (buffer-substring-no-properties beg end)
              :beg beg :end end
              :direction (if (> (point) (mark)) 'forward 'backward)
              :fallback nil))
    (let ((bounds (bounds-of-thing-at-point 'symbol)))
      (unless bounds
        (user-error "No active region or symbol at point"))
      (list :text (buffer-substring-no-properties (car bounds) (cdr bounds))
            :beg (car bounds) :end (cdr bounds)
            :direction 'forward :fallback t))))

(defun multi-cursor--selected-bounds-table (source-beg source-end)
  "Return selected ranges including SOURCE-BEG and SOURCE-END in a hash table."
  (let ((table (make-hash-table :test #'equal)))
    (puthash (cons source-beg source-end) t table)
    (dolist (cursor multi-cursor--cursors)
      (let ((mark (multi-cursor--cursor-mark cursor)))
        (when (and mark (multi-cursor--cursor-mark-active cursor))
          (puthash
           (cons (min (marker-position (multi-cursor--cursor-point cursor))
                      (marker-position mark))
                 (max (marker-position (multi-cursor--cursor-point cursor))
                      (marker-position mark)))
           t table))))
    table))

(defun multi-cursor--occurrence-candidates (source scope)
  "Return unselected literal match bounds for SOURCE according to SCOPE."
  (let ((text (plist-get source :text))
        (source-beg (plist-get source :beg))
        (source-end (plist-get source :end))
        (selected (multi-cursor--selected-bounds-table
                   (plist-get source :beg) (plist-get source :end)))
        candidates)
    (save-excursion
      (pcase scope
        ('next
         (goto-char source-end)
         (while (and (null candidates) (search-forward text nil t))
           (let ((beg (match-beginning 0)) (end (match-end 0)))
             (unless (gethash (cons beg end) selected)
               (setq candidates (list (cons beg end)))))))
        ('previous
         (goto-char source-beg)
         (while (and (null candidates) (search-backward text nil t))
           (let ((beg (match-beginning 0)) (end (match-end 0)))
             (unless (gethash (cons beg end) selected)
               (setq candidates (list (cons beg end)))))))
        ('all
         (goto-char (point-min))
         (while (search-forward text nil t)
           (let ((beg (match-beginning 0)) (end (match-end 0)))
             (unless (gethash (cons beg end) selected)
               (push (cons beg end) candidates))))
         (setq candidates (nreverse candidates)))))
    candidates))

(defun multi-cursor--activate-fallback-source (source)
  "Make the symbol bounds in SOURCE the active primary selection."
  (when (plist-get source :fallback)
    (goto-char (plist-get source :end))
    (set-marker (mark-marker) (plist-get source :beg) (current-buffer))
    (setq mark-active t)))

(defun multi-cursor--add-occurrences (scope)
  "Add occurrence selections according to SCOPE and return their IDs."
  (let* ((source (multi-cursor--occurrence-source))
         (_ (when (string-empty-p (plist-get source :text))
              (user-error "The occurrence source is empty")))
         (candidates (multi-cursor--occurrence-candidates source scope))
         (direction (plist-get source :direction))
         ids)
    (unless candidates
      (user-error "No unselected occurrence in that direction"))
    (multi-cursor--ensure-capacity (length candidates))
    (multi-cursor--activate-fallback-source source)
    (setq ids
          (multi-cursor--add-states
           (mapcar
            (lambda (bounds)
              (if (eq direction 'forward)
                  (list (cdr bounds) (car bounds) t)
                (list (car bounds) (cdr bounds) t)))
            candidates)))
    (if (eq scope 'all) ids (car ids))))

;;;###autoload
(defun multi-cursor-select-next-occurrence ()
  "Select the next unselected literal occurrence without wrapping."
  (interactive)
  (multi-cursor--add-occurrences 'next))

;;;###autoload
(defun multi-cursor-select-previous-occurrence ()
  "Select the previous unselected literal occurrence without wrapping."
  (interactive)
  (multi-cursor--add-occurrences 'previous))

;;;###autoload
(defun multi-cursor-select-all-occurrences ()
  "Select every other literal occurrence in the accessible buffer."
  (interactive)
  (multi-cursor--add-occurrences 'all))

;;;###autoload
(defun multi-cursor-add-at-mouse (event)
  "Add a secondary cursor at the end position of mouse EVENT.

EVENT must designate a live window displaying the current buffer.  This
command has no global binding by default."
  (interactive "e")
  (unless (mouse-event-p event)
    (user-error "Not a mouse event"))
  (let* ((position (event-end event))
         (window (and position (posn-window position)))
         (point (and position (posn-point position))))
    (unless (window-live-p window)
      (user-error "Mouse event has no live window"))
    (unless (eq (window-buffer window) (current-buffer))
      (user-error "Mouse event is for another buffer"))
    (when (posn-area position)
      (user-error "Mouse event is outside the window text area"))
    (unless (or (integerp point) (markerp point))
      (user-error "Mouse event has no buffer position"))
    (multi-cursor-add-at-point point)))

(defun multi-cursor--set-record-state (cursor point mark active goal-column)
  "Set CURSOR to POINT, MARK, ACTIVE, and GOAL-COLUMN."
  (set-marker (multi-cursor--cursor-point cursor) point (current-buffer))
  (if mark
      (if (multi-cursor--cursor-mark cursor)
          (set-marker (multi-cursor--cursor-mark cursor)
                      mark (current-buffer))
        (setf (multi-cursor--cursor-mark cursor) (copy-marker mark)))
    (when (multi-cursor--cursor-mark cursor)
      (set-marker (multi-cursor--cursor-mark cursor) nil)
      (setf (multi-cursor--cursor-mark cursor) nil)))
  (setf (multi-cursor--cursor-mark-active cursor) (and active t)
        (multi-cursor--cursor-direction cursor)
        (cond ((null mark) nil)
              ((< point mark) 'backward)
              ((> point mark) 'forward)
              (t nil))
        (multi-cursor--cursor-goal-column cursor) goal-column
        (multi-cursor--cursor-last-yank cursor) nil))

(defun multi-cursor--movement-state ()
  "Return point, mark, active state, and goal column for the primary cursor."
  (list (point) (mark t) (and mark-active t) temporary-goal-column))

(defun multi-cursor--cursor-movement-state (cursor)
  "Return CURSOR's point, mark, active state, and goal column."
  (list (marker-position (multi-cursor--cursor-point cursor))
        (and (multi-cursor--cursor-mark cursor)
             (marker-position (multi-cursor--cursor-mark cursor)))
        (and (multi-cursor--cursor-mark-active cursor) t)
        (multi-cursor--cursor-goal-column cursor)))

(defun multi-cursor--install-movement-state (state)
  "Install primary point and selection variables from STATE."
  (goto-char (nth 0 state))
  (set-marker (mark-marker) (nth 1 state)
              (and (nth 1 state) (current-buffer)))
  (setq mark-active (nth 2 state)
        temporary-goal-column (nth 3 state)))

(defun multi-cursor--capture-cursor-movement (cursor state)
  "Store successful movement STATE in CURSOR."
  (multi-cursor--set-record-state
   cursor (nth 0 state) (nth 1 state) (nth 2 state) (nth 3 state)))

(defun multi-cursor--invoke-movement (command argument canonical-last-command)
  "Invoke vetted movement COMMAND once, accepting boundary clamping.

ARGUMENT is the prefix converted once for the whole broadcast.
CANONICAL-LAST-COMMAND controls logical-line goal-column continuity."
  (let ((last-command
         (if (memq command '(next-logical-line previous-logical-line))
             canonical-last-command
           last-command)))
    (condition-case nil
        (funcall command argument)
      ((beginning-of-buffer end-of-buffer) nil))))

(defun multi-cursor--broadcast-movement (command record-flag)
  "Run vetted pure movement COMMAND for the primary and every secondary.

All results are staged before cursor records are changed.  Beginning- and
end-of-buffer signals retain the clamped result for that cursor; any other
nonlocal exit restores the original primary state and commits no secondary
result.  If RECORD-FLAG is non-nil, record one invocation in
the variable `command-history'."
  (unless (memq command multi-cursor--movement-commands)
    (user-error "%S is not a vetted multiple-cursor movement command" command))
  (let* ((cursors (multi-cursor--normalized-cursors))
         (primary-before (multi-cursor--movement-state))
         (argument (prefix-numeric-value current-prefix-arg))
         (canonical-last-command
          (pcase last-command
            ((or 'next-line 'next-logical-line) 'next-line)
            ((or 'previous-line 'previous-logical-line) 'previous-line)))
         (states (cons primary-before
                       (mapcar #'multi-cursor--cursor-movement-state cursors)))
         results
         completed)
    (let ((inhibit-redisplay t)
          (pre-command-hook nil)
          (post-command-hook nil)
          (next-line-add-newlines nil))
      (unwind-protect
          (progn
            (dolist (state states)
              (multi-cursor--install-movement-state state)
              (multi-cursor--invoke-movement
               command argument canonical-last-command)
              (push (multi-cursor--movement-state) results))
            (setq results (nreverse results)
                  completed t))
        (multi-cursor--install-movement-state
         (if completed (car results) primary-before))))
    (cl-mapc #'multi-cursor--capture-cursor-movement
             cursors (cdr results))
    (multi-cursor--normalize)
    (when record-flag
      (add-to-history 'command-history (list command argument) nil t))
    nil))

(defun multi-cursor--cycle (direction)
  "Exchange primary state with the next secondary in DIRECTION."
  (multi-cursor--normalized-cursors)
  (unless multi-cursor--cursors
    (user-error "No secondary cursors"))
  (let* ((primary-point (point))
         (primary-mark (mark t))
         (primary-active mark-active)
         (primary-goal temporary-goal-column)
         (sorted (multi-cursor--sorted-cursors))
         (target
          (if (eq direction 'forward)
              (or (cl-find-if
                   (lambda (cursor)
                     (> (marker-position
                         (multi-cursor--cursor-point cursor))
                        primary-point))
                   sorted)
                  (car sorted))
            (or (cl-find-if
                 (lambda (cursor)
                   (< (marker-position
                       (multi-cursor--cursor-point cursor))
                      primary-point))
                 (reverse sorted))
                (car (last sorted)))))
         (target-point (marker-position
                        (multi-cursor--cursor-point target)))
         (target-mark (and (multi-cursor--cursor-mark target)
                           (marker-position
                            (multi-cursor--cursor-mark target))))
         (target-active (multi-cursor--cursor-mark-active target))
         (target-goal (multi-cursor--cursor-goal-column target)))
    (multi-cursor--set-record-state
     target primary-point primary-mark primary-active primary-goal)
    (goto-char target-point)
    (set-marker (mark-marker) target-mark
                (and target-mark (current-buffer)))
    (setq mark-active target-active
          temporary-goal-column target-goal)
    (let* ((positions
            (sort (cons (point)
                        (mapcar
                         (lambda (cursor)
                           (marker-position
                            (multi-cursor--cursor-point cursor)))
                         multi-cursor--cursors))
                  #'<))
           (ordinal (1+ (cl-position (point) positions :test #'=))))
      (message "Cursor %d of %d" ordinal (multi-cursor-count))
      ordinal)))

;;;###autoload
(defun multi-cursor-cycle-forward ()
  "Exchange the primary cursor with the next cursor in buffer order."
  (interactive)
  (multi-cursor--cycle 'forward))

;;;###autoload
(defun multi-cursor-cycle-backward ()
  "Exchange the primary cursor with the previous cursor in buffer order."
  (interactive)
  (multi-cursor--cycle 'backward))

(defun multi-cursor--remove-inaccessible-cursors ()
  "Remove secondary cursors outside the accessible portion of the buffer."
  (when multi-cursor-mode
    (let (kept (removed 0))
      (dolist (cursor multi-cursor--cursors)
        (let ((cursor-point
               (marker-position (multi-cursor--cursor-point cursor)))
              (cursor-mark
               (and (multi-cursor--cursor-mark cursor)
                    (marker-position (multi-cursor--cursor-mark cursor)))))
          (if (and (<= (point-min) cursor-point (point-max))
                   (or (null cursor-mark)
                       (<= (point-min) cursor-mark (point-max))))
              (push cursor kept)
            (cl-incf removed)
            (multi-cursor--release-cursor cursor))))
      (setq multi-cursor--cursors (nreverse kept))
      (when (> removed 0)
        (when (null multi-cursor--cursors)
          (multi-cursor-mode -1))
        (message "Removed %d inaccessible cursor%s"
                 removed (if (= removed 1) "" "s"))))))

(defun multi-cursor--record-restriction-before-command ()
  "Record restriction bounds before the current command."
  (setq multi-cursor--restriction-before-command
        (list (point-min) (point-max) (buffer-chars-modified-tick))))

(defun multi-cursor--maybe-remove-inaccessible-cursors ()
  "Remove inaccessible cursors only after a restriction-only command."
  (when (and multi-cursor-mode
             (buffer-narrowed-p)
             multi-cursor--restriction-before-command
             (= (nth 2 multi-cursor--restriction-before-command)
                (buffer-chars-modified-tick))
             (or (/= (nth 0 multi-cursor--restriction-before-command)
                     (point-min))
                 (/= (nth 1 multi-cursor--restriction-before-command)
                     (point-max))))
    (multi-cursor--remove-inaccessible-cursors))
  (setq multi-cursor--restriction-before-command nil))

(defun multi-cursor--remove-lifecycle-hooks ()
  "Remove lifecycle hooks installed for the current buffer."
  (remove-hook 'kill-buffer-hook #'multi-cursor--end-session t)
  (remove-hook 'before-revert-hook #'multi-cursor--end-session t)
  (remove-hook 'change-major-mode-hook #'multi-cursor--end-session t)
  (remove-hook 'pre-command-hook
               #'multi-cursor--record-restriction-before-command t)
  (remove-hook 'post-command-hook
               #'multi-cursor--maybe-remove-inaccessible-cursors t))

(defun multi-cursor--clear ()
  "Release all cursor records and reset the current buffer's session."
  (mapc #'multi-cursor--release-cursor multi-cursor--cursors)
  (setq multi-cursor--cursors nil
        multi-cursor--next-id 0)
  (multi-cursor--remove-lifecycle-hooks))

(defun multi-cursor--end-session ()
  "End Multiple Cursor mode in the current buffer."
  (when multi-cursor-mode
    (multi-cursor-mode -1)))

(defun multi-cursor--start ()
  "Initialize and attach lifecycle hooks for the current buffer."
  (unless (local-variable-p 'multi-cursor--cursors)
    (setq-local multi-cursor--cursors nil))
  (unless (local-variable-p 'multi-cursor--next-id)
    (setq-local multi-cursor--next-id 0))
  (add-hook 'kill-buffer-hook #'multi-cursor--end-session nil t)
  (add-hook 'before-revert-hook #'multi-cursor--end-session nil t)
  (add-hook 'change-major-mode-hook #'multi-cursor--end-session nil t)
  (add-hook 'pre-command-hook
            #'multi-cursor--record-restriction-before-command nil t)
  (add-hook 'post-command-hook
            #'multi-cursor--maybe-remove-inaccessible-cursors nil t))

;;;###autoload
(define-minor-mode multi-cursor-mode
  "Edit the current buffer using multiple native cursors."
  :lighter (:eval (format " MC:%d" (multi-cursor-count)))
  :group 'multi-cursor
  (if multi-cursor-mode
      (if (bound-and-true-p multiple-cursors-mode)
          (progn
            (when (memq #'multi-cursor--end-session kill-buffer-hook)
              (multi-cursor--clear))
            (setq multi-cursor-mode nil)
            (user-error
             "The external Multiple Cursors mode is active in this buffer"))
        (multi-cursor--start))
    (multi-cursor--clear)))

(dolist (command '(multi-cursor-mode
                   multi-cursor-remove-at-point
                   multi-cursor-remove-all
                   multi-cursor-add-above
                   multi-cursor-add-below
                   multi-cursor-edit-lines
                   multi-cursor-select-next-occurrence
                   multi-cursor-select-previous-occurrence
                   multi-cursor-select-all-occurrences
                   multi-cursor-add-at-mouse
                   multi-cursor-cycle-forward
                   multi-cursor-cycle-backward
                   save-buffer
                   recenter-top-bottom
                   scroll-up-command
                   scroll-down-command
                   universal-argument
                   universal-argument-more
                   universal-argument-minus
                   universal-argument-other-key
                   digit-argument
                   negative-argument))
  (when (commandp command)
    (multi-cursor-register-command command 'run-once)))

(dolist (command multi-cursor--movement-commands)
  (multi-cursor-register-command command 'broadcast-movement))

(dolist (command '(undo undo-only undo-redo
                   keyboard-quit execute-extended-command execute-kbd-macro
                   isearch-forward isearch-backward
                   query-replace query-replace-regexp
                   right-char left-char right-word left-word
                   next-line previous-line
                   beginning-of-visual-line end-of-visual-line))
  (when (commandp command)
    (multi-cursor-register-command command 'unsupported)))

(provide 'multi-cursor)

;;; multi-cursor.el ends here
