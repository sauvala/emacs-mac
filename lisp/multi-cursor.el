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

(cl-defstruct (multi-cursor--cursor
               (:constructor multi-cursor--cursor-create))
  id point mark mark-active direction goal-column last-yank)

(defvar-local multi-cursor--cursors nil
  "Secondary cursor records owned by the current buffer.")

(defvar-local multi-cursor--next-id 0
  "Next secondary cursor identifier in the current buffer.")

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
        (let ((cursor
               (multi-cursor--cursor-create
                :id (cl-incf multi-cursor--next-id)
                :point (copy-marker point-position)
                :mark (and mark-position (copy-marker mark-position))
                :mark-active active
                :direction direction)))
          (push cursor multi-cursor--cursors)
          (multi-cursor--normalize)
          cursor))))

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

(defun multi-cursor--remove-lifecycle-hooks ()
  "Remove lifecycle hooks installed for the current buffer."
  (remove-hook 'kill-buffer-hook #'multi-cursor--end-session t)
  (remove-hook 'before-revert-hook #'multi-cursor--end-session t)
  (remove-hook 'change-major-mode-hook #'multi-cursor--end-session t))

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
  (add-hook 'change-major-mode-hook #'multi-cursor--end-session nil t))

;;;###autoload
(define-minor-mode multi-cursor-mode
  "Edit the current buffer using multiple native cursors."
  :lighter " MC"
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

(provide 'multi-cursor)

;;; multi-cursor.el ends here
