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

;; This library implements buffer-local native multiple-cursor sessions.
;; It manages marker-backed selections, explicit command policies, atomic
;; batched editing, kill and yank integration, and immutable redisplay
;; snapshots.  See Info node `(emacs) Multiple Cursors' for user commands and
;; `(elisp) Multiple-Cursor Command Dispatch' for package integration.

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

(defface multi-cursor-region-face
  '((t :inherit region))
  "Face used for active secondary selections."
  :group 'multi-cursor)

(defface multi-cursor-caret-face
  '((t :inherit cursor))
  "Face used for secondary carets without native backend support."
  :group 'multi-cursor)

(cl-defstruct (multi-cursor--cursor
               (:constructor multi-cursor--cursor-create))
  id point mark mark-active direction goal-column last-yank)

(cl-defstruct (multi-cursor--edit-state
               (:constructor multi-cursor--edit-state-create))
  cursor id primary point mark active direction goal-column last-yank)

(cl-defstruct (multi-cursor--edit
               (:constructor multi-cursor--edit-create))
  beg end string survivor members)

(cl-defstruct (multi-cursor--yank-pop-state
               (:constructor multi-cursor--yank-pop-state-create))
  tick restriction cursors next-id ranges before-p window-start)

(cl-defstruct (multi-cursor--undo-generation
               (:constructor multi-cursor--undo-generation-create))
  "One session-owned ordinary undo generation.

The text change itself remains entirely in `buffer-undo-list'.  This record
only associates its two ordinary undo states with the corresponding native
cursor snapshots and the invariants needed to reject stale history."
  before-states before-cursors before-next-id before-restriction
  before-tick before-undo-list
  after-states after-cursors after-next-id after-restriction
  after-tick after-undo-list)

(defvar-local multi-cursor--cursors nil
  "Secondary cursor records owned by the current buffer.")

(defvar-local multi-cursor--next-id 0
  "Next secondary cursor identifier in the current buffer.")

(defvar-local multi-cursor--undo-generations nil
  "Session-owned edit generations which may be undone.")

(defvar-local multi-cursor--redo-generations nil
  "Session-owned edit generations which may be redone.")

(defvar-local multi-cursor--yank-pop-state nil
  "Validated ranges produced by the latest native `yank' or `yank-pop'.")

(defvar-local multi-cursor--redisplay-snapshot nil
  "Last immutable snapshot built for redisplay in the current buffer.")

(defvar-local multi-cursor--redisplay-snapshot-tick nil
  "Character-change tick represented by the cached redisplay snapshot.")

(defvar-local multi-cursor--redisplay-snapshot-dirty-p t
  "Non-nil means the cached redisplay snapshot must be rebuilt.")

(defvar-local multi-cursor--region-overlays nil
  "Overlays displaying active secondary selections in this buffer.")

(defvar-local multi-cursor--caret-overlays nil
  "Overlays displaying fallback secondary carets in this buffer.")

(defvar-local multi-cursor--presentation-snapshot nil
  "Redisplay snapshot represented by the current presentation overlays.")

(defvar-local multi-cursor--presentation-window nil
  "Selected window for which presentation overlays were built.")

(defvar-local multi-cursor--presentation-native-p nil
  "Non-nil when native carets were available for the current presentation.")

(defvar multi-cursor--redisplay-window nil
  "Window which most recently received a secondary-cursor snapshot.")

(defconst multi-cursor--scan-motion-commands
  '(forward-sexp backward-sexp forward-list backward-list
    down-list up-list backward-up-list)
  "Movement commands which report an unreachable target with `scan-error'.

For these commands a `scan-error' is the local boundary condition, exactly
as `beginning-of-buffer' is for `forward-char': the affected cursor stays
put while the others move.")

(defconst multi-cursor--argumentless-movement-commands
  '(back-to-indentation)
  "Vetted movement commands which accept no argument at all.")

(defconst multi-cursor--movement-commands
  (append
   ;; Character, word, and line motion.
   '(forward-char backward-char left-char right-char
     forward-word backward-word left-word right-word
     move-beginning-of-line move-end-of-line
     beginning-of-line end-of-line
     next-line previous-line next-logical-line previous-logical-line)
   multi-cursor--argumentless-movement-commands
   ;; Balanced-expression motion.  Mode hooks reach these through
   ;; `forward-sexp-function', which is pure point motion by contract.
   multi-cursor--scan-motion-commands
   ;; Larger textual units.  Each clamps at the accessible boundary.
   '(forward-paragraph backward-paragraph
     forward-sentence backward-sentence
     beginning-of-defun end-of-defun))
  "Commands implemented by the native multiple-cursor movement broadcaster.

Every command here moves point without editing text, prompting, pushing the
mark, or switching buffers, so its result can be staged independently for
each cursor.")

(defconst multi-cursor--valid-policies
  '(broadcast-movement batch-edit run-once custom-handler unsupported)
  "Policies accepted by `multi-cursor-register-command'.")

(defvar multi-cursor--command-policies (make-hash-table :test #'eq)
  "Global command policy registry for native multiple cursors.")

(defvar multi-cursor--dispatching nil
  "Non-nil while a command is running through the multiple-cursor dispatcher.")

(declare-function multi-cursor--native-decorations-p "window.c" (window))

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
  (setq multi-cursor--redisplay-snapshot-dirty-p t)
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
    (setq multi-cursor--cursors (nreverse normalized)
          multi-cursor--redisplay-snapshot-dirty-p t)))

(defun multi-cursor--normalized-cursors ()
  "Normalize and return the current buffer's secondary cursor records."
  (multi-cursor--normalize)
  (copy-sequence multi-cursor--cursors))

(defun multi-cursor--sorted-cursors ()
  "Return a non-destructively sorted copy of the secondary cursor list."
  (sort (copy-sequence multi-cursor--cursors)
        #'multi-cursor--cursor-less-p))

(defun multi-cursor--clear-presentation ()
  "Delete presentation overlays owned by the current buffer."
  (mapc #'delete-overlay multi-cursor--region-overlays)
  (mapc #'delete-overlay multi-cursor--caret-overlays)
  (setq multi-cursor--region-overlays nil
        multi-cursor--caret-overlays nil
        multi-cursor--presentation-snapshot nil
        multi-cursor--presentation-window nil
        multi-cursor--presentation-native-p nil))

(defun multi-cursor--make-presentation-overlay (id beg end window face)
  "Return an evaporating cursor ID overlay from BEG to END in WINDOW.

FACE is the face used to render the overlay."
  (let ((overlay (make-overlay beg end nil nil nil)))
    (overlay-put overlay 'multi-cursor-id id)
    (overlay-put overlay 'face face)
    (overlay-put overlay 'window window)
    (overlay-put overlay 'evaporate t)
    (overlay-put overlay 'priority
                 (if (eq face 'multi-cursor-caret-face)
                     '(nil . 101)
                   '(nil . 100)))
    overlay))

(defun multi-cursor--caret-overlay-bounds (position)
  "Return face-overlay caret bounds for POSITION."
  (if (< position (point-max))
      (cons position (1+ position))
    (cons (max (point-min) (1- position)) position)))

(defun multi-cursor--presentation-table (overlays)
  "Return a cursor-ID table containing OVERLAYS."
  (let ((table (make-hash-table :test #'eql)))
    (dolist (overlay overlays)
      (puthash (overlay-get overlay 'multi-cursor-id) overlay table))
    table))

(defun multi-cursor--reuse-presentation-overlay
    (id beg end window face table)
  "Reuse cursor ID's overlay in TABLE at BEG and END, or create it.

WINDOW restricts display and FACE is used when a new overlay is needed."
  (let ((overlay (gethash id table)))
    (if overlay
        (progn
          (remhash id table)
          (unless (and (eq (overlay-buffer overlay) (current-buffer))
                       (= (overlay-start overlay) beg)
                       (= (overlay-end overlay) end))
            (move-overlay overlay beg end (current-buffer)))
          (unless (eq (overlay-get overlay 'window) window)
            (overlay-put overlay 'window window))
          overlay)
      (multi-cursor--make-presentation-overlay id beg end window face))))

(defun multi-cursor--native-cursor-decorations-p (window)
  "Return non-nil when WINDOW's backend paints secondary carets natively."
  (and (fboundp 'multi-cursor--native-decorations-p)
       (multi-cursor--native-decorations-p window)))

(defun multi-cursor--sync-presentation (window snapshot native-p)
  "Synchronize overlays for WINDOW and SNAPSHOT using NATIVE-P carets.

The immutable SNAPSHOT identity is also the presentation generation.  Thus
an unchanged cursor generation causes no overlay churn during redisplay."
  (unless (and (eq snapshot multi-cursor--presentation-snapshot)
               (eq window multi-cursor--presentation-window)
               (eq native-p multi-cursor--presentation-native-p))
    (let ((regions (multi-cursor--presentation-table
                    multi-cursor--region-overlays))
          (carets (multi-cursor--presentation-table
                   multi-cursor--caret-overlays))
          new-regions new-carets)
      (when snapshot
        (let ((index 2))
          (while (< index (length snapshot))
            (let ((id (aref snapshot index))
                  (position (aref snapshot (1+ index)))
                  (mark (aref snapshot (+ index 2)))
                  (active (aref snapshot (+ index 3))))
              (when (and active mark)
                (push (multi-cursor--reuse-presentation-overlay
                       id (min position mark) (max position mark)
                       window 'multi-cursor-region-face regions)
                      new-regions))
              (unless native-p
                (pcase-let ((`(,beg . ,end)
                             (multi-cursor--caret-overlay-bounds position)))
                  (push (multi-cursor--reuse-presentation-overlay
                         id beg end window 'multi-cursor-caret-face carets)
                        new-carets))))
            (setq index (+ index 5)))))
      (maphash (lambda (_id overlay) (delete-overlay overlay)) regions)
      (maphash (lambda (_id overlay) (delete-overlay overlay)) carets)
      (setq multi-cursor--region-overlays (nreverse new-regions)
            multi-cursor--caret-overlays (nreverse new-carets)))
    (setq multi-cursor--presentation-snapshot snapshot
          multi-cursor--presentation-window window
          multi-cursor--presentation-native-p native-p)))

(defun multi-cursor--publish-redisplay-snapshot (window)
  "Publish an immutable secondary-cursor snapshot for selected WINDOW.

The flat vector contains the buffer and its character-change tick followed
by records of ID, point, mark, active state, and direction.  Native-capable
backends receive the snapshot for caret geometry; other terminals receive
nil and use the Lisp face-overlay caret fallback."
  (when (eq window (selected-window))
    (when (and (window-live-p multi-cursor--redisplay-window)
               (not (eq multi-cursor--redisplay-window window)))
      (let ((old-buffer (window-buffer multi-cursor--redisplay-window)))
        (when (buffer-live-p old-buffer)
          (with-current-buffer old-buffer
            (multi-cursor--clear-presentation))))
      (multi-cursor--set-redisplay-snapshot
       multi-cursor--redisplay-window nil))
    (setq multi-cursor--redisplay-window window)
    (let ((tick (buffer-chars-modified-tick))
          (native-p (multi-cursor--native-cursor-decorations-p window)))
      (when (or multi-cursor--redisplay-snapshot-dirty-p
                (not (equal tick multi-cursor--redisplay-snapshot-tick)))
        (setq multi-cursor--redisplay-snapshot
              (when (and multi-cursor-mode multi-cursor--cursors)
                (vconcat
                 (list (current-buffer) tick)
                 (mapcan
                  (lambda (cursor)
                    (list
                     (multi-cursor--cursor-id cursor)
                     (marker-position (multi-cursor--cursor-point cursor))
                     (and (multi-cursor--cursor-mark cursor)
                          (marker-position
                           (multi-cursor--cursor-mark cursor)))
                     (and (multi-cursor--cursor-mark-active cursor) t)
                     (multi-cursor--cursor-direction cursor)))
                  (multi-cursor--sorted-cursors))))
              multi-cursor--redisplay-snapshot-tick tick
              multi-cursor--redisplay-snapshot-dirty-p nil))
      (multi-cursor--set-redisplay-snapshot
       window (and native-p multi-cursor--redisplay-snapshot))
      (multi-cursor--sync-presentation
       window multi-cursor--redisplay-snapshot native-p))))

(defun multi-cursor--mark-redisplay-snapshot-dirty (&rest _ignored)
  "Mark the current buffer's published cursor positions stale."
  (setq multi-cursor--redisplay-snapshot-dirty-p t))

(add-hook 'pre-redisplay-functions
          #'multi-cursor--publish-redisplay-snapshot)

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
    (setq multi-cursor--redisplay-snapshot-dirty-p t)
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

Signal `user-error' if POSITION is the ordinary primary point.  Calling this
without POSITION therefore always fails, so it is a Lisp entry point rather
than a command; `multi-cursor-add-above' and `multi-cursor-add-below' are the
interactive way to add a cursor relative to point."
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
  "Return the cursor count, including the ordinary primary cursor.

Called interactively, also report the count in the echo area."
  (interactive)
  (let ((count (1+ (length multi-cursor--cursors))))
    (when (called-interactively-p 'interactive)
      (message "%d cursor%s" count (if (= count 1) "" "s")))
    count))

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
  (setq multi-cursor--redisplay-snapshot-dirty-p t)
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

(defun multi-cursor--snapshot-edit-states ()
  "Return detached edit snapshots for the primary and secondary cursors."
  (cons
   (multi-cursor--edit-state-create
    :id 0 :primary t :point (point) :mark (mark t)
    :active (and mark-active t) :goal-column temporary-goal-column)
   (mapcar
    (lambda (cursor)
      (multi-cursor--edit-state-create
       :cursor cursor :id (multi-cursor--cursor-id cursor)
       :point (marker-position (multi-cursor--cursor-point cursor))
       :mark (and (multi-cursor--cursor-mark cursor)
                  (marker-position (multi-cursor--cursor-mark cursor)))
       :active (and (multi-cursor--cursor-mark-active cursor) t)
       :direction (multi-cursor--cursor-direction cursor)
       :goal-column (multi-cursor--cursor-goal-column cursor)
       :last-yank
       (multi-cursor--copy-session-value
        (multi-cursor--cursor-last-yank cursor))))
    (multi-cursor--normalized-cursors))))

(defun multi-cursor--restore-edit-states (states cursors next-id)
  "Restore cursor STATES, secondary CURSORS, and NEXT-ID."
  (let ((primary (car states)))
    (goto-char (multi-cursor--edit-state-point primary))
    (set-marker (mark-marker) (multi-cursor--edit-state-mark primary)
                (and (multi-cursor--edit-state-mark primary) (current-buffer)))
    (setq mark-active (multi-cursor--edit-state-active primary)
          temporary-goal-column
          (multi-cursor--edit-state-goal-column primary)))
  (dolist (cursor multi-cursor--cursors)
    (unless (memq cursor cursors)
      (multi-cursor--release-cursor cursor)))
  (setq multi-cursor--cursors cursors
        multi-cursor--next-id next-id)
  (dolist (state (cdr states))
    (let ((cursor (multi-cursor--edit-state-cursor state)))
      (multi-cursor--set-record-state
       cursor (multi-cursor--edit-state-point state)
       (multi-cursor--edit-state-mark state)
       (multi-cursor--edit-state-active state)
       (multi-cursor--edit-state-goal-column state))
      (setf (multi-cursor--cursor-direction cursor)
            (multi-cursor--edit-state-direction state)
            (multi-cursor--cursor-last-yank cursor)
            (multi-cursor--edit-state-last-yank state)))))

(defun multi-cursor--same-cursor-objects-p (cursors next-id)
  "Return non-nil when the current session owns CURSORS and NEXT-ID.

This deliberately compares object identity rather than cursor positions.  A
normal movement between an edit and undo is harmless: undo still restores the
recorded generation.  Adding, removing, or replacing a cursor, however,
makes the generation unsafe to replay."
  (and (= multi-cursor--next-id next-id)
       (= (length multi-cursor--cursors) (length cursors))
       (cl-every #'eq multi-cursor--cursors cursors)))

(defun multi-cursor--undo-list-head (undo-list)
  "Return UNDO-LIST after harmless leading ordinary undo boundaries."
  (while (and (consp undo-list) (null (car undo-list)))
    (setq undo-list (cdr undo-list)))
  undo-list)

(defun multi-cursor--generation-current-p (generation side)
  "Return non-nil when GENERATION's SIDE is safe to replay.

SIDE is `before' or `after'.  The character-change tick, restriction, cursor
ownership, and undo-list head together prevent a session undo from consuming
ordinary edits or history that did not originate in this session."
  (let ((before-p (eq side 'before)))
    (and (= (buffer-chars-modified-tick)
            (if before-p
                (multi-cursor--undo-generation-before-tick generation)
              (multi-cursor--undo-generation-after-tick generation)))
         (equal (cons (point-min) (point-max))
                (if before-p
                    (multi-cursor--undo-generation-before-restriction
                     generation)
                  (multi-cursor--undo-generation-after-restriction
                   generation)))
         (eq (multi-cursor--undo-list-head buffer-undo-list)
             (multi-cursor--undo-list-head
              (if before-p
                  (multi-cursor--undo-generation-before-undo-list generation)
                (multi-cursor--undo-generation-after-undo-list generation))))
         (multi-cursor--same-cursor-objects-p
          (if before-p
              (multi-cursor--undo-generation-before-cursors generation)
            (multi-cursor--undo-generation-after-cursors generation))
          (if before-p
              (multi-cursor--undo-generation-before-next-id generation)
            (multi-cursor--undo-generation-after-next-id generation))))))

(defun multi-cursor--record-undo-generation
    (states cursors next-id restriction before-tick)
  "Record a completed text transaction for active-session undo.

STATES, CURSORS, NEXT-ID, RESTRICTION, and BEFORE-TICK describe the state
before the transaction.  This function is called only after the transaction's
change group has been accepted.  A transaction which made no text change has
no ordinary undo generation and is intentionally not recorded."
  (let ((after-tick (buffer-chars-modified-tick)))
    (when (/= before-tick after-tick)
      (push
       (multi-cursor--undo-generation-create
        :before-states states
        :before-cursors cursors
        :before-next-id next-id
        :before-restriction restriction
        :before-tick before-tick
        :before-undo-list nil
        :after-states (multi-cursor--snapshot-edit-states)
        :after-cursors (copy-sequence multi-cursor--cursors)
        :after-next-id multi-cursor--next-id
        :after-restriction (cons (point-min) (point-max))
        :after-tick after-tick
        :after-undo-list buffer-undo-list)
       multi-cursor--undo-generations)
      ;; A new ordinary edit makes every previous redo branch invalid.
      (setq multi-cursor--redo-generations nil))))

(defun multi-cursor--refresh-generation-side (generation side)
  "Refresh GENERATION's SIDE anchors from the current ordinary undo state."
  (if (eq side 'before)
      (setf (multi-cursor--undo-generation-before-tick generation)
            (buffer-chars-modified-tick)
            (multi-cursor--undo-generation-before-undo-list generation)
            buffer-undo-list)
    (setf (multi-cursor--undo-generation-after-tick generation)
          (buffer-chars-modified-tick)
          (multi-cursor--undo-generation-after-undo-list generation)
          buffer-undo-list)))

(defun multi-cursor--restore-generation-side (generation side)
  "Restore GENERATION's cursor snapshot for SIDE after ordinary undo work."
  (if (eq side 'before)
      (multi-cursor--restore-edit-states
       (multi-cursor--undo-generation-before-states generation)
       (multi-cursor--undo-generation-before-cursors generation)
       (multi-cursor--undo-generation-before-next-id generation))
    (multi-cursor--restore-edit-states
     (multi-cursor--undo-generation-after-states generation)
     (multi-cursor--undo-generation-after-cursors generation)
     (multi-cursor--undo-generation-after-next-id generation))))

(defun multi-cursor--generation-replay-safe-p (generation side)
  "Signal `user-error' unless GENERATION's SIDE is the current session state."
  (unless (multi-cursor--generation-current-p generation side)
    (user-error
     "Multiple-cursor undo history is stale after text, narrowing, or cursor changes")))

(defun multi-cursor--run-ordinary-session-history-command (redo-p)
  "Run one ordinary session undo or redo, selected by REDO-P.

The `undo' command is deliberately dispatched through `undo-only' here.
Within a multiple-cursor session, the command must always travel toward the
older session generation rather than opportunistically toggling into redo.
Leading undo boundaries are ordinary command-loop bookkeeping and are handled
  by `multi-cursor--generation-current-p'."
  (let ((mark-active nil)
        (last-command
         (if (and (not redo-p) multi-cursor--redo-generations)
             'undo
           last-command)))
    (funcall (if redo-p #'undo-redo #'undo-only) 1)
    ;; Ordinary undo records its inverse edits without a boundary.  Keep each
    ;; session generation distinct for a later `undo-redo'.
    (unless redo-p
      (undo-boundary))))

(defun multi-cursor--session-undo
    (command prefix _keys _record-flag _special)
  "Run session-owned COMMAND undo or redo without cursor-state drift.

PREFIX accepts only one generation, because each invocation must first let
the ordinary undo machinery apply precisely one recorded transaction."
  (unless (memq command '(undo undo-only undo-redo))
    (error "Invalid multiple-cursor undo command: %S" command))
  (unless (or (null prefix) (equal prefix 1))
    (user-error "Multiple-cursor undo accepts one generation at a time"))
  (let* ((redo-p (eq command 'undo-redo))
         (stack (if redo-p multi-cursor--redo-generations
                  multi-cursor--undo-generations))
         (generation (car stack))
         (from-side (if redo-p 'before 'after))
         (to-side (if redo-p 'after 'before)))
    (unless generation
      (user-error "No session-owned multiple-cursor %s history"
                  (if redo-p "redo" "undo")))
    (multi-cursor--generation-replay-safe-p generation from-side)
    ;; Yank-pop targets are not part of the ordinary undo generation record.
    ;; Drop their live markers before replay rather than leave stale state.
    (multi-cursor--discard-yank-pop-state)
    ;; Do not let an active primary region turn this into ordinary
    ;; undo-in-region: a session generation must always be all-or-nothing.
    (let (ordinary-completed completed)
      (unwind-protect
          (progn
            ;; The standard command remains the authority for text and undo
            ;; bookkeeping.  Cursor records are restored only after it wins.
            ;; `command-execute' is also used directly by tests and Lisp
            ;; callers, where it does not advance `last-command'.
            (multi-cursor--run-ordinary-session-history-command redo-p)
            (setq ordinary-completed t)
            (unless (equal (cons (point-min) (point-max))
                           (if (eq to-side 'before)
                               (multi-cursor--undo-generation-before-restriction
                                generation)
                             (multi-cursor--undo-generation-after-restriction
                              generation)))
              (error "Ordinary undo changed the buffer restriction"))
            (unless
                (multi-cursor--same-cursor-objects-p
                 (if (eq from-side 'before)
                     (multi-cursor--undo-generation-before-cursors generation)
                   (multi-cursor--undo-generation-after-cursors generation))
                 (if (eq from-side 'before)
                     (multi-cursor--undo-generation-before-next-id generation)
                   (multi-cursor--undo-generation-after-next-id generation)))
              (error "Ordinary undo changed the cursor session"))
            (multi-cursor--restore-generation-side generation to-side)
            (multi-cursor--refresh-generation-side generation to-side)
            (if redo-p
                (progn
                  (setq multi-cursor--redo-generations (cdr stack))
                  (push generation multi-cursor--undo-generations)
                  ;; The next redo starts where this one ended.
                  (when multi-cursor--redo-generations
                    (multi-cursor--refresh-generation-side
                     (car multi-cursor--redo-generations) 'before)))
              (setq multi-cursor--undo-generations (cdr stack))
              (push generation multi-cursor--redo-generations)
              ;; The next undo starts where this one ended.
              (when multi-cursor--undo-generations
                (multi-cursor--refresh-generation-side
                 (car multi-cursor--undo-generations) 'after)))
            (setq completed t))
        ;; If an unexpected post-undo check fails, reverse the ordinary text
        ;; operation before leaving the generation stacks untouched.  Thus a
        ;; failure cannot strand changed text beside stale session history.
        (unless completed
          (when ordinary-completed
            (condition-case rollback-error
                (progn
                  (multi-cursor--run-ordinary-session-history-command
                   (not redo-p))
                  (multi-cursor--restore-generation-side generation from-side)
                  (multi-cursor--refresh-generation-side generation from-side))
              (error
               (error "Multiple-cursor undo rollback failed: %S"
                      rollback-error))))
          (setq multi-cursor--redisplay-snapshot-dirty-p t))))))

(defun multi-cursor--detach-edit-markers (states)
  "Detach the markers represented by edit STATES before changing text."
  (set-marker (mark-marker) nil)
  (setq mark-active nil)
  (dolist (state (cdr states))
    (multi-cursor--release-cursor (multi-cursor--edit-state-cursor state))))

(defun multi-cursor--step-delete-chars (position count)
  "Return the position COUNT characters from POSITION for raw deletion.

Deleting outwards at an exact accessible boundary is a per-cursor no-op.
Otherwise an overshooting count rejects the entire batch."
  (let ((target (+ position count)))
    (cond
     ((and (> count 0) (= position (point-max))) position)
     ((and (< count 0) (= position (point-min))) position)
     ((> target (point-max)) (signal 'end-of-buffer nil))
     ((< target (point-min)) (signal 'beginning-of-buffer nil))
     (t target))))

(defun multi-cursor--step-delete-forward-graphemes (position count)
  "Return the position COUNT grapheme clusters after POSITION.

An exact accessible end is a per-cursor no-op.  Overshooting the accessible
end rejects the entire batch.  This follows `delete-forward-char' without
executing that editing command separately for every cursor."
  (if (= position (point-max))
      position
    (let ((pos position))
      (while (> count 0)
        (when (>= pos (point-max))
          (signal 'end-of-buffer nil))
        (let ((composition (find-composition pos)))
          (setq pos
                (if composition
                    (let ((from (car composition))
                          (to (cadr composition)))
                      (cond
                       ((and (= (length composition) 3)
                             (booleanp (nth 2 composition)))
                        to)
                       ((<= to pos) (1+ pos))
                       (t
                        (lgstring-glyph-boundary
                         (nth 2 composition) from (1+ pos)))))
                  (1+ pos))))
        (setq count (1- count)))
      (when (> pos (point-max))
        (signal 'end-of-buffer nil))
      pos)))

(defun multi-cursor--read-only-value-blocks-p (value)
  "Return non-nil when read-only VALUE is not inhibited."
  (and value
       (not (eq inhibit-read-only t))
       (not (and (listp inhibit-read-only)
                 (memq value inhibit-read-only)))))

(defun multi-cursor--preflight-edit-range (beg end origin target)
  "Reject an inaccessible, cross-field, or read-only BEG..END.

ORIGIN and TARGET retain the direction of the edit for field checks."
  (unless (<= (point-min) beg end (point-max))
    (user-error "Multiple-cursor edit is outside the accessible buffer"))
  (unless (= target (constrain-to-field target origin nil nil nil))
    (user-error "Multiple-cursor edit crosses a field boundary"))
  (barf-if-buffer-read-only)
  (let ((position beg)
        blocked)
    ;; `get-char-property' includes overlays.  The primitive remains the
    ;; authority for boundary stickiness and races with modification hooks.
    (while (and (not blocked) (< position end))
      (when (and (= (% position 128) 0) quit-flag)
        (signal 'quit nil))
      (setq blocked
            (multi-cursor--read-only-value-blocks-p
             (get-char-property position 'read-only))
            position (1+ position)))
    (when blocked
      (signal 'text-read-only (list blocked)))))

(defun multi-cursor--edit-survivor-less-p (left right)
  "Return non-nil when edit state LEFT should survive before RIGHT."
  (or (multi-cursor--edit-state-primary left)
      (and (not (multi-cursor--edit-state-primary right))
           (< (multi-cursor--edit-state-id left)
              (multi-cursor--edit-state-id right)))))

(defun multi-cursor--merge-edits (edits &optional replacement-safe-p)
  "Merge compatible touching or overlapping EDITS in buffer order.

By default, preserve the established batch-edit behavior of coalescing all
touching ranges.  When REPLACEMENT-SAFE-P is non-nil, touching empty deletions
merge, touching edits with replacements remain separate, and incompatible
strict replacement overlaps are rejected before the transaction starts."
  (let (result)
    (dolist (edit (sort edits
                        (lambda (left right)
                          (if (/= (multi-cursor--edit-beg left)
                                  (multi-cursor--edit-beg right))
                              (< (multi-cursor--edit-beg left)
                                 (multi-cursor--edit-beg right))
                            (< (multi-cursor--edit-state-id
                                (multi-cursor--edit-survivor left))
                               (multi-cursor--edit-state-id
                                (multi-cursor--edit-survivor right)))))))
      (let ((previous (car result)))
        (cond
         ((null previous) (push edit result))
         ((> (multi-cursor--edit-beg edit)
             (multi-cursor--edit-end previous))
          (push edit result))
         ((not replacement-safe-p)
          (setf (multi-cursor--edit-end previous)
                (max (multi-cursor--edit-end previous)
                     (multi-cursor--edit-end edit)))
          (when (multi-cursor--edit-survivor-less-p
                 (multi-cursor--edit-survivor edit)
                 (multi-cursor--edit-survivor previous))
            (setf (multi-cursor--edit-survivor previous)
                  (multi-cursor--edit-survivor edit))))
         ((and (= (multi-cursor--edit-beg edit)
                  (multi-cursor--edit-end previous))
               (or (> (length (multi-cursor--edit-string previous)) 0)
                   (> (length (multi-cursor--edit-string edit)) 0)))
          (push edit result))
         ((or (and (zerop (length (multi-cursor--edit-string previous)))
                   (zerop (length (multi-cursor--edit-string edit))))
              (and (= (multi-cursor--edit-beg previous)
                      (multi-cursor--edit-beg edit))
                   (= (multi-cursor--edit-end previous)
                      (multi-cursor--edit-end edit))
                   (equal (multi-cursor--edit-string previous)
                          (multi-cursor--edit-string edit))))
          (setf (multi-cursor--edit-end previous)
                (max (multi-cursor--edit-end previous)
                     (multi-cursor--edit-end edit)))
          (when (multi-cursor--edit-survivor-less-p
                 (multi-cursor--edit-survivor edit)
                 (multi-cursor--edit-survivor previous))
            (setf (multi-cursor--edit-survivor previous)
                  (multi-cursor--edit-survivor edit))))
         (t
          (user-error
           "Overlapping multiple-cursor replacements are incompatible")))))
    (nreverse result)))

(defun multi-cursor--state-edit
    (state command argument insertion &optional delete-policy)
  "Return the raw edit for STATE under COMMAND and ARGUMENT.

INSERTION is the string used by `self-insert-command'.  DELETE-POLICY is
the captured value of the variable `delete-active-region'."
  (let* ((point (multi-cursor--edit-state-point state))
         (mark (multi-cursor--edit-state-mark state))
         (active (and (multi-cursor--edit-state-active state)
                      mark (/= point mark)))
         (replace-selection
          (and active
               (or (memq command '(self-insert-command yank delete-char))
                   (and delete-policy
                        (memq command '(delete-backward-char
                                        delete-forward-char))))))
         beg end replacement)
    (if replace-selection
        (setq beg (min point mark)
              end (max point mark)
              replacement (if (memq command '(self-insert-command yank))
                              insertion ""))
      (pcase command
        ((or 'self-insert-command 'yank)
         (setq beg point end point replacement insertion))
        ('delete-char
         (let ((target (multi-cursor--step-delete-chars point argument)))
           (setq beg (min point target) end (max point target)
                 replacement "")))
        ('delete-backward-char
         (let ((target (multi-cursor--step-delete-chars point (- argument))))
           (setq beg (min point target) end (max point target)
                 replacement "")))
        ('delete-forward-char
         (let ((target
                (if (> argument 0)
                    (multi-cursor--step-delete-forward-graphemes
                     point argument)
                  (multi-cursor--step-delete-chars point argument))))
           (setq beg (min point target) end (max point target)
                 replacement "")))))
    (multi-cursor--preflight-edit-range beg end point
                                        (if (= point beg) end beg))
    (multi-cursor--edit-create
     :beg beg :end end :string replacement :survivor state
     :members (list state))))

(defun multi-cursor--untabify-state-edit (state method delete-policy)
  "Plan backward untabifying deletion for STATE using METHOD.

DELETE-POLICY is the captured value of the variable
`delete-active-region'."
  (let* ((point (multi-cursor--edit-state-point state))
         (mark (multi-cursor--edit-state-mark state))
         (active (and (multi-cursor--edit-state-active state)
                      mark (/= point mark))))
    (if (and active delete-policy)
        (multi-cursor--state-edit
         state 'delete-backward-char 1 nil delete-policy)
      (let (target replacement)
        (pcase method
          ('untabify
           (if (or (= point (point-min))
                   (/= (char-before point) ?\t))
               (setq target
                     (multi-cursor--step-delete-chars point -1)
                     replacement "")
             (let (column previous-column)
               (save-excursion
                 (goto-char point)
                 (setq column (current-column))
                 (forward-char -1)
                 (setq previous-column (current-column)))
               (setq target (1- point)
                     replacement
                     (make-string (1- (- column previous-column)) ?\s)))))
          ((or 'hungry 'all)
           (let ((characters (if (eq method 'hungry) " \t" " \t\n\r")))
             (save-excursion
               (goto-char point)
               (skip-chars-backward characters)
               (setq target (constrain-to-field nil point)))
             (when (= target point)
               (setq target
                     (multi-cursor--step-delete-chars point -1)))
             (setq replacement "")))
          ('nil
           (setq target (multi-cursor--step-delete-chars point -1)
                 replacement ""))
          (_
           (user-error
            "Unsupported backward-delete-char-untabify method: %S"
            method)))
        (let ((beg (min point target))
              (end (max point target)))
          (multi-cursor--preflight-edit-range beg end point target)
          (multi-cursor--edit-create
           :beg beg :end end :string replacement :survivor state
           :members (list state)))))))

(defun multi-cursor--partition-passive-replacement-edits (edits)
  "Partition EDITS into primitive edits and passive no-op states.

A zero-length empty edit is passive only when a nonempty replacement starts
at the same position.  Return (PRIMITIVE-EDITS . PASSIVE-STATES), preserving
the original order of both lists."
  (let (primitive passive)
    (dolist (edit edits)
      (if (and (= (multi-cursor--edit-beg edit)
                  (multi-cursor--edit-end edit))
               (zerop (length (multi-cursor--edit-string edit)))
               (cl-some
                (lambda (other)
                  (and (= (multi-cursor--edit-beg other)
                          (multi-cursor--edit-beg edit))
                       (> (length (multi-cursor--edit-string other)) 0)))
                edits))
          (push (multi-cursor--edit-survivor edit) passive)
        (push edit primitive)))
    (cons (nreverse primitive) (nreverse passive))))

(defun multi-cursor--remap-edit-position
    (position groups positions &optional replacement-to-beg)
  "Remap detached marker POSITION through GROUPS and POSITIONS.

GROUPS is an ascending vector of disjoint edits and POSITIONS is the
parallel vector of their final ends.  When REPLACEMENT-TO-BEG is non-nil,
map positions inside a replaced range to its final beginning."
  (let ((low 0)
        (high (length groups)))
    ;; Find the first edit whose original end is at or after POSITION.
    (while (< low high)
      (let ((middle (/ (+ low high) 2)))
        (if (< (multi-cursor--edit-end (aref groups middle)) position)
            (setq low (1+ middle))
          (setq high middle))))
    (if (= low (length groups))
        (if (= low 0)
            position
          (+ position (- (aref positions (1- low))
                         (multi-cursor--edit-end
                          (aref groups (1- low))))))
      (let* ((group (aref groups low))
             (beg (multi-cursor--edit-beg group))
             (end (multi-cursor--edit-end group))
             (final-end (aref positions low))
             (final-beg (- final-end
                           (length (multi-cursor--edit-string group)))))
        (cond
         ((< position beg) (+ position (- final-beg beg)))
         ((= position beg) final-beg)
         ((<= position end) (if replacement-to-beg final-beg final-end))
         (t (error "Invalid multiple-cursor edit transform")))))))

(defun multi-cursor--install-edit-results
    (groups positions states &optional passive-states mark-remapper)
  "Install POSITIONS for merged edit GROUPS, releasing losing STATES.

PASSIVE-STATES are no-op cursors omitted from GROUPS.  Remap and retain them
without sending their empty edits to the batch primitive.  MARK-REMAPPER,
when non-nil, remaps detached marks instead of the standard transform."
  (let ((group-vector (vconcat groups))
        (remap-mark
         (or mark-remapper #'multi-cursor--remap-edit-position))
        survivors)
    (cl-mapc
     (lambda (group position)
       (let ((survivor (multi-cursor--edit-survivor group)))
         (if (multi-cursor--edit-state-primary survivor)
             (progn
               (goto-char position)
               (set-marker
                (mark-marker)
                (and (multi-cursor--edit-state-mark survivor)
                     (funcall
                      remap-mark
                      (multi-cursor--edit-state-mark survivor)
                      group-vector positions))
                (and (multi-cursor--edit-state-mark survivor)
                     (current-buffer)))
               (setq mark-active nil temporary-goal-column nil))
           (let ((cursor (multi-cursor--edit-state-cursor survivor)))
             (multi-cursor--set-record-state
              cursor position
              (and (multi-cursor--edit-state-mark survivor)
                   (funcall
                    remap-mark
                    (multi-cursor--edit-state-mark survivor)
                    group-vector positions))
             nil nil)
             (push cursor survivors)))))
     groups (append positions nil))
    (dolist (state passive-states)
      (let ((point
             (multi-cursor--remap-edit-position
              (multi-cursor--edit-state-point state)
              group-vector positions))
            (mark
             (and (multi-cursor--edit-state-mark state)
                  (funcall
                   remap-mark
                   (multi-cursor--edit-state-mark state)
                   group-vector positions))))
        (if (multi-cursor--edit-state-primary state)
            (progn
              (goto-char point)
              (set-marker (mark-marker) mark
                          (and mark (current-buffer)))
              (setq mark-active nil temporary-goal-column nil))
          (let ((cursor (multi-cursor--edit-state-cursor state)))
            (multi-cursor--set-record-state cursor point mark nil nil)
            (push cursor survivors)))))
    (dolist (state (cdr states))
      (unless (memq (multi-cursor--edit-state-cursor state) survivors)
        (multi-cursor--release-cursor
         (multi-cursor--edit-state-cursor state))))
    (setq multi-cursor--cursors (nreverse survivors))
    (multi-cursor--normalize)))

(defun multi-cursor--apply-edit-transaction
    (states groups &optional installer)
  "Apply disjoint edit GROUPS atomically for cursor STATES.

INSTALLER receives GROUPS, final positions, and STATES after the buffer edits.
It defaults to `multi-cursor--install-edit-results'.  Return the final position
vector."
  (let* ((original-cursors (copy-sequence multi-cursor--cursors))
         (original-next-id multi-cursor--next-id)
         (buffer (current-buffer))
         (restriction (cons (point-min) (point-max)))
         (before-tick (buffer-chars-modified-tick))
         (vector
          (vconcat
           (mapcar (lambda (edit)
                     (vector (multi-cursor--edit-beg edit)
                             (multi-cursor--edit-end edit)
                             (multi-cursor--edit-string edit)))
                   groups)))
         positions completed)
    (multi-cursor--detach-edit-markers states)
    (progn
      (unwind-protect
          (progn
            (let ((change-group (prepare-change-group))
                  (undo-outer-limit nil)
                  (undo-limit most-positive-fixnum)
                  (undo-strong-limit most-positive-fixnum)
                  group-completed)
              (unwind-protect
                  (progn
                    (activate-change-group change-group)
                    (setq positions (multi-cursor--apply-edits vector))
                    (unless (eq (current-buffer) buffer)
                      (error
                       "Modification hook changed the current buffer"))
                    (unless
                        (equal
                         (cons
                          (car restriction)
                          (+ (cdr restriction)
                             (cl-loop
                              for group in groups
                              sum (- (length
                                      (multi-cursor--edit-string group))
                                     (- (multi-cursor--edit-end group)
                                        (multi-cursor--edit-beg group))))))
                         (cons (point-min) (point-max)))
                      (error
                       "Modification hook changed the buffer restriction"))
                    (unless
                        (and (equal multi-cursor--cursors original-cursors)
                             (= multi-cursor--next-id original-next-id))
                      (error "Modification hook changed the cursor session"))
                    (funcall
                     (or installer #'multi-cursor--install-edit-results)
                     groups positions states)
                    (setq group-completed t))
                (if group-completed
                    (accept-change-group change-group)
                  (when (buffer-live-p buffer)
                    (let ((inhibit-modification-hooks t))
                      (cancel-change-group change-group))))))
            (setq completed t))
        (unless completed
          (when (buffer-live-p buffer)
            (set-buffer buffer)
            (multi-cursor--restore-edit-states
             states original-cursors original-next-id)))))
    (when (and completed
               (/= before-tick (buffer-chars-modified-tick)))
      ;; `accept-change-group' keeps the transaction atomic but does not add
      ;; a following boundary.  Add the ordinary boundary here so one session
      ;; undo never falls through into edits that predate the session.
      (undo-boundary)
      (multi-cursor--record-undo-generation
       states original-cursors original-next-id restriction before-tick))
    positions))

(defun multi-cursor--kill-ring-state ()
  "Return a restorable snapshot of the ordinary `kill-ring' variables."
  (list kill-ring
        kill-ring-yank-pointer
        (mapcar (lambda (tail)
                  (list tail (car tail) (cdr tail)))
                (let (tails)
                  (cl-loop for tail on kill-ring do (push tail tails))
                  (nreverse tails)))))

(defun multi-cursor--restore-kill-ring-state (state)
  "Restore the ordinary `kill-ring' variables from STATE."
  (dolist (cell-state (nth 2 state))
    (setcar (nth 0 cell-state) (nth 1 cell-state))
    (setcdr (nth 0 cell-state) (nth 2 cell-state)))
  (setq kill-ring (nth 0 state)
        kill-ring-yank-pointer (nth 1 state)))

(defun multi-cursor--selection-edit (state delete-p)
  "Return a selection edit for STATE, preflighting deletion if DELETE-P."
  (let ((point (multi-cursor--edit-state-point state))
        (mark (multi-cursor--edit-state-mark state)))
    (unless (and mark
                 (multi-cursor--edit-state-active state)
                 (/= point mark))
      (user-error "Every cursor needs a nonempty active selection"))
    (let ((beg (min point mark))
          (end (max point mark)))
      (if delete-p
          (multi-cursor--preflight-edit-range beg end point mark)
        (unless (<= (point-min) beg end (point-max))
          (user-error "Multiple-cursor selection is outside the buffer")))
      (multi-cursor--edit-create
       :beg beg :end end :string "" :survivor state :members (list state)))))

(defun multi-cursor--selection-groups-and-text (states delete-p)
  "Return merged selection edit groups and their text for STATES.

The plain clipboard representation concatenates every original selection in
buffer order, including overlapping text.  DELETE-P requests deletion
preflight; the returned edit groups merge overlaps for a single deletion."
  (let* ((edits
          (mapcar (lambda (state)
                    (multi-cursor--selection-edit state delete-p))
                  states))
         (text
          (mapconcat
           (lambda (group)
             (filter-buffer-substring
              (multi-cursor--edit-beg group)
              (multi-cursor--edit-end group)))
           (sort
            (copy-sequence edits)
            (lambda (left right)
              (let ((left-beg (multi-cursor--edit-beg left))
                    (right-beg (multi-cursor--edit-beg right))
                    (left-end (multi-cursor--edit-end left))
                    (right-end (multi-cursor--edit-end right))
                    (left-id
                     (multi-cursor--edit-state-id
                      (multi-cursor--edit-survivor left)))
                    (right-id
                     (multi-cursor--edit-state-id
                      (multi-cursor--edit-survivor right))))
                (or (< left-beg right-beg)
                    (and (= left-beg right-beg)
                         (or (< left-id right-id)
                             (and (= left-id right-id)
                                  (< left-end right-end))))))))
           ""))
         (groups (multi-cursor--merge-edits edits)))
    (cons groups text)))

(defun multi-cursor--original-edit-payload (edits)
  "Return the stable, pre-transaction kill payload for EDITS.

Every original cursor range contributes its filtered text, including a range
which overlaps another cursor's range.  The batch primitive must instead see
the merged ranges, but the kill ring must not depend on which overlapping
cursor happened to survive that merge."
  (mapconcat
   (lambda (edit)
     (or (filter-buffer-substring
          (multi-cursor--edit-beg edit)
          (multi-cursor--edit-end edit))
         ""))
   (sort
    (copy-sequence edits)
    (lambda (left right)
      (let ((left-beg (multi-cursor--edit-beg left))
            (right-beg (multi-cursor--edit-beg right))
            (left-end (multi-cursor--edit-end left))
            (right-end (multi-cursor--edit-end right))
            (left-id
             (multi-cursor--edit-state-id
              (multi-cursor--edit-survivor left)))
            (right-id
             (multi-cursor--edit-state-id
              (multi-cursor--edit-survivor right))))
        (or (< left-beg right-beg)
            (and (= left-beg right-beg)
                 (or (< left-id right-id)
                     (and (= left-id right-id)
                          (< left-end right-end))))))))
   ""))

(defun multi-cursor--word-kill-state-edit (state argument)
  "Return the `forward-word' deletion planned for STATE and ARGUMENT.

The ordinary word movement is evaluated only while planning, with STATE's
point restored afterwards.  This lets every cursor derive its range from the
same original buffer rather than from an earlier cursor's deletion."
  (let* ((point (multi-cursor--edit-state-point state))
         (target
          (save-excursion
            (goto-char point)
            (forward-word argument)
            (point)))
         (beg (min point target))
         (end (max point target)))
    (multi-cursor--preflight-edit-range beg end point target)
    (multi-cursor--edit-create
     :beg beg :end end :string "" :survivor state :members (list state))))

(defun multi-cursor--word-kill
    (command prefix _keys record-flag _special)
  "Kill a snapshotted word range for every native cursor.

COMMAND is `kill-word' or `backward-kill-word'.  All `forward-word' ranges
are planned from the original cursor snapshots, then overlapping deletions
are merged for one native edit transaction.  Kill-ring and clipboard effects
are deferred until that transaction has committed."
  (unless (memq command '(kill-word backward-kill-word))
    (error "Invalid multiple-cursor word kill: %S" command))
  ;; The ordinary `kill-region' calls its filter with DELETE non-nil.
  ;; A custom filter can therefore own deletion as well as transformation;
  ;; extracting it first and deleting later would either diverge or delete
  ;; twice.  Emacs's normal default is `buffer-substring--filter' (rather
  ;; than nil), so admit just that stock implementation and the nil path.
  (unless (memq filter-buffer-substring-function
                '(nil buffer-substring--filter))
    (user-error
     "Custom filter-buffer-substring is not multiple-cursor safe"))
  (let* ((argument (prefix-numeric-value prefix))
         (word-argument
          (if (eq command 'backward-kill-word) (- argument) argument))
         (states (multi-cursor--snapshot-edit-states))
         (original-cursors (copy-sequence multi-cursor--cursors))
         (original-next-id multi-cursor--next-id)
         (ring-state (multi-cursor--kill-ring-state))
         before-p edits groups payload export completed)
    (unwind-protect
        (progn
          ;; `forward-word' may invoke syntax-propertization or mode Lisp.
          ;; Keep its effects inside an abortable change group and refuse any
          ;; callback that changes text, narrowing, or cursor session state.
          (save-current-buffer
            (save-restriction
              (atomic-change-group
                (let ((context (multi-cursor--callback-context)))
                  (setq edits
                        (mapcar
                         (lambda (state)
                           (save-excursion
                             (multi-cursor--word-kill-state-edit
                              state word-argument)))
                         states)
                        payload (multi-cursor--original-edit-payload edits)
                        ;; `kill-region' decides append direction from its
                        ;; actual primary endpoints, not merely the prefix
                        ;; sign.  At an accessible boundary a negative word
                        ;; movement is a zero-length kill and has no backward
                        ;; endpoint to prepend.
                        before-p
                        (< (multi-cursor--edit-beg (car edits))
                           (multi-cursor--edit-state-point (car states))))
                  (multi-cursor--validate-callback-state context)
                  (setq groups (multi-cursor--merge-edits edits))))))
          (multi-cursor--apply-edit-transaction
           states groups
           (lambda (edit-groups positions edit-states)
             ;; A kill transform may run arbitrary Lisp.  Store the payload
             ;; while the central change group can still cancel the text edit;
             ;; postpone the irreversible clipboard callback until afterward.
             (let ((context (multi-cursor--callback-context)))
               (setq export
                     (multi-cursor--store-kill payload before-p))
               (multi-cursor--validate-callback-state context)
               (multi-cursor--install-edit-results
                edit-groups positions edit-states))))
          (setq completed t))
      (unless completed
        (multi-cursor--restore-kill-ring-state ring-state)
        (multi-cursor--restore-edit-states
         states original-cursors original-next-id)
        (unless multi-cursor-mode
          (setq multi-cursor-mode t)
          (multi-cursor--start))))
    ;; This is intentionally `kill-region', matching the ordinary helper
    ;; called by both word-kill commands.  Consecutive word kills therefore
    ;; append to a single kill-ring entry regardless of their key binding.
    (setq this-command 'kill-region
          deactivate-mark t)
    (when record-flag
      (add-to-history 'command-history (list command argument) nil t))
    ;; External effects must happen only after text, cursor, and kill-ring
    ;; state are known to be committed successfully.
    (when (car export)
      (funcall (car export) (cadr export)))
    nil))

(defun multi-cursor--line-kill-state-edit (state)
  "Return the `kill-line' deletion planned for STATE.

The range is derived exactly as ordinary `kill-line' derives it, including
visible-line semantics, `show-trailing-whitespace', and the option
`kill-whole-line'.
Planning runs against the original buffer with STATE's point restored
afterwards, so no cursor sees an earlier cursor's deletion.
A cursor at the accessible end of the buffer signals `end-of-buffer' exactly
as the ordinary command does; because a broadcast edit is atomic, that
rejects the whole command rather than only that cursor."
  (let* ((point (multi-cursor--edit-state-point state))
         (target
          (save-excursion
            (goto-char point)
            (when (eobp)
              (signal 'end-of-buffer nil))
            (let ((end (save-excursion (end-of-visible-line) (point))))
              (if (or (save-excursion
                        ;; Visible trailing whitespace is not "nothing".
                        (unless show-trailing-whitespace
                          (skip-chars-forward " \t" end))
                        (= (point) end))
                      (and kill-whole-line (bolp)))
                  (forward-visible-line 1)
                (goto-char end)))
            (point))))
    (multi-cursor--preflight-edit-range point target point target)
    (multi-cursor--edit-create
     :beg point :end target :string "" :survivor state :members (list state))))

(defun multi-cursor--line-kill
    (command prefix _keys record-flag _special)
  "Kill each cursor's line remainder in one transaction.

COMMAND is `kill-line'.  Every range is planned from the original cursor
snapshots, then overlapping deletions are merged for one native edit
transaction; two cursors on the same line therefore kill that line once
while both contribute their own text to the kill ring.  Kill-ring and
clipboard effects are deferred until the transaction has committed.

PREFIX must be nil: a prefixed `kill-line' counts visible lines and can kill
backward, which needs its own contract.  RECORD-FLAG controls the variable
`command-history'."
  (unless (eq command 'kill-line)
    (error "Invalid multiple-cursor line kill: %S" command))
  (when prefix
    (user-error "Prefixed %S is not multiple-cursor safe" command))
  ;; See `multi-cursor--word-kill': a custom filter can own deletion as well
  ;; as transformation, so admit only the stock implementation and nil.
  (unless (memq filter-buffer-substring-function
                '(nil buffer-substring--filter))
    (user-error
     "Custom filter-buffer-substring is not multiple-cursor safe"))
  (let* ((states (multi-cursor--snapshot-edit-states))
         (original-cursors (copy-sequence multi-cursor--cursors))
         (original-next-id multi-cursor--next-id)
         (ring-state (multi-cursor--kill-ring-state))
         edits groups payload export completed)
    (unwind-protect
        (progn
          (save-current-buffer
            (save-restriction
              (atomic-change-group
                (let ((context (multi-cursor--callback-context)))
                  (setq edits
                        (mapcar
                         (lambda (state)
                           (save-excursion
                             (multi-cursor--line-kill-state-edit state)))
                         states)
                        payload (multi-cursor--original-edit-payload edits))
                  (multi-cursor--validate-callback-state context)
                  (setq groups (multi-cursor--merge-edits edits))))))
          (multi-cursor--apply-edit-transaction
           states groups
           (lambda (edit-groups positions edit-states)
             ;; Store the payload while the change group can still cancel the
             ;; text edit; postpone the irreversible clipboard callback.
             (let ((context (multi-cursor--callback-context)))
               ;; `kill-line' never kills backward without a prefix, so the
               ;; payload always appends after the previous kill.
               (setq export (multi-cursor--store-kill payload nil))
               (multi-cursor--validate-callback-state context)
               (multi-cursor--install-edit-results
                edit-groups positions edit-states))))
          (setq completed t))
      (unless completed
        (multi-cursor--restore-kill-ring-state ring-state)
        (multi-cursor--restore-edit-states
         states original-cursors original-next-id)
        (unless multi-cursor-mode
          (setq multi-cursor-mode t)
          (multi-cursor--start))))
    ;; Ordinary `kill-line' kills through `kill-region', so consecutive kills
    ;; append to one kill-ring entry.  Match that.
    (setq this-command 'kill-region
          deactivate-mark t)
    (when record-flag
      (add-to-history 'command-history (list command nil) nil t))
    ;; External effects only after text, cursor, and kill-ring state commit.
    (when (car export)
      (funcall (car export) (cadr export)))
    nil))

(defun multi-cursor--store-kill (string before-p)
  "Store STRING once, appending before the last kill when BEFORE-P.

Return the external clipboard function and the value it should receive, or
nil when the kill transformation discarded STRING."
  (let ((external interprogram-cut-function)
        exported export-p)
    (let ((interprogram-cut-function
           (lambda (value)
             (setq exported value export-p t)))
          (kill-append-merge-undo nil))
      (if (eq last-command 'kill-region)
          (kill-append string before-p)
        (kill-new string)))
    (and export-p (list external exported))))

(defun multi-cursor--copy-session-value (value)
  "Return a detached structural copy of cursor metadata VALUE."
  (cond
   ((stringp value) (copy-sequence value))
   ((consp value)
    (cons (multi-cursor--copy-session-value (car value))
          (multi-cursor--copy-session-value (cdr value))))
   ((vectorp value)
    (vconcat (mapcar #'multi-cursor--copy-session-value value)))
   (t value)))

(defun multi-cursor--session-fingerprint ()
  "Return an immutable fingerprint of the complete current cursor session."
  (list
   (point) (mark t) (and mark-active t) temporary-goal-column
   multi-cursor--next-id
   (mapcar
    (lambda (cursor)
      (list (multi-cursor--cursor-id cursor)
            (marker-position (multi-cursor--cursor-point cursor))
            (and (multi-cursor--cursor-mark cursor)
                 (marker-position (multi-cursor--cursor-mark cursor)))
            (and (multi-cursor--cursor-mark-active cursor) t)
            (multi-cursor--cursor-direction cursor)
            (multi-cursor--cursor-goal-column cursor)
            (multi-cursor--copy-session-value
             (multi-cursor--cursor-last-yank cursor))))
    multi-cursor--cursors)))

(defun multi-cursor--callback-context ()
  "Return the buffer and immutable state protected across a callback."
  (list (current-buffer)
        (cons (point-min) (point-max))
        (buffer-chars-modified-tick)
        (multi-cursor--session-fingerprint)))

(defun multi-cursor--validate-callback-state (context)
  "Validate session invariants after a callback against CONTEXT."
  (unless (eq (current-buffer) (nth 0 context))
    (error "Multiple-cursor callback changed the current buffer"))
  (unless (equal (nth 1 context) (cons (point-min) (point-max)))
    (error "Multiple-cursor callback changed the buffer restriction"))
  (unless (= (nth 2 context) (buffer-chars-modified-tick))
    (error "Multiple-cursor callback changed buffer text"))
  (unless (equal (nth 3 context) (multi-cursor--session-fingerprint))
    (error "Multiple-cursor callback changed the cursor session")))

(defun multi-cursor--validate-plain-region (primary states cursors next-id)
  "Reject nonlinear region extraction for PRIMARY and protect cursor STATES.

CURSORS and NEXT-ID are restored if the extractor mutates state or signals."
  (let* ((point (multi-cursor--edit-state-point primary))
         (mark (multi-cursor--edit-state-mark primary))
         (expected (and mark (list (cons (min point mark)
                                         (max point mark)))))
         bounds completed)
    (unwind-protect
        (save-current-buffer
          (atomic-change-group
            (let ((context (multi-cursor--callback-context)))
              (setq bounds (funcall region-extract-function 'bounds))
              (multi-cursor--validate-callback-state context)
              (setq completed t))))
      (unless completed
        (multi-cursor--restore-edit-states states cursors next-id)))
    (unless (and expected (equal bounds expected))
      (user-error "Nonlinear regions are not multiple-cursor safe yet"))))

(defun multi-cursor--kill-or-copy
    (command _prefix _keys record-flag _special)
  "Apply multi-selection kill or copy COMMAND as one logical operation.

RECORD-FLAG non-nil records that single command invocation."
  (unless (memq command '(kill-region copy-region-as-kill kill-ring-save))
    (error "Invalid multiple-cursor kill command: %S" command))
  (let* ((states (multi-cursor--snapshot-edit-states))
         (original-cursors (copy-sequence multi-cursor--cursors))
         (original-next-id multi-cursor--next-id)
         (_ (multi-cursor--validate-plain-region
             (car states) states original-cursors original-next-id))
         (groups-and-text
          (multi-cursor--selection-groups-and-text
           states (eq command 'kill-region)))
         (groups (car groups-and-text))
         (text (cdr groups-and-text))
         (primary (car states))
         (before-p (< (multi-cursor--edit-state-point primary)
                      (multi-cursor--edit-state-mark primary)))
         (ring-state (multi-cursor--kill-ring-state))
         export completed)
    (unwind-protect
        (progn
          (if (eq command 'kill-region)
              (multi-cursor--apply-edit-transaction
               states groups
               (lambda (edits positions edit-states)
                 (let ((context (multi-cursor--callback-context)))
                   (setq export (multi-cursor--store-kill text before-p))
                   (multi-cursor--validate-callback-state context)
                   (multi-cursor--install-edit-results
                    edits positions edit-states))))
            (let ((context (multi-cursor--callback-context)))
              (save-current-buffer
                (atomic-change-group
                  (setq export (multi-cursor--store-kill text before-p))
                  (multi-cursor--validate-callback-state context)))
              (dolist (cursor multi-cursor--cursors)
                (setf (multi-cursor--cursor-mark-active cursor) nil))
              (deactivate-mark t)
              (setq multi-cursor--redisplay-snapshot-dirty-p t)))
          (setq completed t))
      (unless completed
        (multi-cursor--restore-kill-ring-state ring-state)
        (when (not (eq command 'kill-region))
          (multi-cursor--restore-edit-states
           states original-cursors original-next-id))))
    (when (eq command 'kill-region)
      (setq this-command 'kill-region))
    (setq deactivate-mark t)
    (when record-flag
      (add-to-history
       'command-history
       (list command
             (multi-cursor--edit-state-mark primary)
             (multi-cursor--edit-state-point primary)
             '(quote region))
       nil t))
    ;; Clipboard callbacks run last.  Their external effects cannot be
    ;; compensated if they signal after changing another application.
    (when (car export)
      (funcall (car export) (cadr export)))
    nil))

(defun multi-cursor--prepare-yank-string (string)
  "Return plain broadcast-yank STRING prepared for insertion.

Arbitrary yank handlers are deferred because they can insert different text,
move point, or install command-specific undo functions at each cursor."
  (unless (stringp string)
    (error "Kill-ring entry is not a string"))
  (dolist (function yank-transform-functions)
    (let ((context (multi-cursor--callback-context)))
      (setq string (funcall function string))
      (multi-cursor--validate-callback-state context)))
  (unless (stringp string)
    (error "Yank transform did not return a string"))
  (when (text-property-not-all 0 (length string) 'yank-handler nil string)
    (user-error "Yank handlers are not multiple-cursor safe yet"))
  (copy-sequence string))

(defun multi-cursor--process-yank-spans (groups positions)
  "Apply ordinary yank property handling to GROUPS at final POSITIONS."
  (cl-mapc
   (lambda (group final-end)
     (let ((final-beg (- final-end
                         (length (multi-cursor--edit-string group)))))
       (when (< final-beg final-end)
         ;; Run arbitrary handlers outside `with-silent-modifications' so
         ;; character changes they attempt remain part of the change group
         ;; and can be rolled back.
         (dolist (handler yank-handled-properties)
           (let ((property (car handler))
                 (function (cdr handler))
                 (run-start final-beg))
             (while (< run-start final-end)
               (let ((value (get-text-property run-start property))
                     (run-end (next-single-property-change
                               run-start property nil final-end)))
                 (let ((context (multi-cursor--callback-context)))
                   (funcall function value run-start run-end)
                   (multi-cursor--validate-callback-state context))
                 (setq run-start run-end)))))
         (with-silent-modifications
           (if (eq yank-excluded-properties t)
               (set-text-properties final-beg final-end nil)
             (remove-list-of-text-properties
              final-beg final-end yank-excluded-properties))
           (when (text-properties-at (1- final-end))
             (put-text-property
              (1- final-end) final-end 'rear-nonsticky t))))))
   groups (append positions nil)))

(defun multi-cursor--install-yank-results
    (groups positions states before-p)
  "Install yank GROUPS at POSITIONS for STATES, honoring BEFORE-P."
  (multi-cursor--install-edit-results groups positions states)
  (cl-mapc
   (lambda (group final-end)
     (let* ((state (multi-cursor--edit-survivor group))
            (final-beg (- final-end
                          (length (multi-cursor--edit-string group))))
            (point (if before-p final-beg final-end))
            (mark (if before-p final-end final-beg)))
       (if (multi-cursor--edit-state-primary state)
           (progn
             (goto-char point)
             (set-marker (mark-marker) mark (current-buffer))
             (setq mark-active nil temporary-goal-column nil))
         (let ((cursor (multi-cursor--edit-state-cursor state)))
           (multi-cursor--set-record-state cursor point mark nil nil)))))
   groups (append positions nil)))

(defun multi-cursor--discard-yank-pop-state ()
  "Detach markers and forget the current native `yank-pop' target."
  (when multi-cursor--yank-pop-state
    (dolist (range (multi-cursor--yank-pop-state-ranges
                    multi-cursor--yank-pop-state))
      (set-marker (nth 0 range) nil)
      (set-marker (nth 1 range) nil))
    (setq multi-cursor--yank-pop-state nil)))

(defun multi-cursor--record-yank-pop-state (groups positions before-p)
  "Record final yank GROUPS at POSITIONS with orientation BEFORE-P."
  (multi-cursor--discard-yank-pop-state)
  (let (ranges)
    (cl-mapc
     (lambda (group final-end)
       (let* ((final-beg (- final-end
                            (length (multi-cursor--edit-string group))))
              (state (multi-cursor--edit-survivor group)))
         (push (list (copy-marker final-beg)
                     (copy-marker final-end t)
                     (buffer-substring final-beg final-end)
                     (multi-cursor--edit-state-primary state)
                     (multi-cursor--edit-state-id state))
               ranges)))
     groups (append positions nil))
    (setq multi-cursor--yank-pop-state
          (multi-cursor--yank-pop-state-create
           :tick (buffer-chars-modified-tick)
           :restriction (cons (point-min) (point-max))
           :cursors (copy-sequence multi-cursor--cursors)
           :next-id multi-cursor--next-id
           :ranges (nreverse ranges)
           :before-p before-p
           :window-start yank-window-start))))

(defun multi-cursor--yank-pop-state-edit (range states insertion)
  "Replace recorded yank RANGE in STATES with INSERTION in a new edit."
  (let* ((primary-p (nth 3 range))
         (id (nth 4 range))
         (state
          (cl-find-if
           (lambda (candidate)
             (if primary-p
                 (multi-cursor--edit-state-primary candidate)
               (and (not (multi-cursor--edit-state-primary candidate))
                    (= (multi-cursor--edit-state-id candidate) id))))
           states))
         (beg (marker-position (nth 0 range)))
         (end (marker-position (nth 1 range))))
    (unless (and state beg end)
      (user-error "The previous multiple-cursor yank is no longer live"))
    (unless (equal-including-properties
             (buffer-substring beg end) (nth 2 range))
      (user-error "The previous multiple-cursor yank text has changed"))
    (multi-cursor--preflight-edit-range beg end beg end)
    (multi-cursor--edit-create
     :beg beg :end end :string insertion :survivor state
     :members (list state))))

(defun multi-cursor--validate-yank-pop-state ()
  "Return the current `yank-pop' state, or reject it before editing."
  (let ((state multi-cursor--yank-pop-state))
    (unless (and state (eq last-command 'yank))
      (user-error "Yank-pop must immediately follow a native yank or yank-pop"))
    (unless (and (= (multi-cursor--yank-pop-state-tick state)
                    (buffer-chars-modified-tick))
                 (equal (multi-cursor--yank-pop-state-restriction state)
                        (cons (point-min) (point-max)))
                 (multi-cursor--same-cursor-objects-p
                  (multi-cursor--yank-pop-state-cursors state)
                  (multi-cursor--yank-pop-state-next-id state)))
      (user-error "The previous multiple-cursor yank state has changed"))
    state))

(defun multi-cursor--yank
    (command prefix _keys record-flag _special)
  "Broadcast one snapshotted `kill-ring' string for yank COMMAND.

PREFIX selects the ordinary kill entry and yank orientation.  RECORD-FLAG
non-nil records that single command invocation."
  (unless (eq command 'yank)
    (error "Invalid multiple-cursor yank command: %S" command))
  (let* ((ring-state (multi-cursor--kill-ring-state))
         (initial-states (multi-cursor--snapshot-edit-states))
         (initial-cursors (copy-sequence multi-cursor--cursors))
         (initial-next-id multi-cursor--next-id)
         (callback-context (multi-cursor--callback-context))
         (before-p (consp prefix))
         (index (cond
                 (before-p 0)
                 ((eq prefix '-) -2)
                 (t (1- (prefix-numeric-value prefix)))))
         states insertion groups positions completed)
    ;; Mark an incomplete yank exactly as the ordinary command does.
    (multi-cursor--discard-yank-pop-state)
    (setq yank-window-start (window-start)
          this-command t)
    (unwind-protect
        (progn
          ;; `current-kill' is deliberately called once, including any
          ;; interprogram-paste mutation of the kill ring.
          (save-current-buffer
            (atomic-change-group
              (setq insertion
                    (multi-cursor--prepare-yank-string (current-kill index)))
              (multi-cursor--validate-callback-state callback-context)))
          (setq states initial-states
                groups
                (multi-cursor--merge-edits
                 (mapcar (lambda (state)
                           (multi-cursor--state-edit
                            state 'yank 1 insertion))
                         states)))
          (setq positions
                (multi-cursor--apply-edit-transaction
                 states groups
                 (lambda (edits final-positions edit-states)
                   (let ((context (multi-cursor--callback-context)))
                     (multi-cursor--process-yank-spans edits final-positions)
                     (multi-cursor--validate-callback-state context)
                     (multi-cursor--install-yank-results
                      edits final-positions edit-states before-p)))))
          (multi-cursor--record-yank-pop-state groups positions before-p)
          (setq completed t))
      (unless completed
        (multi-cursor--restore-kill-ring-state ring-state)
        (multi-cursor--restore-edit-states
         initial-states initial-cursors initial-next-id)))
    (setq this-command 'yank
          yank-undo-function nil)
    (when record-flag
      (add-to-history
       'command-history
       (list command
             (if (or (consp prefix) (and (symbolp prefix) prefix))
                 (list 'quote prefix)
               prefix))
       nil t))
    nil))

(defun multi-cursor--yank-pop
    (command prefix _keys record-flag _special)
  "Run COMMAND after native yank, replacing every range selected by PREFIX."
  (unless (eq command 'yank-pop)
    (error "Invalid multiple-cursor yank-pop command: %S" command))
  (let* ((target-state (multi-cursor--validate-yank-pop-state))
         (argument (prefix-numeric-value prefix))
         (ring-state (multi-cursor--kill-ring-state))
         (initial-states (multi-cursor--snapshot-edit-states))
         (initial-cursors (copy-sequence multi-cursor--cursors))
         (initial-next-id multi-cursor--next-id)
         (callback-context (multi-cursor--callback-context))
         (before-p (multi-cursor--yank-pop-state-before-p target-state))
         (external-cut interprogram-cut-function)
         external-value external-called
         insertion edits groups positions completed)
    (unless (integerp argument)
      (signal 'wrong-type-argument (list 'integerp argument)))
    (unwind-protect
        (progn
          ;; Rotate the shared ring once, then broadcast that exact value.
          (save-current-buffer
            (atomic-change-group
              (let ((interprogram-cut-function
                     (lambda (value &rest _arguments)
                       (setq external-value value
                             external-called t))))
                (setq insertion
                      (multi-cursor--prepare-yank-string
                       (current-kill argument))))
              (multi-cursor--validate-callback-state callback-context)))
          (setq edits
                (mapcar
                 (lambda (range)
                   (multi-cursor--yank-pop-state-edit
                    range initial-states insertion))
                 (multi-cursor--yank-pop-state-ranges target-state))
                groups (multi-cursor--merge-edits edits t)
                positions
                (multi-cursor--apply-edit-transaction
                 initial-states groups
                 (lambda (replacement-groups final-positions edit-states)
                   (let ((context (multi-cursor--callback-context)))
                     (multi-cursor--process-yank-spans
                      replacement-groups final-positions)
                     (multi-cursor--validate-callback-state context)
                     (multi-cursor--install-yank-results
                      replacement-groups final-positions edit-states
                      before-p)))))
          (multi-cursor--record-yank-pop-state groups positions before-p)
          (setq completed t))
      (unless completed
        (multi-cursor--restore-kill-ring-state ring-state)
        (multi-cursor--restore-edit-states
         initial-states initial-cursors initial-next-id)
        ;; Cancelling a change group advances the modification tick even when
        ;; it restores the exact text.  Keep the still-valid preceding yank
        ;; retryable after an atomic failure.
        (when (eq multi-cursor--yank-pop-state target-state)
          (setf (multi-cursor--yank-pop-state-tick target-state)
                (buffer-chars-modified-tick)))))
    (setq this-command 'yank
          yank-undo-function nil)
    (when (window-live-p (selected-window))
      (set-window-start
       (selected-window)
       (multi-cursor--yank-pop-state-window-start target-state) t))
    (when record-flag
      (add-to-history 'command-history (list command argument) nil t))
    ;; Selection ownership is an irreversible external effect, so publish it
    ;; only after the buffer transaction and native cursor state have committed.
    (when (and external-called external-cut)
      (funcall external-cut external-value))
    nil))

(defun multi-cursor--batch-edit
    (command prefix _keys record-flag _special)
  "Apply supported editing COMMAND with PREFIX once at every native cursor.

When RECORD-FLAG is non-nil, add the single logical invocation to command
history."
  (when (and prefix (memq command '(delete-char delete-backward-char)))
    (user-error "Prefix deletion is not multiple-cursor safe yet"))
  (let* ((argument (prefix-numeric-value prefix))
         (insertion
          (when (eq command 'self-insert-command)
            (unless (characterp last-command-event)
              (user-error "Self insertion requires a character event"))
            (when (< argument 0)
              (user-error "Negative repetition argument"))
            (make-string argument last-command-event))))
    (unless (memq command
                  '(self-insert-command delete-char delete-backward-char))
      (user-error "%S has no native multiple-cursor batch editor" command))
    (when (and (not (eq command 'self-insert-command))
               (not (integerp argument)))
      (signal 'wrong-type-argument (list 'integerp argument)))
    (unless (and (= argument 0)
                 (not (and mark-active (mark t) (/= (point) (mark t))))
                 (not (cl-some
                       (lambda (cursor)
                         (and (multi-cursor--cursor-mark-active cursor)
                              (multi-cursor--cursor-mark cursor)
                              (/= (marker-position
                                   (multi-cursor--cursor-point cursor))
                                  (marker-position
                                   (multi-cursor--cursor-mark cursor)))))
                       multi-cursor--cursors)))
      (let* ((states (multi-cursor--snapshot-edit-states))
             (edits (mapcar (lambda (state)
                              (multi-cursor--state-edit
                               state command argument insertion))
                            states))
             (groups (multi-cursor--merge-edits edits)))
        (multi-cursor--apply-edit-transaction states groups)))
    (when record-flag
      (add-to-history
       'command-history
       (if (eq command 'self-insert-command)
           (list command argument last-command-event)
         (list command argument))
       nil t))))

(defconst multi-cursor--literal-tab-guarded-options
  '(indent-tabs-mode tab-width tab-always-indent indent-line-function
    abbrev-mode)
  "Options which select the literal branch of `indent-for-tab-command'.")

(defun multi-cursor--literal-tab-option-state ()
  "Return the buffer-local values which make literal TAB safe to batch.

The locality bit matters: an after-change hook that makes an option local can
silently change later TAB behavior even when its value currently agrees with
the global default.  Keep that default too, since a hook may change it while
this buffer has no local binding."
  (mapcar (lambda (variable)
            (list variable
                  (local-variable-p variable)
                  (symbol-value variable)
                  (default-value variable)))
          multi-cursor--literal-tab-guarded-options))

(defun multi-cursor--literal-tab-options-unchanged-p (state)
  "Return non-nil when literal TAB option STATE still matches this buffer."
  (cl-every
   (lambda (entry)
     (and (eq (local-variable-p (nth 0 entry)) (nth 1 entry))
          (equal (symbol-value (nth 0 entry)) (nth 2 entry))
          (equal (default-value (nth 0 entry)) (nth 3 entry))))
   state))

(defun multi-cursor--restore-literal-tab-option-state (state)
  "Restore literal TAB option STATE after an aborted native transaction."
  (dolist (entry state)
    (let ((variable (nth 0 entry))
          (localp (nth 1 entry))
          (value (nth 2 entry))
          (default (nth 3 entry)))
      (set-default variable default)
      (if localp
          (set (make-local-variable variable) value)
        (kill-local-variable variable)))))

(defun multi-cursor--literal-tab-selection-p (state)
  "Return non-nil if STATE has an active selection.

The bounded literal TAB handler deliberately does not model region
indentation, even for an empty active region."
  (and (multi-cursor--edit-state-active state)
       (multi-cursor--edit-state-mark state)))

(defun multi-cursor--literal-tab-state-p (state)
  "Return non-nil when ordinary TAB takes its literal branch for STATE.

This is the branch predicate from `indent-for-tab-command'.  Evaluate it at
every saved cursor position before starting the transaction: accepting a
literal TAB at only some cursors would incorrectly run indentation at the
others."
  (or (eq indent-line-function #'indent-to-left-margin)
      (and (null tab-always-indent)
           (or (eq this-command last-command)
               (save-excursion
                 (goto-char (multi-cursor--edit-state-point state))
                 (> (current-column) (current-indentation)))))))

(defun multi-cursor--literal-tab-string (state)
  "Return the exact `insert-tab' text for STATE with no prefix argument."
  (if indent-tabs-mode
      "\t"
    (let ((column
           (save-excursion
             (goto-char (multi-cursor--edit-state-point state))
             (current-column))))
      (make-string
       (- (* tab-width (1+ (/ column tab-width))) column)
       ?\s))))

(defconst multi-cursor--elisp-indent-guarded-options
  '(indent-tabs-mode tab-width tab-always-indent abbrev-mode
    lisp-indent-offset lisp-body-indent
    indent-line-function lisp-indent-function lisp-indent-local-overrides
    overwrite-mode auto-fill-function use-hard-newlines
    translation-table-for-input left-margin post-self-insert-hook
    electric-indent-mode)
  "Options which define the bounded Emacs Lisp indentation contract.")

(defun multi-cursor--elisp-indent-option-state ()
  "Capture effective, local, and default Lisp indentation option state."
  (mapcar (lambda (variable)
            (list variable (local-variable-p variable)
                  (symbol-value variable) (default-value variable)))
          multi-cursor--elisp-indent-guarded-options))

(defun multi-cursor--elisp-indent-options-unchanged-p (state)
  "Return non-nil when Lisp indentation option STATE is unchanged."
  (cl-every
   (lambda (entry)
     (let ((variable (nth 0 entry)))
       (and (eq (local-variable-p variable) (nth 1 entry))
            (equal (symbol-value variable) (nth 2 entry))
            (equal (default-value variable) (nth 3 entry)))))
   state))

(defun multi-cursor--restore-elisp-indent-option-state (state)
  "Restore effective, local, and default Lisp indentation option STATE."
  (dolist (entry state)
    (let ((variable (nth 0 entry)))
      (unless (equal (default-value variable) (nth 3 entry))
        (set-default variable (nth 3 entry)))
      (if (nth 1 entry)
          (set (make-local-variable variable) (nth 2 entry))
        (kill-local-variable variable)
        (set variable (nth 2 entry))))))

(defun multi-cursor--elisp-indent-line-info (state restriction)
  "Return physical line information for STATE within RESTRICTION.

The result is (BEG PREFIX-END).  Signal `user-error' if the cursor does not
own a complete accessible physical line or the line needs semantics outside
the bounded stock Lisp contract."
  (let ((position (multi-cursor--edit-state-point state))
        physical-beg physical-end prefix-end)
    (unless (<= (car restriction) position (cdr restriction))
      (user-error "Lisp indentation cursor is outside the accessible buffer"))
    (save-restriction
      (widen)
      (save-excursion
        (goto-char position)
        (setq physical-beg (line-beginning-position)
              physical-end (line-end-position))
        (unless (and (<= (car restriction) physical-beg)
                     (<= physical-end (cdr restriction)))
          (user-error "Lisp indentation requires complete accessible lines"))
        (goto-char physical-beg)
        (skip-chars-forward " \t" physical-end)
        (setq prefix-end (point))
        (let ((ppss (syntax-ppss prefix-end)))
          (when (or (nth 3 ppss) (nth 4 ppss)
                    (eq (char-after prefix-end) ?\;)
                    (eq (char-after prefix-end) ?\"))
            (user-error
             "Comment and string indentation is not multiple-cursor safe")))
        (when (cl-some
               (lambda (overlay)
                 (or (overlay-get overlay 'read-only)
                     (overlay-get overlay 'invisible)
                     (overlay-get overlay 'display)))
               (overlays-in physical-beg (max (1+ physical-beg) prefix-end)))
          (user-error "Overlay-sensitive Lisp indentation is not supported"))))
    (list physical-beg prefix-end)))

(defun multi-cursor--elisp-indent-shadow-plan (states line-info)
  "Return exact shadow-buffer indentation plan for STATES and LINE-INFO.

The result is (PREFIXES PLANNED-STATES), where PREFIXES contains
(ORIGINAL-BEG ORIGINAL-END STRING STATE) records in source order."
  (let ((source-text
         (save-restriction
           (widen)
           (buffer-substring (point-min) (point-max))))
        (syntax (syntax-table))
        (tabs indent-tabs-mode)
        (width tab-width)
        (offset lisp-indent-offset)
        (body-indent lisp-body-indent)
        records line-records)
    (with-temp-buffer
      (let ((emacs-lisp-mode-hook nil)
            (change-major-mode-hook nil)
            (after-change-major-mode-hook nil))
        (emacs-lisp-mode))
      (set-syntax-table syntax)
      (insert source-text)
      (setq-local indent-tabs-mode tabs
                  tab-width width
                  lisp-indent-offset offset
                  lisp-body-indent body-indent
                  indent-line-function #'lisp-indent-line
                  lisp-indent-function #'lisp-indent-function
                  lisp-indent-local-overrides nil
                  before-change-functions nil
                  after-change-functions nil)
      (setq records
            (cl-mapcar
             (lambda (state info)
               (list state (copy-marker (multi-cursor--edit-state-point state))
                     (and (multi-cursor--edit-state-mark state)
                          (copy-marker (multi-cursor--edit-state-mark state)))
                     (copy-marker (car info))))
             states line-info))
      (setq line-records
            (cl-mapcar
             (lambda (state info)
               (list (car info) (cadr info) state (copy-marker (car info))))
             states line-info))
      (unwind-protect
          (progn
            (dolist (record
                     (sort (copy-sequence records)
                           (lambda (left right)
                             (< (marker-position (nth 1 left))
                                (marker-position (nth 1 right))))))
              (goto-char (marker-position (nth 1 record)))
              (set-marker (mark-marker)
                          (and (nth 2 record)
                               (marker-position (nth 2 record))))
              (setq mark-active (multi-cursor--edit-state-active (car record)))
              (lisp-indent-line)
              (set-marker (nth 1 record) (point)))
            (let ((planned-states
                   (mapcar
                    (lambda (record)
                      (let ((copy (copy-multi-cursor--edit-state (car record))))
                        (setf (multi-cursor--edit-state-point copy)
                              (marker-position (nth 1 record))
                              (multi-cursor--edit-state-mark copy)
                              (and (nth 2 record)
                                   (marker-position (nth 2 record))))
                        copy))
                    records))
                  prefixes)
              (dolist (record line-records)
                (goto-char (marker-position (nth 3 record)))
                (let ((shadow-beg (point)))
                  (skip-chars-forward " \t" (line-end-position))
                  (push (list (nth 0 record) (nth 1 record)
                              (buffer-substring shadow-beg (point))
                              (nth 2 record))
                        prefixes)))
              (list (nreverse prefixes) planned-states (buffer-string))))
        (dolist (record records)
          (set-marker (nth 1 record) nil)
          (when (nth 2 record) (set-marker (nth 2 record) nil)))
        (dolist (record line-records)
          (set-marker (nth 3 record) nil))))))

(defun multi-cursor--elisp-indent (states record-flag)
  "Indent stock Emacs Lisp cursor STATES as one native transaction.

RECORD-FLAG controls the one command-history entry."
  (unless (and (eq major-mode 'emacs-lisp-mode)
               (eq indent-line-function #'lisp-indent-line)
               (eq lisp-indent-function #'lisp-indent-function)
               (null lisp-indent-local-overrides)
               (integerp lisp-indent-offset)
               (not (and (fboundp 'advice--p)
                         (or (advice--p (symbol-function 'lisp-indent-line))
                             (advice--p (symbol-function 'lisp-indent-function))))))
    (user-error "This Lisp indentation configuration is not multiple-cursor safe"))
  (let* ((restriction (cons (point-min) (point-max)))
         (line-info (mapcar (lambda (state)
                              (multi-cursor--elisp-indent-line-info
                               state restriction))
                            states))
         (line-starts (mapcar #'car line-info)))
    (unless (= (length line-starts)
               (length (delete-dups (copy-sequence line-starts))))
      (user-error "Multiple Lisp cursors on one physical line are unsupported"))
    (let* ((option-state (multi-cursor--elisp-indent-option-state))
           (original-cursors (copy-sequence multi-cursor--cursors))
           (original-next-id multi-cursor--next-id)
           (plan (multi-cursor--elisp-indent-shadow-plan states line-info))
           (prefixes (car plan))
           (planned-states (cadr plan))
           (planned-text (nth 2 plan))
           (edits
            (delq
             nil
             (mapcar
              (lambda (record)
                (unless (equal (buffer-substring-no-properties
                                (nth 0 record) (nth 1 record))
                               (nth 2 record))
                  (multi-cursor--preflight-edit-range
                   (nth 0 record) (nth 1 record)
                   (nth 0 record) (nth 1 record))
                  (multi-cursor--edit-create
                   :beg (nth 0 record) :end (nth 1 record)
                   :string (nth 2 record) :survivor (nth 3 record)
                   :members (list (nth 3 record)))))
              prefixes)))
           (groups (multi-cursor--merge-edits edits t))
           completed)
      (unwind-protect
          (progn
            (if groups
                (multi-cursor--apply-edit-transaction
                 states groups
                 (lambda (_edits _positions _states)
                   (unless (multi-cursor--elisp-indent-options-unchanged-p
                            option-state)
                     (error "Lisp indentation options changed during editing"))
                   (unless (multi-cursor--same-cursor-objects-p
                            original-cursors original-next-id)
                     (error "Lisp indentation changed the cursor session"))
                   (unless
                       (equal
                        (save-restriction (widen) (buffer-string))
                        planned-text)
                     (error "Lisp indentation hooks changed the planned text"))
                   (multi-cursor--restore-edit-states
                    planned-states original-cursors original-next-id)))
              (unless (multi-cursor--elisp-indent-options-unchanged-p
                       option-state)
                (error "Lisp indentation options changed during planning"))
              (multi-cursor--restore-edit-states
               planned-states original-cursors original-next-id))
            (setq completed t))
        (unless completed
          (multi-cursor--restore-elisp-indent-option-state option-state)))
      (when record-flag
        (add-to-history 'command-history '(indent-for-tab-command) nil t)))))

(defun multi-cursor--newline-indent-shadow-plan (states line-info)
  "Return a stock shadow plan for bounded `newline-and-indent' STATES.

LINE-INFO is the complete-line data already validated in the live buffer.
The result is (REPLACEMENTS PLANNED-STATES PLANNED-TEXT)."
  (let ((source-text
         (save-restriction
           (widen)
           (buffer-substring (point-min) (point-max))))
        (syntax (syntax-table))
        (tabs indent-tabs-mode)
        (width tab-width)
        (offset lisp-indent-offset)
        (body-indent lisp-body-indent)
        records)
    (with-temp-buffer
      (let ((emacs-lisp-mode-hook nil)
            (change-major-mode-hook nil)
            (after-change-major-mode-hook nil))
        (emacs-lisp-mode))
      (set-syntax-table syntax)
      (insert source-text)
      (setq-local indent-tabs-mode tabs
                  tab-width width
                  lisp-indent-offset offset
                  lisp-body-indent body-indent
                  indent-line-function #'lisp-indent-line
                  lisp-indent-function #'lisp-indent-function
                  lisp-indent-local-overrides nil
                  abbrev-mode nil
                  auto-fill-function nil
                  use-hard-newlines nil
                  translation-table-for-input nil
                  post-self-insert-hook nil
                  before-change-functions nil
                  after-change-functions nil)
      (setq records
            (cl-mapcar
             (lambda (state info)
               (let ((point (multi-cursor--edit-state-point state)))
                 (list state (copy-marker point)
                       (and (multi-cursor--edit-state-mark state)
                            (copy-marker (multi-cursor--edit-state-mark state)))
                       (copy-marker (car info))
                       (save-excursion
                         (goto-char point)
                         (skip-chars-backward " \t" (car info))
                         (point))
                       (save-excursion
                         (goto-char point)
                         (skip-chars-forward " \t" (line-end-position))
                         (point))
                       nil)))
             states line-info))
      (unwind-protect
          (progn
            (dolist (record
                     (sort (copy-sequence records)
                           (lambda (left right)
                             (< (marker-position (nth 1 left))
                                (marker-position (nth 1 right))))))
              (goto-char (marker-position (nth 1 record)))
              (set-marker (mark-marker)
                          (and (nth 2 record)
                               (marker-position (nth 2 record))))
              (setq mark-active (multi-cursor--edit-state-active (car record)))
              (delete-horizontal-space t)
              (let ((beg-marker (copy-marker (point))))
                (setf (nth 6 record) beg-marker)
                (let ((electric-indent-mode nil))
                  (newline nil t)
                  (indent-according-to-mode))
                (set-marker (nth 1 record) (point))))
            (let ((planned-states
                   (mapcar
                    (lambda (record)
                      (let ((copy (copy-multi-cursor--edit-state (car record))))
                        (setf (multi-cursor--edit-state-point copy)
                              (marker-position (nth 1 record))
                              (multi-cursor--edit-state-mark copy)
                              (and (nth 2 record)
                                   (marker-position (nth 2 record))))
                        copy))
                    records))
                  replacements)
              (dolist (record records)
                (push (list (nth 4 record) (nth 5 record)
                            (buffer-substring
                             (marker-position (nth 6 record))
                             (marker-position (nth 1 record)))
                            (car record))
                      replacements))
              (list (nreverse replacements) planned-states (buffer-string))))
        (dolist (record records)
          (set-marker (nth 1 record) nil)
          (when (nth 2 record) (set-marker (nth 2 record) nil))
          (set-marker (nth 3 record) nil)
          (when (nth 6 record) (set-marker (nth 6 record) nil)))))))

(defun multi-cursor--newline-and-indent
    (command prefix _keys record-flag _special)
  "Handle COMMAND by inserting and indenting one Lisp newline per cursor."
  (unless (eq command 'newline-and-indent)
    (error "Invalid multiple-cursor newline-and-indent command: %S" command))
  (unless (or (null prefix) (equal prefix 1))
    (user-error "Multiple-cursor newline-and-indent accepts one newline"))
  (when (minibufferp)
    (user-error "Newline-and-indent is unsafe in a minibuffer"))
  (unless (and (eq major-mode 'emacs-lisp-mode)
               (eq indent-line-function #'lisp-indent-line)
               (eq lisp-indent-function #'lisp-indent-function)
               (null lisp-indent-local-overrides)
               (integerp lisp-indent-offset)
               (not (and (fboundp 'advice--p)
                         (or (advice--p (symbol-function 'lisp-indent-line))
                             (advice--p (symbol-function 'lisp-indent-function))))))
    (user-error "This newline indentation configuration is not multiple-cursor safe"))
  (when (or abbrev-mode auto-fill-function overwrite-mode use-hard-newlines
            translation-table-for-input)
    (user-error "This newline insertion context is not multiple-cursor safe"))
  (let* ((states (multi-cursor--snapshot-edit-states))
         (restriction (cons (point-min) (point-max))))
    (when (cl-some #'multi-cursor--literal-tab-selection-p states)
      (user-error "Newline-and-indent with active selections is unsupported"))
    (let* ((line-info
            (mapcar
             (lambda (state)
               (let ((info (multi-cursor--elisp-indent-line-info
                            state restriction)))
                 (save-excursion
                   (goto-char (multi-cursor--edit-state-point state))
                   (unless (zerop (current-left-margin))
                     (user-error "Newline-and-indent with margins is unsupported"))
                   (when (or (text-properties-at (point))
                             (and (> (point) (line-beginning-position))
                                  (text-properties-at (1- (point)))))
                     (user-error "Property-sensitive newline is unsupported")))
                 info))
             states))
           (line-starts (mapcar #'car line-info)))
      (unless (= (length line-starts)
                 (length (delete-dups (copy-sequence line-starts))))
        (user-error "Multiple newline cursors on one physical line are unsupported"))
      (let* ((option-state (multi-cursor--elisp-indent-option-state))
             (original-cursors (copy-sequence multi-cursor--cursors))
             (original-next-id multi-cursor--next-id)
             (plan (multi-cursor--newline-indent-shadow-plan states line-info))
             (replacements (car plan))
             (planned-states (cadr plan))
             (planned-text (nth 2 plan))
             (edits
              (mapcar
               (lambda (record)
                 (multi-cursor--preflight-edit-range
                  (nth 0 record) (nth 1 record) (nth 0 record) (nth 1 record))
                 (multi-cursor--edit-create
                  :beg (nth 0 record) :end (nth 1 record)
                  :string (nth 2 record) :survivor (nth 3 record)
                  :members (list (nth 3 record))))
               replacements))
             (groups (multi-cursor--merge-edits edits t))
             completed)
        (unwind-protect
            (progn
              (multi-cursor--apply-edit-transaction
               states groups
               (lambda (_edits _positions _states)
                 (unless (multi-cursor--elisp-indent-options-unchanged-p
                          option-state)
                   (error "Newline indentation options changed during editing"))
                 (unless (multi-cursor--same-cursor-objects-p
                          original-cursors original-next-id)
                   (error "Newline indentation changed the cursor session"))
                 (unless
                     (equal (save-restriction (widen) (buffer-string))
                            planned-text)
                   (error "Newline hooks changed the planned text"))
                 (multi-cursor--restore-edit-states
                  planned-states original-cursors original-next-id)))
              (setq completed t))
          (unless completed
            (multi-cursor--restore-elisp-indent-option-state option-state)))
        (when record-flag
          (add-to-history 'command-history '(newline-and-indent) nil t))))))

(defun multi-cursor--literal-tab-handler
    (command prefix _keys record-flag _special)
  "Batch the literal insertion branch of `indent-for-tab-command'.

This supports only cases in which every cursor takes Emacs's literal
insertion branch.  Prefix indentation, regions, abbrev expansion, completion,
and any cursor which would run an indentation function retain their ordinary
single-cursor semantics instead of being guessed at for each native cursor."
  (unless (eq command 'indent-for-tab-command)
    (error "Invalid multiple-cursor literal TAB command: %S" command))
  (when prefix
    (user-error "Prefix TAB is not multiple-cursor safe"))
  (when (minibufferp (current-buffer))
    (user-error "TAB is not multiple-cursor safe in the minibuffer"))
  (when (or abbrev-mode (eq tab-always-indent 'complete))
    (user-error "This TAB completion or abbrev branch is not multiple-cursor safe"))
  (unless (or indent-tabs-mode
              (and (integerp tab-width) (> tab-width 0)))
    (user-error "TAB width is not multiple-cursor safe"))
  (let* ((states (multi-cursor--snapshot-edit-states))
         (literal-states (mapcar #'multi-cursor--literal-tab-state-p states)))
    (when (cl-some #'multi-cursor--literal-tab-selection-p states)
      (user-error "TAB with an active selection is not multiple-cursor safe"))
    (cond
     ((cl-every #'identity literal-states)
      (let ((option-state (multi-cursor--literal-tab-option-state))
            completed)
        (unwind-protect
            (progn
              (let ((groups
                     (multi-cursor--merge-edits
                      (mapcar
                       (lambda (state)
                         (let ((position (multi-cursor--edit-state-point state)))
                           (multi-cursor--preflight-edit-range
                            position position position position)
                           (multi-cursor--edit-create
                            :beg position :end position
                            :string (multi-cursor--literal-tab-string state)
                            :survivor state :members (list state))))
                       states))))
                (multi-cursor--apply-edit-transaction
                 states groups
                 (lambda (edits positions edit-states)
                   (unless
                       (multi-cursor--literal-tab-options-unchanged-p option-state)
                     (error "TAB options changed during multiple-cursor edit"))
                   (multi-cursor--install-edit-results
                    edits positions edit-states)))
                (setq completed t)))
          (unless completed
            (multi-cursor--restore-literal-tab-option-state option-state)))))
     ((cl-some #'identity literal-states)
      (user-error "Mixed literal and indentation TAB branches are unsupported"))
     (t
      (multi-cursor--elisp-indent states record-flag)))))

(defun multi-cursor--newline-post-hook-safe-p (hook)
  "Return non-nil when HOOK contains only stock newline-inert entries."
  (and (proper-list-p hook)
       (cl-every
        (lambda (function)
          (memq function
                '(electric-indent-post-self-insert-function
                  blink-paren-post-self-insert-function)))
        hook)))

(defconst multi-cursor--electric-newline-guarded-options
  '(overwrite-mode abbrev-mode auto-fill-function use-hard-newlines
    electric-indent-mode translation-table-for-input delete-active-region
    left-margin post-self-insert-hook electric-indent-functions
    electric-indent-chars indent-line-function indent-line-ignored-functions
    electric-indent-functions-without-reindent electric-indent-inhibit
    indent-tabs-mode tab-width syntax-propertize-function)
  "Options that must remain stable across electric-newline planning and edits.")

(defun multi-cursor--electric-newline-reference-child-state (value)
  "Capture VALUE identity and recursive mutable reference state."
  (list value
        (unless (functionp value)
          (multi-cursor--electric-newline-reference-state value))))

(defun multi-cursor--electric-newline-reference-state (value)
  "Capture child identities of a guarded mutable option VALUE."
  (cond
   ((functionp value) nil)
   ((consp value)
    (list 'cons
          (multi-cursor--electric-newline-reference-child-state (car value))
          (multi-cursor--electric-newline-reference-child-state (cdr value))))
   ((char-table-p value)
    (let* ((direct (copy-sequence value))
           (subtype (char-table-subtype value))
           (slots (or (get subtype 'char-table-extra-slots) 0))
           (slot-states (make-vector slots nil))
           ranges)
      (set-char-table-parent direct nil)
      (map-char-table
       (lambda (range entry)
         (push
          (list range
                (multi-cursor--electric-newline-reference-child-state
                 entry))
          ranges))
       direct)
      (dotimes (index slots)
        (aset
         slot-states index
         (multi-cursor--electric-newline-reference-child-state
          (char-table-extra-slot value index))))
      (list
       'char-table
       (multi-cursor--electric-newline-reference-child-state
        (char-table-range value nil))
       ranges
       slot-states
       (multi-cursor--electric-newline-reference-child-state
        (char-table-parent value)))))
   ((and (not (bool-vector-p value))
         (or (recordp value) (vectorp value)))
    (let ((states (make-vector (length value) nil)))
      (dotimes (index (length value))
        (aset
         states index
         (multi-cursor--electric-newline-reference-child-state
          (aref value index))))
      (list 'vector states)))
   (t nil)))

(defun multi-cursor--validate-electric-newline-reference-child
    (value state)
  "Return non-nil when VALUE retains identities recorded in child STATE."
  (and
   (eq value (nth 0 state))
   (let ((nested (nth 1 state)))
     (or
      (null nested)
      (multi-cursor--validate-electric-newline-reference-state
       value nested)))))

(defun multi-cursor--validate-electric-newline-reference-state
    (value state)
  "Return non-nil when guarded VALUE retains recursive reference STATE."
  (pcase (nth 0 state)
    ('cons
     (and
      (consp value)
      (multi-cursor--validate-electric-newline-reference-child
       (car value) (nth 1 state))
      (multi-cursor--validate-electric-newline-reference-child
       (cdr value) (nth 2 state))))
    ('char-table
     (and
      (char-table-p value)
      (let* ((direct (copy-sequence value))
             (slot-states (nth 3 state)))
        (set-char-table-parent direct nil)
        (and
         (multi-cursor--validate-electric-newline-reference-child
          (char-table-range value nil) (nth 1 state))
         (cl-every
          (lambda (range-state)
            (multi-cursor--validate-electric-newline-reference-child
             (char-table-range direct (nth 0 range-state))
             (nth 1 range-state)))
          (nth 2 state))
         (cl-loop
          for index below (length slot-states)
          always
          (multi-cursor--validate-electric-newline-reference-child
           (char-table-extra-slot value index)
           (aref slot-states index)))
         (multi-cursor--validate-electric-newline-reference-child
          (char-table-parent value) (nth 4 state))))))
    ('vector
     (let ((states (nth 1 state)))
       (and
        (not (bool-vector-p value))
        (or (recordp value) (vectorp value))
        (= (length value) (length states))
        (cl-loop
         for index below (length states)
         always
         (multi-cursor--validate-electric-newline-reference-child
          (aref value index) (aref states index))))))
    (_ nil)))

(defun multi-cursor--restore-electric-newline-reference-child
    (state snapshot)
  "Restore saved child reference STATE from detached SNAPSHOT."
  (multi-cursor--restore-electric-newline-value
   (nth 0 state) snapshot (nth 1 state)))

(defun multi-cursor--snapshot-electric-newline-value (value)
  "Return a detached snapshot of mutable guarded option VALUE."
  (cond
   ((functionp value) value)
   ((consp value)
    (cons (multi-cursor--snapshot-electric-newline-value (car value))
          (multi-cursor--snapshot-electric-newline-value (cdr value))))
   ((stringp value) (copy-sequence value))
   ((char-table-p value)
    (let* ((copy (copy-sequence value))
           (parent (char-table-parent value))
           (subtype (char-table-subtype value))
           (slots (or (get subtype 'char-table-extra-slots) 0)))
      ;; `map-char-table' includes inherited parent ranges.  Detach the
      ;; parent while copying direct entries, then snapshot it separately.
      (set-char-table-parent copy nil)
      (set-char-table-range
       copy nil
       (multi-cursor--snapshot-electric-newline-value
        (char-table-range value nil)))
      (let (ranges)
        (map-char-table
         (lambda (range entry)
           (push (cons range entry) ranges))
         copy)
        (dolist (range-state ranges)
          (set-char-table-range
           copy (car range-state)
           (multi-cursor--snapshot-electric-newline-value
            (cdr range-state)))))
      (dotimes (index slots)
        (set-char-table-extra-slot
         copy index
         (multi-cursor--snapshot-electric-newline-value
          (char-table-extra-slot value index))))
      (set-char-table-parent
       copy (multi-cursor--snapshot-electric-newline-value parent))
      copy))
   ((bool-vector-p value) (copy-sequence value))
   ((or (recordp value) (vectorp value))
    (let ((copy (copy-sequence value)))
      (dotimes (index (length value))
        (aset copy index
              (multi-cursor--snapshot-electric-newline-value
               (aref value index))))
      copy))
   (t value)))

(defun multi-cursor--restore-electric-newline-value
    (original snapshot &optional reference-state)
  "Repair mutable ORIGINAL from detached SNAPSHOT and return ORIGINAL.

REFERENCE-STATE preserves pre-callback child references recursively.
When ORIGINAL cannot be repaired in place, return the detached snapshot."
  (cond
   ((eq original snapshot) original)
   ((and (consp original) (consp snapshot))
    (setcar
     original
     (multi-cursor--restore-electric-newline-reference-child
      (nth 1 reference-state) (car snapshot)))
    (setcdr
     original
     (multi-cursor--restore-electric-newline-reference-child
      (nth 2 reference-state) (cdr snapshot)))
    original)
   ((and (stringp original) (stringp snapshot)
         (= (length original) (length snapshot)))
    (dotimes (index (length original))
      (aset original index (aref snapshot index)))
    original)
   ((and (char-table-p original) (char-table-p snapshot)
         (eq (char-table-subtype original)
             (char-table-subtype snapshot)))
    (let* ((range-states (nth 2 reference-state))
           (slot-states (nth 3 reference-state))
           (direct-snapshot (copy-sequence snapshot)))
      (set-char-table-parent direct-snapshot nil)
      (set-char-table-parent original nil)
      (set-char-table-range original t nil)
      (set-char-table-range
       original nil
       (multi-cursor--restore-electric-newline-reference-child
        (nth 1 reference-state) (char-table-range snapshot nil)))
      (dolist (range-state range-states)
        (let ((range (nth 0 range-state)))
          (set-char-table-range
           original range
           (multi-cursor--restore-electric-newline-reference-child
            (nth 1 range-state)
            (char-table-range direct-snapshot range)))))
      (dotimes (index (length slot-states))
        (set-char-table-extra-slot
         original index
         (multi-cursor--restore-electric-newline-reference-child
          (aref slot-states index)
          (char-table-extra-slot snapshot index))))
      (set-char-table-parent
       original
       (multi-cursor--restore-electric-newline-reference-child
        (nth 4 reference-state) (char-table-parent snapshot)))
      original))
   ((and (bool-vector-p original) (bool-vector-p snapshot)
         (= (length original) (length snapshot)))
    (dotimes (index (length original))
      (aset original index (aref snapshot index)))
    original)
   ((and (or (recordp original) (vectorp original))
         (or (recordp snapshot) (vectorp snapshot))
         (= (length original) (length snapshot)))
    (let ((states (nth 1 reference-state)))
      (dotimes (index (length original))
        (aset
         original index
         (multi-cursor--restore-electric-newline-reference-child
          (aref states index) (aref snapshot index)))))
    original)
   (t snapshot)))

(defun multi-cursor--electric-newline-options ()
  "Capture guarded option binding states, references, and snapshots."
  (mapcar
   (lambda (variable)
     (let ((value (symbol-value variable))
           (default (default-value variable)))
       (list variable
             (local-variable-p variable)
             value
             (multi-cursor--snapshot-electric-newline-value value)
             default
             (multi-cursor--snapshot-electric-newline-value default)
             (multi-cursor--electric-newline-reference-state value)
             (multi-cursor--electric-newline-reference-state default))))
   multi-cursor--electric-newline-guarded-options))

(defun multi-cursor--validate-electric-newline-options (options)
  "Signal an error unless guarded electric-newline OPTIONS are unchanged."
  (unless
      (cl-every
       (lambda (entry)
         (let ((variable (nth 0 entry)))
           (and
            (eq (local-variable-p variable) (nth 1 entry))
            (eq (symbol-value variable) (nth 2 entry))
            (equal (symbol-value variable) (nth 3 entry))
            (eq (default-value variable) (nth 4 entry))
            (equal (default-value variable) (nth 5 entry))
            (or
             (null (nth 6 entry))
             (multi-cursor--validate-electric-newline-reference-state
              (symbol-value variable) (nth 6 entry)))
            (or
             (null (nth 7 entry))
             (multi-cursor--validate-electric-newline-reference-state
              (default-value variable) (nth 7 entry))))))
       options)
    (error "Electric newline changed guarded options")))

(defun multi-cursor--restore-electric-newline-defaults (options)
  "Restore process-wide guarded defaults in OPTIONS."
  (dolist (entry options)
    (set-default
     (nth 0 entry)
     (multi-cursor--restore-electric-newline-value
      (nth 4 entry) (nth 5 entry) (nth 7 entry)))))

(defun multi-cursor--restore-electric-newline-locals (options)
  "Restore guarded local binding states and values in OPTIONS."
  (dolist (entry options)
    (let* ((variable (nth 0 entry))
           (local (nth 1 entry))
           (value
            (multi-cursor--restore-electric-newline-value
             (nth 2 entry) (nth 3 entry) (nth 6 entry))))
      (if local
          (set (make-local-variable variable) value)
        (when (local-variable-p variable)
          (kill-local-variable variable))
        (unless (eq (symbol-value variable) value)
          (set variable value)
          (when (local-variable-p variable)
            (kill-local-variable variable)))))))

(defun multi-cursor--restore-electric-newline-failure
    (options buffer states cursors next-id)
  "Restore failed electric newline state, tolerating a dead BUFFER."
  (multi-cursor--restore-electric-newline-defaults options)
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (multi-cursor--restore-electric-newline-locals options)
      (multi-cursor--restore-edit-states states cursors next-id)
      (unless multi-cursor-mode
        (setq multi-cursor-mode t)
        (multi-cursor--start)))
    (set-buffer buffer)))

(defun multi-cursor--validate-electric-newline-contract ()
  "Reject electric indentation outside the bounded relative-indent contract."
  (unless
      (and electric-indent-mode
           (memq #'electric-indent-post-self-insert-function
                 post-self-insert-hook)
           (null electric-indent-functions)
           (proper-list-p electric-indent-chars)
           (memq ?\n electric-indent-chars)
           (eq indent-line-function #'indent-relative)
           (proper-list-p indent-line-ignored-functions)
           (memq #'indent-relative indent-line-ignored-functions)
           (proper-list-p electric-indent-functions-without-reindent)
           (memq #'indent-relative
                 electric-indent-functions-without-reindent)
           (not (eq electric-indent-inhibit 'electric-layout-mode))
           (memq syntax-propertize-function '(nil ignore)))
    (user-error
     "Electric newline is outside the bounded relative-indent contract")))

(defun multi-cursor--electric-newline-tab-width ()
  "Return `tab-width' sanitized for canonical electric indentation."
  (if (and (integerp tab-width) (<= 1 tab-width 1000))
      tab-width
    8))

(defun multi-cursor--electric-newline-indentation (column)
  "Return canonical indentation from column zero through COLUMN."
  (let ((width (multi-cursor--electric-newline-tab-width)))
    (if indent-tabs-mode
        (concat (make-string (/ column width) ?\t)
                (make-string (% column width) ?\s))
      (make-string column ?\s))))

(defun multi-cursor--electric-newline-reject-properties (beg end)
  "Reject text properties or active read-only values around BEG..END.

The neighboring characters are inheritance boundaries for the replacement."
  (let ((buffer-beg (point-min))
        (buffer-end (point-max))
        (position beg))
    (while (< position end)
      (when (or (text-properties-at position)
                (multi-cursor--read-only-value-blocks-p
                 (get-char-property position 'read-only)))
        (user-error
         "Electric newline in a property context is not multiple-cursor safe"))
      (setq position (1+ position)))
    (dolist (boundary (list (1- beg) beg (1- end) end))
      (when (and (<= buffer-beg boundary)
                 (< boundary buffer-end)
                 (or (text-properties-at boundary)
                     (multi-cursor--read-only-value-blocks-p
                      (get-char-property boundary 'read-only))))
        (user-error
         "Electric newline at a property boundary is not multiple-cursor safe")))))

(defun multi-cursor--electric-newline-state-edit (state)
  "Plan the bounded electric newline replacement for detached cursor STATE."
  (let* ((position (multi-cursor--edit-state-point state))
         (accessible-beg (point-min))
         (accessible-end (point-max))
         line-beg indent-end trailing-beg target-column replacement)
    (goto-char position)
    (unless (= position (line-end-position))
      (user-error "Electric newline requires every cursor at end of line"))
    (unless (zerop (current-left-margin))
      (user-error
       "Electric newline with a left margin is not multiple-cursor safe"))
    (save-restriction
      (widen)
      (goto-char position)
      (unless (= position (line-end-position))
        (user-error
         "Electric newline at a narrowed physical mid-line is unsupported"))
      (setq line-beg (line-beginning-position))
      (unless (<= accessible-beg line-beg position accessible-end)
        (user-error
         "Electric newline requires complete accessible physical lines"))
      (save-excursion
        (goto-char line-beg)
        (skip-chars-forward " \t" position)
        (setq indent-end (point)))
      (save-excursion
        (goto-char position)
        (skip-chars-backward " \t" line-beg)
        (setq trailing-beg (point)))
      (setq target-column
            (if (= trailing-beg line-beg)
                0
              (let ((tab-width
                     (multi-cursor--electric-newline-tab-width)))
                (save-excursion
                  (goto-char position)
                  (current-indentation)))))
      (multi-cursor--electric-newline-reject-properties line-beg indent-end)
      (multi-cursor--electric-newline-reject-properties
       trailing-beg position))
    (multi-cursor--preflight-edit-range
     trailing-beg position position trailing-beg)
    (setq replacement
          (concat "\n"
                  (multi-cursor--electric-newline-indentation
                   target-column)))
    (multi-cursor--edit-create
     :beg trailing-beg :end position :string replacement
     :survivor state :members (list state))))

(defun multi-cursor--remap-electric-newline-mark
    (position groups positions)
  "Remap electric-newline mark POSITION through GROUPS and POSITIONS.

Marks in a removed trailing-whitespace range stay before the inserted
newline and indentation, matching ordinary before-gravity mark behavior."
  (multi-cursor--remap-edit-position position groups positions t))

(defun multi-cursor--install-electric-newline-results
    (groups positions states)
  "Install electric-newline GROUPS and POSITIONS for cursor STATES."
  (multi-cursor--install-edit-results
   groups positions states nil
   #'multi-cursor--remap-electric-newline-mark))

(defun multi-cursor--electric-newline (record-flag)
  "Apply one bounded electric newline at every native cursor.

RECORD-FLAG controls the single logical command-history entry."
  (multi-cursor--validate-electric-newline-contract)
  (let* ((buffer (current-buffer))
         (options (multi-cursor--electric-newline-options))
         (states (multi-cursor--snapshot-edit-states))
         (original-cursors (copy-sequence multi-cursor--cursors))
         (original-next-id multi-cursor--next-id)
         edits groups planned completed)
    (unwind-protect
        (progn
          (save-restriction
            (atomic-change-group
              (let ((context (multi-cursor--callback-context)))
                (setq edits
                      (mapcar
                       (lambda (state)
                         (save-excursion
                           (multi-cursor--electric-newline-state-edit state)))
                       states))
                (multi-cursor--validate-callback-state context)
                (multi-cursor--validate-electric-newline-options options)
                (setq groups (multi-cursor--merge-edits edits t)
                      planned t)))))
      (unless planned
        (multi-cursor--restore-electric-newline-failure
         options buffer states original-cursors original-next-id)))
    (unwind-protect
        (progn
          (save-restriction
            (multi-cursor--apply-edit-transaction
             states groups
             (lambda (edit-groups positions edit-states)
               (multi-cursor--validate-electric-newline-options options)
               (multi-cursor--install-electric-newline-results
                edit-groups positions edit-states))))
          (setq completed t))
      (unless completed
        (multi-cursor--restore-electric-newline-failure
         options buffer states original-cursors original-next-id)))
    (when record-flag
      (add-to-history 'command-history '(newline nil 1) nil t))))

(defun multi-cursor--newline
    (command prefix _keys record-flag _special)
  "Insert one guarded newline for COMMAND at every native cursor.

PREFIX is rejected.  RECORD-FLAG controls recording in the variable
`command-history'."
  (unless (eq command 'newline)
    (error "Invalid multiple-cursor newline command: %S" command))
  (when prefix
    (user-error "Prefix newline is not multiple-cursor safe yet"))
  (when (minibufferp)
    (user-error "Newline is not multiple-cursor safe in a minibuffer"))
  (when (or mark-active
            (cl-some #'multi-cursor--cursor-mark-active
                     multi-cursor--cursors))
    (user-error "Newline with active selections is not supported yet"))
  (when overwrite-mode
    (user-error "Overwrite-mode newline is not multiple-cursor safe"))
  (when abbrev-mode
    (user-error "Abbrev-mode newline is not multiple-cursor safe"))
  (when auto-fill-function
    (user-error "Auto-fill newline is not multiple-cursor safe"))
  (when use-hard-newlines
    (user-error "Hard newline insertion is not multiple-cursor safe"))
  (when translation-table-for-input
    (user-error "Translated newline input is not multiple-cursor safe"))
  ;; Electric indentation is admitted only by the explicit bounded planner.
  (unless (multi-cursor--newline-post-hook-safe-p post-self-insert-hook)
    (user-error "Custom newline insertion hooks are not multiple-cursor safe"))
  (if (bound-and-true-p electric-indent-mode)
      (multi-cursor--electric-newline record-flag)
    (progn
  (let ((newline-overwrite-mode overwrite-mode)
        (newline-abbrev-mode abbrev-mode)
        (newline-auto-fill-function auto-fill-function)
        (newline-use-hard-newlines use-hard-newlines)
        (newline-electric-indent-mode
         (bound-and-true-p electric-indent-mode))
        (newline-translation-table translation-table-for-input)
        (newline-delete-active-region delete-active-region)
        (newline-left-margin left-margin)
        (newline-post-hook (copy-tree post-self-insert-hook)))
    (let* ((states (multi-cursor--snapshot-edit-states))
           (original-cursors (copy-sequence multi-cursor--cursors))
           (original-next-id multi-cursor--next-id)
           edits groups planned)
      (unwind-protect
          (save-current-buffer
            (save-restriction
              (let ((overwrite-mode newline-overwrite-mode)
                    (abbrev-mode newline-abbrev-mode)
                    (auto-fill-function newline-auto-fill-function)
                    (use-hard-newlines newline-use-hard-newlines)
                    (electric-indent-mode newline-electric-indent-mode)
                    (translation-table-for-input newline-translation-table)
                    (delete-active-region newline-delete-active-region)
                    (left-margin newline-left-margin)
                    (post-self-insert-hook (copy-tree newline-post-hook)))
                (atomic-change-group
                  (let ((context (multi-cursor--callback-context)))
                    (dolist (state states)
                      (save-excursion
                        (let ((position
                               (multi-cursor--edit-state-point state)))
                          (goto-char position)
                          (save-restriction
                            (widen)
                            (when
                                (or (and (> position (point-min))
                                         (text-properties-at (1- position)))
                                    (and (< position (point-max))
                                         (text-properties-at position)))
                              (user-error
                               "Newline next to text properties is not multiple-cursor safe"))))
                        (unless (zerop (current-left-margin))
                          (user-error
                           "Newline with a left margin is not multiple-cursor safe"))))
                    (setq edits
                          (mapcar
                           (lambda (state)
                             (multi-cursor--state-edit
                              state 'self-insert-command 1 "\n"))
                           states))
                    (multi-cursor--validate-callback-state context)
                    (unless
                        (and (eq overwrite-mode newline-overwrite-mode)
                             (eq abbrev-mode newline-abbrev-mode)
                             (eq auto-fill-function
                                 newline-auto-fill-function)
                             (eq use-hard-newlines
                                 newline-use-hard-newlines)
                             (eq electric-indent-mode
                                 newline-electric-indent-mode)
                             (eq translation-table-for-input
                                 newline-translation-table)
                             (eq delete-active-region
                                 newline-delete-active-region)
                             (equal left-margin newline-left-margin)
                             (equal post-self-insert-hook newline-post-hook))
                      (error "Newline planning changed guarded options"))
                    (setq groups (multi-cursor--merge-edits edits)
                          planned t))))))
        (unless planned
          (multi-cursor--restore-edit-states
           states original-cursors original-next-id)
          (unless multi-cursor-mode
            (setq multi-cursor-mode t)
            (multi-cursor--start))))
      (multi-cursor--apply-edit-transaction states groups))
    (when record-flag
      (add-to-history 'command-history '(newline nil 1) nil t))))))

(defun multi-cursor--open-line-reject-properties (position)
  "Reject unsafe insertion properties immediately around POSITION.

`open-line' must preserve the ordinary boundary behavior of an insertion,
but this bounded implementation deliberately does not emulate arbitrary text
property stickiness.  Check both sides in the physical buffer, including
read-only overlay properties, before planning the literal newline."
  (save-restriction
    (widen)
    (dolist (boundary (list (1- position) position))
      (when (and (<= (point-min) boundary)
                 (< boundary (point-max))
                 (or (text-properties-at boundary)
                     (multi-cursor--read-only-value-blocks-p
                      (get-char-property boundary 'read-only))))
        (user-error
         "Open line next to text properties is not multiple-cursor safe")))))

(defun multi-cursor--open-line-state-edit (state)
  "Plan one literal `open-line' insertion for detached cursor STATE."
  (let ((position (multi-cursor--edit-state-point state)))
    (save-excursion
      (goto-char position)
      (unless (zerop (current-left-margin))
        (user-error
         "Open line with a left margin is not multiple-cursor safe")))
    (multi-cursor--open-line-reject-properties position)
    (multi-cursor--preflight-edit-range position position position position)
    (multi-cursor--edit-create
     :beg position :end position :string "\n" :survivor state
     :members (list state))))

(defun multi-cursor--install-open-line-results (groups positions states)
  "Install GROUPS and STATES after `open-line', leaving points before newlines.

POSITIONS are deliberately passed unchanged to the ordinary installer first:
inactive marks must be remapped against each edit's *final end*, not against
the point-before-newline locations used by this command.  Once mark remapping
is complete, move every surviving cursor back over its inserted newline."
  (multi-cursor--install-edit-results groups positions states)
  (cl-mapc
   (lambda (group position)
     (let* ((survivor (multi-cursor--edit-survivor group))
            (point (- position
                      (length (multi-cursor--edit-string group)))))
       (if (multi-cursor--edit-state-primary survivor)
           (goto-char point)
         (set-marker
          (multi-cursor--cursor-point
           (multi-cursor--edit-state-cursor survivor))
          point (current-buffer)))))
   groups positions)
  ;; Moving the marker-only points can change their buffer order.
  (setq multi-cursor--redisplay-snapshot-dirty-p t)
  (multi-cursor--normalize))

(defun multi-cursor--open-line-reject-duplicate-positions (edits)
  "Reject EDITS which would insert more than one newline at a position.

Native cursor records may differ only in inactive mark state while sharing a
point.  The batched primitive intentionally rejects two replacements with the
same start, so detect that shape during planning and leave the buffer and the
session unchanged."
  (let ((positions (make-hash-table :test #'eql)))
    (dolist (edit edits)
      (let ((position (multi-cursor--edit-beg edit)))
        (when (gethash position positions)
          (user-error
           "Open line at duplicate cursor positions is not supported yet"))
        (puthash position t positions)))))

(defun multi-cursor--open-line
    (command prefix _keys record-flag _special)
  "Open one bounded literal line at every native cursor.

Only the stock, one-newline behavior is implemented.  COMMAND must be
`open-line'.  PREFIX is the raw
interactive prefix and RECORD-FLAG controls the single `command-history' entry.
This is bounded literal C-o behavior: it intentionally bypasses abbreviation,
electric-indent, auto-fill, and overwrite-mode postprocessing rather than
replaying the full `open-line' command independently at every cursor."
  (unless (eq command 'open-line)
    (error "Invalid multiple-cursor open-line command: %S" command))
  (unless (or (null prefix) (equal prefix 1))
    (user-error "Open line accepts only one newline in a multiple-cursor session"))
  (when (minibufferp)
    (user-error "Open line is not multiple-cursor safe in a minibuffer"))
  (when (or mark-active
            (cl-some #'multi-cursor--cursor-mark-active
                     multi-cursor--cursors))
    (user-error "Open line with active selections is not supported yet"))
  (when fill-prefix
    (user-error "Open line with a fill prefix is not multiple-cursor safe"))
  (when use-hard-newlines
    (user-error "Hard open-line insertion is not multiple-cursor safe"))
  (when translation-table-for-input
    (user-error "Translated open-line input is not multiple-cursor safe"))
  (let* ((states (multi-cursor--snapshot-edit-states))
         (original-cursors (copy-sequence multi-cursor--cursors))
         (original-next-id multi-cursor--next-id)
         edits groups planned)
    (unwind-protect
        (save-current-buffer
          (save-restriction
            (atomic-change-group
              (let ((context (multi-cursor--callback-context)))
                (setq edits
                      (mapcar #'multi-cursor--open-line-state-edit states))
                (multi-cursor--validate-callback-state context)
                ;; Keep adjacent insertions distinct.  Identical starts are
                ;; rejected explicitly: the batch primitive forbids them.
                (multi-cursor--open-line-reject-duplicate-positions edits)
                (setq groups (multi-cursor--merge-edits edits t)
                      planned t)))))
      (unless planned
        (multi-cursor--restore-edit-states
         states original-cursors original-next-id)
        (unless multi-cursor-mode
          (setq multi-cursor-mode t)
          (multi-cursor--start))))
    (multi-cursor--apply-edit-transaction
     states groups #'multi-cursor--install-open-line-results))
  (when record-flag
    (add-to-history 'command-history '(open-line 1) nil t)))

(defun multi-cursor--character-delete
    (command prefix _keys record-flag _special)
  "Safely apply an ordinary no-prefix character deletion COMMAND.

PREFIX is rejected because ordinary interactive prefixes also request kill
semantics.  RECORD-FLAG controls command-history recording."
  (unless (memq command '(delete-backward-char delete-forward-char))
    (error "Invalid multiple-cursor character deletion: %S" command))
  (when prefix
    (user-error "Prefix deletion is not multiple-cursor safe yet"))
  (when (and (eq command 'delete-backward-char) overwrite-mode)
    (user-error
     "Overwrite-mode backward deletion is not multiple-cursor safe"))
  (let ((delete-policy delete-active-region))
    (when (and (eq delete-policy 'kill)
               (or (and mark-active (mark t) (/= (point) (mark t)))
                   (cl-some
                    (lambda (cursor)
                      (and (multi-cursor--cursor-mark-active cursor)
                           (multi-cursor--cursor-mark cursor)
                           (/= (marker-position
                                (multi-cursor--cursor-point cursor))
                               (marker-position
                                (multi-cursor--cursor-mark cursor)))))
                    multi-cursor--cursors)))
      (user-error
       "Killing active selections is not multiple-cursor safe here"))
    (let* ((states (multi-cursor--snapshot-edit-states))
           (original-cursors (copy-sequence multi-cursor--cursors))
           (original-next-id multi-cursor--next-id)
           edits groups planned)
      ;; Composition discovery can shape text through Lisp callbacks.  Plan
      ;; under an atomic guard and reject any change to text, restriction,
      ;; selection policy, buffer identity, or the cursor session.
      (unwind-protect
          (save-current-buffer
            (save-restriction
              (let ((delete-active-region delete-policy))
                (atomic-change-group
                  (let ((context (multi-cursor--callback-context)))
                    (setq edits
                          (mapcar
                           (lambda (state)
                             (multi-cursor--state-edit
                              state command 1 nil delete-policy))
                           states))
                    (multi-cursor--validate-callback-state context)
                    (unless (eq delete-active-region delete-policy)
                      (error
                       "Deletion planning changed its selection policy"))
                    (setq groups (multi-cursor--merge-edits edits)
                          planned t))))))
        (unless planned
          (multi-cursor--restore-edit-states
           states original-cursors original-next-id)
          (unless multi-cursor-mode
            (setq multi-cursor-mode t)
            (multi-cursor--start))))
      (multi-cursor--apply-edit-transaction states groups))
    (when record-flag
      (add-to-history 'command-history (list command 1) nil t))))

(defun multi-cursor--untabify-delete
    (command prefix _keys record-flag _special)
  "Safely apply no-prefix COMMAND when it is untabifying Backspace.

PREFIX is rejected because an ordinary interactive prefix requests kill
semantics.  RECORD-FLAG controls recording in the variable
`command-history'."
  (unless (eq command 'backward-delete-char-untabify)
    (error "Invalid untabifying deletion command: %S" command))
  (when prefix
    (user-error "Prefix deletion is not multiple-cursor safe yet"))
  (when overwrite-mode
    (user-error
     "Overwrite-mode backward deletion is not multiple-cursor safe"))
  (let ((delete-policy delete-active-region)
        (method backward-delete-char-untabify-method)
        (planning-tab-width tab-width))
    (unless (memq method '(nil untabify hungry all))
      (user-error
       "Unsupported backward-delete-char-untabify method: %S" method))
    (when (and (eq delete-policy 'kill)
               (or (and mark-active (mark t) (/= (point) (mark t)))
                   (cl-some
                    (lambda (cursor)
                      (and (multi-cursor--cursor-mark-active cursor)
                           (multi-cursor--cursor-mark cursor)
                           (/= (marker-position
                                (multi-cursor--cursor-point cursor))
                               (marker-position
                                (multi-cursor--cursor-mark cursor)))))
                    multi-cursor--cursors)))
      (user-error
       "Killing active selections is not multiple-cursor safe here"))
    (let* ((states (multi-cursor--snapshot-edit-states))
           (original-cursors (copy-sequence multi-cursor--cursors))
           (original-next-id multi-cursor--next-id)
           edits groups passive-states planned)
      (unwind-protect
          (save-current-buffer
            (save-restriction
              (let ((delete-active-region delete-policy)
                    (backward-delete-char-untabify-method method)
                    (tab-width planning-tab-width))
                (atomic-change-group
                  (let ((context (multi-cursor--callback-context)))
                    (setq edits
                          (mapcar
                           (lambda (state)
                             (multi-cursor--untabify-state-edit
                              state method delete-policy))
                           states))
                    (multi-cursor--validate-callback-state context)
                    (unless (and (eq delete-active-region delete-policy)
                                 (eq backward-delete-char-untabify-method
                                     method)
                                 (equal tab-width planning-tab-width))
                      (error "Untabifying deletion changed its policy"))
                    (pcase-let
                        ((`(,primitive-edits . ,passive)
                          (multi-cursor--partition-passive-replacement-edits
                           edits)))
                      (setq groups
                            (multi-cursor--merge-edits primitive-edits t)
                            passive-states passive
                            planned t)))))))
        (unless planned
          (multi-cursor--restore-edit-states
           states original-cursors original-next-id)
          (unless multi-cursor-mode
            (setq multi-cursor-mode t)
            (multi-cursor--start))))
      (multi-cursor--apply-edit-transaction
       states groups
       (when passive-states
         (lambda (edits positions edit-states)
           (multi-cursor--install-edit-results
            edits positions edit-states passive-states)))))
    (when record-flag
      (add-to-history 'command-history (list command 1) nil t))))

(defun multi-cursor--invoke-movement (command argument canonical-last-command)
  "Invoke vetted movement COMMAND once, accepting boundary clamping.

ARGUMENT is the prefix converted once for the whole broadcast.
CANONICAL-LAST-COMMAND controls vertical goal-column continuity.
Boundary conditions are local to one cursor: that cursor keeps its clamped
result while the rest of the broadcast proceeds.  Every other signal
propagates so the caller can restore the whole cursor set."
  (let ((last-command
         (if (memq command '(next-line previous-line
                             next-logical-line previous-logical-line))
             (and temporary-goal-column canonical-last-command)
           last-command)))
    (condition-case err
        (if (memq command multi-cursor--argumentless-movement-commands)
            (funcall command)
          (funcall command argument))
      ((beginning-of-buffer end-of-buffer) nil)
      (scan-error
       (unless (memq command multi-cursor--scan-motion-commands)
         (signal (car err) (cdr err)))))))

(defun multi-cursor--movement-handler
    (command prefix _keys record-flag _special)
  "Broadcast ordinary movement COMMAND after rejecting unsafe variants.

PREFIX is the raw command prefix and RECORD-FLAG controls command-history.
Shift selection normally depends on interactive command-loop processing which
cannot yet stage an independent mark for every secondary cursor.
Visual-order horizontal movement and display-line vertical movement depend on
live window glyph geometry, which cannot be staged independently for every
secondary cursor.  A non-nil `goal-column' makes `next-line' and
`previous-line' use logical lines and is therefore safe."
  (when this-command-keys-shift-translated
    (user-error
     "Shift-selection movement is not multiple-cursor safe"))
  (when (and (memq command '(left-char right-char))
             visual-order-cursor-movement)
    (user-error
     "Visual-order arrow movement is not multiple-cursor safe"))
  (when (and (memq command '(next-line previous-line))
             line-move-visual
             (null goal-column))
    (user-error
     "Visual-line arrow movement is not multiple-cursor safe"))
  (let ((current-prefix-arg prefix))
    (multi-cursor--broadcast-movement command record-flag)))

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

(defun multi-cursor--reject-temporary-transient-mark (command)
  "Signal unless ordinary Transient Mark state applies to COMMAND.

The `lambda' and `(only . @dots{})' values are one-command states which
`set-mark-command' clears as a side effect before doing anything else.
Reproducing that for a whole cursor set is not worth its own contract."
  (when (or (eq transient-mark-mode 'lambda)
            (eq (car-safe transient-mark-mode) 'only))
    (user-error "Temporary transient mark is not multiple-cursor safe: %S"
                command)))

(defun multi-cursor--cursor-mark-position (cursor)
  "Return CURSOR's mark position, or nil when it has no mark."
  (let ((mark (multi-cursor--cursor-mark cursor)))
    (and mark (marker-position mark))))

(defun multi-cursor--set-cursor-activation (cursors active)
  "Set every cursor in CURSORS to ACTIVE, retaining its point and mark.

A cursor with no mark has no selection to activate, so it stays inactive:
an active flag without a mark is not a representable cursor state."
  (dolist (cursor cursors)
    (let ((mark (multi-cursor--cursor-mark-position cursor)))
      (multi-cursor--set-record-state
       cursor
       (marker-position (multi-cursor--cursor-point cursor))
       mark
       (and mark active)
       (multi-cursor--cursor-goal-column cursor)))))

(defun multi-cursor--set-mark (command prefix _keys record-flag _special)
  "Set or toggle each cursor's own mark for COMMAND.

Only the two branches of `set-mark-command' which act on the current
position are supported: setting the mark at point, and the repeat
idiom which toggles activation of an existing mark.  PREFIX must be nil,
because every prefixed branch navigates the buffer-global mark ring, which
is not per-cursor state.  RECORD-FLAG controls the variable
`command-history'."
  (when prefix
    (user-error "Prefixed %S is not multiple-cursor safe" command))
  (multi-cursor--reject-temporary-transient-mark command)
  (when (and set-mark-command-repeat-pop
             (memq last-command '(pop-to-mark-command pop-global-mark)))
    (user-error "Repeated mark popping is not multiple-cursor safe"))
  (let ((cursors (multi-cursor--normalized-cursors)))
    (if (eq last-command 'set-mark-command)
        ;; Repeat: toggle activation without moving any mark.
        (if (region-active-p)
            (progn
              (deactivate-mark)
              (multi-cursor--set-cursor-activation cursors nil)
              (message "Mark deactivated"))
          (activate-mark)
          (multi-cursor--set-cursor-activation cursors t)
          (message "Mark activated"))
      ;; Ordinary set.  The primary keeps exact stock behavior, including
      ;; its single mark-ring push; secondary marks are per-cursor state
      ;; and never reach the ring.
      (push-mark-command nil)
      (dolist (cursor cursors)
        (let ((position (marker-position (multi-cursor--cursor-point cursor))))
          (multi-cursor--set-record-state
           cursor position position t
           (multi-cursor--cursor-goal-column cursor)))))
    (setq multi-cursor--redisplay-snapshot-dirty-p t)
    (when record-flag
      (add-to-history 'command-history (list command nil) nil t))
    nil))

(defun multi-cursor--exchange-point-and-mark
    (command prefix _keys record-flag _special)
  "Swap point and mark at every cursor for COMMAND.

Each cursor swaps its own point and mark and retains its own activation
state.  PREFIX must be nil, because the prefixed form of
`exchange-point-and-mark' inverts activation rather than preserving it.
Every cursor is validated before any cursor is changed, so a cursor without
a mark rejects the whole command.  RECORD-FLAG controls the variable
`command-history'."
  (when prefix
    (user-error "Prefixed %S is not multiple-cursor safe" command))
  (multi-cursor--reject-temporary-transient-mark command)
  (let ((cursors (multi-cursor--normalized-cursors)))
    (unless (mark t)
      (user-error "No mark set in this buffer"))
    (dolist (cursor cursors)
      (unless (multi-cursor--cursor-mark cursor)
        (user-error "A secondary cursor has no mark")))
    ;; Every cursor is known good; commit.
    (let ((active (region-active-p))
          (target (mark t)))
      (set-mark (point))
      (goto-char target)
      (unless active (deactivate-mark)))
    (dolist (cursor cursors)
      (multi-cursor--set-record-state
       cursor
       (multi-cursor--cursor-mark-position cursor)
       (marker-position (multi-cursor--cursor-point cursor))
       (multi-cursor--cursor-mark-active cursor)
       (multi-cursor--cursor-goal-column cursor)))
    (multi-cursor--normalize)
    (when record-flag
      (add-to-history 'command-history (list command nil) nil t))
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

(defun multi-cursor--keyboard-quit
    (command _prefix _keys _record-flag _special)
  "Handle COMMAND with the two-stage multiple-cursor quit contract.

The first invocation deactivates every primary and secondary selection while
preserving its mark.  If no selection is active, the invocation ends the
session."
  (unless (eq command 'keyboard-quit)
    (error "Invalid multiple-cursor quit command: %S" command))
  (let ((active-p mark-active))
    (dolist (cursor multi-cursor--cursors)
      (when (multi-cursor--cursor-mark-active cursor)
        (setq active-p t)
        (setf (multi-cursor--cursor-mark-active cursor) nil)))
    (if active-p
        (progn
          (when mark-active
            (deactivate-mark t))
          (setq multi-cursor--redisplay-snapshot-dirty-p t)
          (force-window-update (current-buffer)))
      (multi-cursor-mode -1))))

(defun multi-cursor--remove-lifecycle-hooks ()
  "Remove lifecycle hooks installed for the current buffer."
  (remove-hook 'kill-buffer-hook #'multi-cursor--end-session t)
  (remove-hook 'before-revert-hook #'multi-cursor--end-session t)
  (remove-hook 'change-major-mode-hook #'multi-cursor--end-session t)
  (remove-hook 'pre-command-hook
               #'multi-cursor--record-restriction-before-command t)
  (remove-hook 'post-command-hook
               #'multi-cursor--maybe-remove-inaccessible-cursors t)
  (remove-hook 'after-change-functions
               #'multi-cursor--mark-redisplay-snapshot-dirty t))

(defun multi-cursor--clear ()
  "Release all cursor records and reset the current buffer's session."
  (when (and (window-live-p multi-cursor--presentation-window)
             (eq (window-buffer multi-cursor--presentation-window)
                 (current-buffer)))
    (multi-cursor--set-redisplay-snapshot
     multi-cursor--presentation-window nil))
  (multi-cursor--clear-presentation)
  (multi-cursor--discard-yank-pop-state)
  (mapc #'multi-cursor--release-cursor multi-cursor--cursors)
  (setq multi-cursor--cursors nil
        multi-cursor--next-id 0
        multi-cursor--undo-generations nil
        multi-cursor--redo-generations nil
        multi-cursor--redisplay-snapshot nil
        multi-cursor--redisplay-snapshot-tick nil
        multi-cursor--redisplay-snapshot-dirty-p t)
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
  (unless (local-variable-p 'multi-cursor--undo-generations)
    (setq-local multi-cursor--undo-generations nil))
  (unless (local-variable-p 'multi-cursor--redo-generations)
    (setq-local multi-cursor--redo-generations nil))
  (setq multi-cursor--redisplay-snapshot-dirty-p t)
  (add-hook 'kill-buffer-hook #'multi-cursor--end-session nil t)
  (add-hook 'before-revert-hook #'multi-cursor--end-session nil t)
  (add-hook 'change-major-mode-hook #'multi-cursor--end-session nil t)
  (add-hook 'pre-command-hook
            #'multi-cursor--record-restriction-before-command nil t)
  (add-hook 'post-command-hook
            #'multi-cursor--maybe-remove-inaccessible-cursors nil t)
  (add-hook 'after-change-functions
            #'multi-cursor--mark-redisplay-snapshot-dirty nil t))

;;;###autoload
(define-minor-mode multi-cursor-mode
  "Edit the current buffer using multiple native cursors.

Adding the first secondary cursor enables this buffer-local mode
automatically.  The mode provides no default key bindings.  Commands must
have an explicit multiple-cursor policy; unknown commands fail before they
change the buffer.  Since `execute-extended-command' is unsupported during
a session, bind any management commands needed after the first cursor is
created.  This mode refuses to start while the external
`multiple-cursors-mode' is active; do not enable both modes in one buffer."
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

(defconst multi-cursor--run-once-commands
  '(;; Cursor-set management.  These commands own the session itself, so
    ;; broadcasting them to the cursors they maintain is meaningless.
    multi-cursor-mode
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
    multi-cursor-count
    ;; Prefix-argument accumulation.  The command loop consumes the result
    ;; once, before the dispatcher sees the command it applies to.
    universal-argument
    universal-argument-more
    universal-argument-minus
    universal-argument-other-key
    digit-argument
    negative-argument
    ;; Scrolling, recentering, and display adjustment.  None of these change
    ;; buffer text or any cursor's position within it.
    recenter
    recenter-top-bottom
    scroll-up-command
    scroll-down-command
    scroll-up
    scroll-down
    scroll-left
    scroll-right
    scroll-other-window
    scroll-other-window-down
    mwheel-scroll
    mouse-wheel-text-scale
    move-to-window-line-top-bottom
    redraw-display
    recenter-current-error
    text-scale-adjust
    text-scale-increase
    text-scale-decrease
    toggle-truncate-lines
    visual-line-mode
    display-line-numbers-mode
    ;; Window and frame management.  The session belongs to a buffer, not to
    ;; the window configuration displaying it.
    other-window
    split-window-below
    split-window-right
    split-window-vertically
    split-window-horizontally
    delete-window
    delete-other-windows
    balance-windows
    enlarge-window
    shrink-window
    enlarge-window-horizontally
    shrink-window-horizontally
    other-frame
    make-frame-command
    delete-frame
    toggle-frame-fullscreen
    toggle-frame-maximized
    ;; Buffer and file commands.  Those which replace or kill the buffer end
    ;; the session through the ordinary lifecycle hooks.
    switch-to-buffer
    switch-to-buffer-other-window
    switch-to-buffer-other-frame
    next-buffer
    previous-buffer
    list-buffers
    kill-buffer
    kill-current-buffer
    bury-buffer
    save-buffer
    save-some-buffers
    write-file
    find-file
    find-file-other-window
    find-file-other-frame
    find-alternate-file
    revert-buffer
    ;; Help, documentation, and introspection.
    describe-key
    describe-function
    describe-variable
    describe-mode
    describe-bindings
    describe-char
    help-for-help
    info
    apropos
    apropos-command
    where-is
    view-lossage
    ;; Evaluation.  These run at the primary cursor exactly as they do
    ;; without a session; markers keep every secondary cursor attached.
    eval-expression
    eval-last-sexp
    eval-defun
    eval-region
    eval-buffer)
  "Commands which run once at the primary cursor during a session.

None of these commands edit buffer text at a cursor position, so
broadcasting them would be meaningless rather than merely unsafe.  Commands
which are not preloaded are skipped when this list is applied.")

(dolist (command multi-cursor--run-once-commands)
  (when (commandp command)
    (multi-cursor-register-command command 'run-once)))

(dolist (command multi-cursor--movement-commands)
  (multi-cursor-register-command
   command 'broadcast-movement #'multi-cursor--movement-handler))

(dolist (command '(self-insert-command delete-char))
  (multi-cursor-register-command command 'batch-edit #'multi-cursor--batch-edit))

(multi-cursor-register-command 'newline 'batch-edit #'multi-cursor--newline)

(multi-cursor-register-command
 'open-line 'custom-handler #'multi-cursor--open-line)

(multi-cursor-register-command
 'indent-for-tab-command 'custom-handler #'multi-cursor--literal-tab-handler)

(multi-cursor-register-command
 'newline-and-indent 'custom-handler #'multi-cursor--newline-and-indent)

(dolist (command '(delete-backward-char delete-forward-char))
  (multi-cursor-register-command
   command 'batch-edit #'multi-cursor--character-delete))

(multi-cursor-register-command
 'backward-delete-char-untabify 'batch-edit #'multi-cursor--untabify-delete)

(dolist (command '(kill-region copy-region-as-kill kill-ring-save))
  (multi-cursor-register-command
   command 'custom-handler #'multi-cursor--kill-or-copy))

(dolist (command '(kill-word backward-kill-word))
  (multi-cursor-register-command
   command 'custom-handler #'multi-cursor--word-kill))

(multi-cursor-register-command
 'kill-line 'custom-handler #'multi-cursor--line-kill)

(multi-cursor-register-command 'yank 'batch-edit #'multi-cursor--yank)

(multi-cursor-register-command
 'yank-pop 'custom-handler #'multi-cursor--yank-pop)

(dolist (command '(execute-extended-command execute-kbd-macro
                   isearch-forward isearch-backward
                   query-replace query-replace-regexp
                   beginning-of-visual-line end-of-visual-line))
  (when (commandp command)
    (multi-cursor-register-command command 'unsupported)))

(dolist (command '(undo undo-only undo-redo))
  (when (commandp command)
    (multi-cursor-register-command command 'custom-handler
                                   #'multi-cursor--session-undo)))

(multi-cursor-register-command
 'set-mark-command 'custom-handler #'multi-cursor--set-mark)

(multi-cursor-register-command
 'exchange-point-and-mark 'custom-handler #'multi-cursor--exchange-point-and-mark)

(multi-cursor-register-command
 'keyboard-quit 'custom-handler #'multi-cursor--keyboard-quit)

(provide 'multi-cursor)

;;; multi-cursor.el ends here
