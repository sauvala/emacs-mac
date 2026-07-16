;;; multicursor-tests.el --- tests for multicursor.c  -*- lexical-binding: t -*-

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

;;; Code:

(require 'ert)

(ert-deftest multicursor-apply-edits-orders-and-adjusts-results ()
  (with-temp-buffer
    (insert "abcdef")
    ;; Deliberately use caller order rather than buffer order.
    (should (equal (multi-cursor--apply-edits
                    [[5 7 "XY"] [1 1 "Q"] [3 4 "Z"]])
                   [8 2 5]))
    (should (equal (buffer-string) "QabZdXY"))))

(ert-deftest multicursor-apply-edits-accepts-empty-and-adjacent-edits ()
  (with-temp-buffer
    (insert "abcdef")
    (should (equal (multi-cursor--apply-edits []) []))
    (should (equal (multi-cursor--apply-edits [[2 4 "X"] [4 6 "Y"]])
                   [3 4]))
    (should (equal (buffer-string) "aXYf"))))

(ert-deftest multicursor-apply-edits-requires-an-outer-vector ()
  (with-temp-buffer
    (insert "abc")
    (should-error (multi-cursor--apply-edits '([2 3 "X"]))
                  :type 'wrong-type-argument)
    (should (equal (buffer-string) "abc"))))

(ert-deftest multicursor-apply-edits-validates-before-modifying ()
  (dolist (edits '(([5 7 "XY"] [2 4 "x"] [3 5 "y"])
                   ([5 7 "XY"] [2 1 "x"])
                   ([5 7 "XY"] [0 1 "x"])
                   ([5 7 "XY"] [2 3])
                   ([5 7 "XY"] [2 3 4])))
    (with-temp-buffer
      (insert "abcdef")
      (let ((before-change-functions
             (list (lambda (&rest _args)
                     (ert-fail "validation ran a modification hook"))))
            (tick (buffer-chars-modified-tick)))
        (should-error
         (multi-cursor--apply-edits (vconcat edits)))
        (should (equal (buffer-string) "abcdef"))
        (should (= tick (buffer-chars-modified-tick)))))))

(ert-deftest multicursor-apply-edits-rejects-coincident-insertions ()
  (with-temp-buffer
    (insert "abc")
    (should-error (multi-cursor--apply-edits [[2 2 "x"] [2 2 "y"]]))
    (should (equal (buffer-string) "abc"))))

(ert-deftest multicursor-apply-edits-obeys-read-only-text ()
  (with-temp-buffer
    (insert "abcdef")
    (put-text-property 2 4 'read-only t)
    (should-error (multi-cursor--apply-edits [[2 3 "X"]])
                  :type 'text-read-only)
    (should (equal (buffer-string) "abcdef"))))

(ert-deftest multicursor-apply-edits-runs-normal-change-hooks ()
  (with-temp-buffer
    (insert "abcdef")
    (let (events)
      (let ((before-change-functions
             (list (lambda (beg end)
                     (push (list 'before beg end) events))))
            (after-change-functions
             (list (lambda (beg end old-length)
                     (push (list 'after beg end old-length) events)))))
        (multi-cursor--apply-edits [[1 1 "Q"] [5 7 "XY"]]))
      (should (equal (nreverse events)
                     '((before 5 7) (after 5 7 2)
                       (before 1 1) (after 1 2 0)))))))

(ert-deftest multicursor-apply-edits-restores-buffer-after-hook-switch ()
  (let ((other (generate-new-buffer " *multicursor-test*")))
    (unwind-protect
        (with-temp-buffer
          (insert "abcdef")
          (with-current-buffer other
            (insert "uvwxyz"))
          (let ((entry (current-buffer))
                switched)
            (let ((after-change-functions
                   (list (lambda (&rest _args)
                           (unless switched
                             (setq switched t)
                             (set-buffer other))))))
              (should-error
               (multi-cursor--apply-edits [[2 3 "L"] [5 7 "XY"]])))
            (should (eq (current-buffer) entry))
            (should (equal (buffer-string) "abcdXY"))
            (should (equal (with-current-buffer other (buffer-string))
                           "uvwxyz"))))
      (kill-buffer other))))

(ert-deftest multicursor-apply-edits-restores-restriction-after-hook-narrows ()
  (with-temp-buffer
    (insert "abcdef")
    (let ((entry (current-buffer))
          narrowed)
      (let ((after-change-functions
             (list (lambda (&rest _args)
                     (unless narrowed
                       (setq narrowed t)
                       (narrow-to-region 2 6))))))
        (should-error
         (multi-cursor--apply-edits [[2 3 "L"] [5 7 "XY"]])))
      (should (eq (current-buffer) entry))
      (should (= (point-min) 1))
      (should (= (point-max) 7))
      (should (equal (buffer-string) "abcdXY")))))

(ert-deftest multicursor-apply-edits-stops-after-before-hook-switches-buffer ()
  (let ((other (generate-new-buffer " *multicursor-test*")))
    (unwind-protect
        (with-temp-buffer
          (insert "abcdef")
          (with-current-buffer other
            (insert "uvwxyz"))
          (let ((entry (current-buffer))
                switched)
            (let ((before-change-functions
                   (list (lambda (&rest _args)
                           (unless switched
                             (setq switched t)
                             (set-buffer other))))))
              (should-error
               (multi-cursor--apply-edits [[2 3 "L"] [5 7 "XY"]])))
            (should (eq (current-buffer) entry))
            (should (equal (buffer-string) "abcdef"))
            (should (equal (with-current-buffer other (buffer-string))
                           "uvwxyz"))))
      (kill-buffer other))))

(ert-deftest multicursor-apply-edits-stops-after-before-hook-narrows ()
  (with-temp-buffer
    (insert "abcdef")
    (let (narrowed)
      (let ((before-change-functions
             (list (lambda (&rest _args)
                     (unless narrowed
                       (setq narrowed t)
                       (narrow-to-region 2 6))))))
        (should-error
         (multi-cursor--apply-edits [[2 3 "L"] [5 7 "XY"]])))
      (should (= (point-min) 1))
      (should (= (point-max) 7))
      (should (equal (buffer-string) "abcdef")))))

(ert-deftest multicursor-apply-edits-caches-strings-before-hooks ()
  (with-temp-buffer
    (insert "abcdef")
    (let ((edits [[1 2 "L"] [5 7 "XY"]])
          mutated)
      (let ((before-change-functions
             (list (lambda (&rest _args)
                     (unless mutated
                       (setq mutated t)
                       (aset (aref edits 0) 2 "bad")
                       (aset (aref edits 1) 2 "bad"))))))
        (multi-cursor--apply-edits edits))
      (should (equal (buffer-string) "LbcdXY")))))

(ert-deftest multicursor-apply-edits-no-op-does-not-modify ()
  (with-temp-buffer
    (insert "abc")
    (let ((tick (buffer-chars-modified-tick))
          (before-change-functions
           (list (lambda (&rest _args)
                   (ert-fail "no-op ran a modification hook")))))
      (should (equal (multi-cursor--apply-edits [[2 2 ""]]) [2]))
      (should (= tick (buffer-chars-modified-tick)))
      (should (equal (buffer-string) "abc")))))

(ert-deftest multicursor-apply-edits-direct-call-can-partially-modify ()
  (with-temp-buffer
    (insert "abcdef")
    (put-text-property 2 3 'read-only t)
    ;; The high edit precedes the failing low edit.  Transaction rollback is
    ;; intentionally the responsibility of the Lisp caller.
    (should-error
     (multi-cursor--apply-edits [[2 3 "L"] [5 7 "XY"]])
     :type 'text-read-only)
    (should (equal (buffer-substring-no-properties 1 (point-max))
                   "abcdXY"))))

(ert-deftest multicursor-apply-edits-preserves-fields-and-string-properties ()
  (with-temp-buffer
    (insert (propertize "abcdef" 'field 'old))
    (let ((replacement (propertize "XY" 'field 'new 'face 'bold)))
      (multi-cursor--apply-edits (vector (vector 3 5 replacement))))
    (should (equal (buffer-string) "abXYef"))
    (should (eq (get-text-property 2 'field) 'old))
    (should (eq (get-text-property 3 'field) 'new))
    (should (eq (get-text-property 4 'face) 'bold))
    (should (eq (get-text-property 5 'field) 'old))))

(ert-deftest multicursor-apply-edits-handles-multibyte-strings ()
  (with-temp-buffer
    (insert "aλc")
    (let ((replacement (propertize "界é" 'multicursor-test t)))
      (should (equal (multi-cursor--apply-edits
                      (vector (vector 2 3 replacement)))
                     [4])))
    (should (equal (buffer-string) "a界éc"))
    (should (get-text-property 2 'multicursor-test))
    (should (get-text-property 3 'multicursor-test))))

(ert-deftest multicursor-apply-edits-checks-for-quit-before-modifying ()
  (with-temp-buffer
    (insert "abcdef")
    (let ((caught
           (condition-case nil
               (progn
                 ;; Set this inside the handler so ERT cannot consume the
                 ;; pending quit before the primitive starts validating.
                 (setq quit-flag t)
                 (multi-cursor--apply-edits [[2 3 "X"]])
                 nil)
             (quit t))))
      (should caught))
    (should (equal (buffer-string) "abcdef"))))

(provide 'multicursor-tests)

;;; multicursor-tests.el ends here
