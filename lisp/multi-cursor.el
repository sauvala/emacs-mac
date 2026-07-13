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
;; later stages; this initial implementation only defines cursor records and
;; their lifecycle.

;;; Code:

(require 'cl-lib)

(defgroup multi-cursor nil
  "Edit a buffer through multiple native cursors."
  :group 'editing)

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
  "Sort secondary cursors and release records with duplicate positions."
  (let (normalized previous)
    (dolist (cursor (sort multi-cursor--cursors
                          #'multi-cursor--cursor-less-p))
      (if (and previous (multi-cursor--same-state-p previous cursor))
          (multi-cursor--release-cursor cursor)
        (push cursor normalized)
        (setq previous cursor)))
    (setq multi-cursor--cursors (nreverse normalized))))

(defun multi-cursor--add-cursor (point mark mark-active)
  "Add a secondary cursor at POINT with MARK and MARK-ACTIVE.

POINT and MARK are positions in the current buffer.  An exact duplicate
point/mark pair reuses the existing cursor record."
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
