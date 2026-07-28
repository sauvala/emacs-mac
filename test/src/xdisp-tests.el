;;; xdisp-tests.el --- tests for xdisp.c functions -*- lexical-binding: t -*-

;; Copyright (C) 2020-2026 Free Software Foundation, Inc.

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

(defmacro xdisp-tests--in-minibuffer (&rest body)
  (declare (debug t) (indent 0))
  `(catch 'result
     (minibuffer-with-setup-hook
         (lambda ()
           (let ((redisplay-skip-initial-frame nil)
                 (executing-kbd-macro nil)) ;Don't skip redisplay
             (throw 'result (progn . ,body))))
       (let ((executing-kbd-macro t)) ;Force real minibuffer in `read-string'.
         (read-string "toto: ")))))

(ert-deftest xdisp-tests--minibuffer-resizing () ;; bug#43519
  (should
   (equal
    t
    (xdisp-tests--in-minibuffer
      (insert "hello")
      (let ((ol (make-overlay (point) (point)))
            (max-mini-window-height 1)
            (text (copy-sequence "askdjfhaklsjdfhlkasjdfhklasdhflkasdhflkajsdhflkashdfkljahsdlfkjahsdlfkjhasldkfhalskdjfhalskdfhlaksdhfklasdhflkasdhflkasdhflkajsdhklajsdgh")))
        ;; (save-excursion (insert text))
        ;; (sit-for 2)
        ;; (delete-region (point) (point-max))
        (put-text-property 0 1 'cursor t text)
        (overlay-put ol 'after-string text)
        (redisplay 'force)
        ;; Make sure we do the see "hello" text.
        (prog1 (equal (window-start) (point-min))
          ;; (list (window-start) (window-end) (window-width))
          (delete-overlay ol)))))))

(ert-deftest xdisp-tests--minibuffer-scroll () ;; bug#44070
  (let ((posns
         (xdisp-tests--in-minibuffer
           (let ((max-mini-window-height 4))
             (dotimes (_ 80) (insert "\nhello"))
             (goto-char (point-min))
             (redisplay 'force)
             (goto-char (point-max))
             ;; A simple edit like removing the last `o' shouldn't cause
             ;; the rest of the minibuffer's text to move.
             (list
              (progn (redisplay 'force) (window-start))
              (progn (delete-char -1)
                     (redisplay 'force) (window-start))
              (progn (goto-char (point-min)) (redisplay 'force)
                     (goto-char (point-max)) (redisplay 'force)
                     (window-start)))))))
    (should (equal (nth 0 posns) (nth 1 posns)))
    (should (equal (nth 1 posns) (nth 2 posns)))))

(ert-deftest xdisp-tests--window-text-pixel-size () ;; bug#45748
  (with-temp-buffer
    (insert "xxx")
    (switch-to-buffer (current-buffer))
    (let* ((char-width (frame-char-width))
           (size (window-text-pixel-size nil t t))
           (width-in-chars (/ (car size) char-width)))
      (should (equal width-in-chars 3)))))

(ert-deftest xdisp-tests--window-text-pixel-size-leading-space () ;; bug#45748
  (with-temp-buffer
    (insert " xx")
    (switch-to-buffer (current-buffer))
    (let* ((char-width (frame-char-width))
           (size (window-text-pixel-size nil t t))
           (width-in-chars (/ (car size) char-width)))
      (should (equal width-in-chars 3)))))

(ert-deftest xdisp-tests--window-text-pixel-size-trailing-space () ;; bug#45748
  (with-temp-buffer
    (insert "xx ")
    (switch-to-buffer (current-buffer))
    (let* ((char-width (frame-char-width))
           (size (window-text-pixel-size nil t t))
           (width-in-chars (/ (car size) char-width)))
      (should (equal width-in-chars 3)))))

(ert-deftest xdisp-tests--find-directional-overrides-case-1 ()
  (with-temp-buffer
    (insert "\
int main() {
  bool isAdmin = false;
  /*‮ }⁦if (isAdmin)⁩ ⁦ begin admins only */
  printf(\"You are an admin.\\n\");
  /* end admins only ‮ { ⁦*/
  return 0;
}")
    (goto-char (point-min))
    (should (eq (bidi-find-overridden-directionality (point-min) (point-max)
                                                     nil)
                46))))

(ert-deftest xdisp-tests--find-directional-overrides-case-2 ()
  (with-temp-buffer
    (insert "\
#define is_restricted_user(user)			\\
  !strcmp (user, \"root\") ? 0 :			\\
  !strcmp (user, \"admin\") ? 0 :			\\
  !strcmp (user, \"superuser‮⁦? 0 : 1⁩ ⁦\")⁩‬

int main () {
  printf (\"root: %d\\n\", is_restricted_user (\"root\"));
  printf (\"admin: %d\\n\", is_restricted_user (\"admin\"));
  printf (\"superuser: %d\\n\", is_restricted_user (\"superuser\"));
  printf (\"luser: %d\\n\", is_restricted_user (\"luser\"));
  printf (\"nobody: %d\\n\", is_restricted_user (\"nobody\"));
}")
    (goto-char (point-min))
    (should (eq (bidi-find-overridden-directionality (point-min) (point-max)
                                                     nil)
                138))))

(ert-deftest xdisp-tests--find-directional-overrides-case-3 ()
  (with-temp-buffer
    (insert "\
#define is_restricted_user(user)			\\
  !strcmp (user, \"root\") ? 0 :			\\
  !strcmp (user, \"admin\") ? 0 :			\\
  !strcmp (user, \"superuser‮⁦? '#' : '!'⁩ ⁦\")⁩‬

int main () {
  printf (\"root: %d\\n\", is_restricted_user (\"root\"));
  printf (\"admin: %d\\n\", is_restricted_user (\"admin\"));
  printf (\"superuser: %d\\n\", is_restricted_user (\"superuser\"));
  printf (\"luser: %d\\n\", is_restricted_user (\"luser\"));
  printf (\"nobody: %d\\n\", is_restricted_user (\"nobody\"));
}")
    (goto-char (point-min))
    (should (eq (bidi-find-overridden-directionality (point-min) (point-max)
                                                     nil)
                138))))

(ert-deftest test-get-display-property ()
  (with-temp-buffer
    (insert (propertize "foo" 'face 'bold 'display '(height 2.0)))
    (should (equal (get-display-property 2 'height) 2.0)))
  (with-temp-buffer
    (insert (propertize "foo" 'face 'bold 'display '((height 2.0)
                                                     (space-width 2.0))))
    (should (equal (get-display-property 2 'height) 2.0))
    (should (equal (get-display-property 2 'space-width) 2.0)))
  (with-temp-buffer
    (insert (propertize "foo bar" 'face 'bold
                        'display '[(height 2.0)
                                   (space-width 20)]))
    (should (equal (get-display-property 2 'height) 2.0))
    (should (equal (get-display-property 2 'space-width) 20))))

(ert-deftest test-messages-buffer-name ()
  (should
   (equal
    (let ((messages-buffer-name "test-message"))
      (message "foo")
      (with-current-buffer messages-buffer-name
        (buffer-string)))
    "foo\n")))

(ert-deftest xdisp-tests--long-line-redisplay-preserves-bidi-setting ()
  "Long-line redisplay should not mutate `bidi-display-reordering'."
  (let ((old-buffer (window-buffer)))
    (unwind-protect
        (with-temp-buffer
          (setq-local bidi-display-reordering t)
          (let ((long-line-threshold 10)
                (redisplay-skip-initial-frame nil))
            (dotimes (_ 20)
              (insert "xxxxx"))
            (switch-to-buffer (current-buffer))
            (redisplay 'force)
            (should (long-line-optimizations-p))
            (should (eq bidi-display-reordering t))))
      (when (buffer-live-p old-buffer)
        (switch-to-buffer old-buffer)))))

(ert-deftest xdisp-test-format-mode-line ()
  ;; 'format-mode-line' returns an empty string with no properties in
  ;; noninteractive sessions.
  (skip-when noninteractive)
  (with-temp-buffer
    (insert (format-mode-line " " t))
    (should (equal (buffer-string) #(" " 0 1 (face mode-line-active)))))
  (with-temp-buffer
    (insert (format-mode-line
             (propertize "x" 'face 'bold-italic)
             1200000000000000000000000000))
    (should (null (get-text-property 1 'face))))
  (should
   (equal
    (text-properties-at
     0
     (format-mode-line '((:propertize "Hello!" face bold)) 'mode-line))
    (list 'face '(bold mode-line) 'mode-line-elt-no 3)))
  (with-temp-buffer
    ;; This test is due to Markus Triska <triska@metalevel.at>.
    (let ((m1 (format-mode-line mode-line-format nil))
	  (m2 (format-mode-line mode-line-format 'default))
	  s1 s2)
      (font-lock-mode 0)
      (insert "\n")
      (insert m1)
      (setq s1 (window-text-pixel-size nil (line-beginning-position) (point)))
      (insert "\n")
      (insert m2)
      (setq s2 (window-text-pixel-size nil (line-beginning-position) (point)))
      (should (equal m1 m2)))))


;;; Indentation guides

(defun xdisp-tests--guide-stops (text pos)
  "Return guide stops for the line containing POS in a buffer with TEXT."
  (with-temp-buffer
    (insert text)
    (setq-local display-indent-guides t)
    (setq-local display-indent-guides-spacing 4)
    (setq-local display-indent-guides-offset 0)
    (setq-local tab-width 8)
    (internal--indent-guide-stops pos)))

(ert-deftest xdisp-tests--indent-guide-stops-none ()
  "A line with no indentation has no guides."
  (should (equal (xdisp-tests--guide-stops "foo\n" 1) nil)))

(ert-deftest xdisp-tests--indent-guide-stops-one ()
  "Four columns of indentation give one guide, at column 0."
  (should (equal (xdisp-tests--guide-stops "    foo\n" 1) '((0 . 1)))))

(ert-deftest xdisp-tests--indent-guide-stops-three ()
  "Twelve columns of indentation give three guides."
  (should (equal (xdisp-tests--guide-stops "            foo\n" 1)
                 '((0 . 1) (4 . 2) (8 . 3)))))

(ert-deftest xdisp-tests--indent-guide-stops-partial ()
  "Indentation that does not land on a stop still yields the passed stops."
  (should (equal (xdisp-tests--guide-stops "      foo\n" 1)
                 '((0 . 1) (4 . 2)))))

(ert-deftest xdisp-tests--indent-guide-stops-tabs ()
  "A tab expands by `tab-width' when measuring indentation."
  (should (equal (xdisp-tests--guide-stops "\tfoo\n" 1)
                 '((0 . 1) (4 . 2)))))

(ert-deftest xdisp-tests--indent-guide-stops-offset ()
  "`display-indent-guides-offset' shifts the first stop."
  (with-temp-buffer
    (insert "        foo\n")
    (setq-local display-indent-guides t)
    (setq-local display-indent-guides-spacing 4)
    (setq-local display-indent-guides-offset 2)
    (should (equal (internal--indent-guide-stops 1) '((2 . 1) (6 . 2))))))

(ert-deftest xdisp-tests--indent-guide-stops-disabled ()
  "No guides when the feature is off in this buffer."
  (with-temp-buffer
    (insert "        foo\n")
    (setq-local display-indent-guides nil)
    (should (equal (internal--indent-guide-stops 1) nil))))

(ert-deftest xdisp-tests--indent-guide-stops-max-depth ()
  "`display-indent-guides-max-depth' caps the number of guides."
  (with-temp-buffer
    (insert (make-string 40 ?\s) "foo\n")
    (setq-local display-indent-guides t)
    (setq-local display-indent-guides-spacing 4)
    (setq-local display-indent-guides-offset 0)
    (setq-local display-indent-guides-max-depth 3)
    (should (equal (internal--indent-guide-stops 1)
                   '((0 . 1) (4 . 2) (8 . 3))))))

(ert-deftest xdisp-tests--indent-guide-stops-bad-spacing ()
  "A nonsensical spacing degrades to no guides rather than signalling."
  (with-temp-buffer
    (insert "        foo\n")
    (setq-local display-indent-guides t)
    (setq-local display-indent-guides-spacing 0)
    (should (equal (internal--indent-guide-stops 1) nil))))

(defun xdisp-tests--guide-stops-blank (text pos)
  "Return guide stops for TEXT at POS with blank-line guides enabled."
  (with-temp-buffer
    (insert text)
    (setq-local display-indent-guides t)
    (setq-local display-indent-guides-spacing 4)
    (setq-local display-indent-guides-offset 0)
    (setq-local display-indent-guides-blank-lines t)
    (setq-local tab-width 8)
    (internal--indent-guide-stops pos)))

(ert-deftest xdisp-tests--indent-guide-blank-between ()
  "A blank line between two indented lines takes the deeper context."
  ;; Line 2 is blank; neighbours are indented 4 and 8 columns.
  (should (equal (xdisp-tests--guide-stops-blank "    a\n\n        b\n" 7)
                 '((0 . 1) (4 . 2)))))

(ert-deftest xdisp-tests--indent-guide-blank-run ()
  "All lines of a blank run get the same context."
  (let ((text "        a\n\n\n\n    b\n"))
    ;; Positions 11, 12 and 13 are the three blank lines.
    (should (equal (xdisp-tests--guide-stops-blank text 11)
                   '((0 . 1) (4 . 2))))
    (should (equal (xdisp-tests--guide-stops-blank text 12)
                   '((0 . 1) (4 . 2))))
    (should (equal (xdisp-tests--guide-stops-blank text 13)
                   '((0 . 1) (4 . 2))))))

(ert-deftest xdisp-tests--indent-guide-blank-at-bob ()
  "A blank line with no previous non-blank line uses the following one."
  (should (equal (xdisp-tests--guide-stops-blank "\n        b\n" 1)
                 '((0 . 1) (4 . 2)))))

(ert-deftest xdisp-tests--indent-guide-blank-at-eob ()
  "A blank line with no following non-blank line uses the previous one."
  (should (equal (xdisp-tests--guide-stops-blank "        a\n\n" 11)
                 '((0 . 1) (4 . 2)))))

(ert-deftest xdisp-tests--indent-guide-blank-disabled ()
  "With blank-line guides off, a blank line has no guides."
  (with-temp-buffer
    (insert "        a\n\n        b\n")
    (setq-local display-indent-guides t)
    (setq-local display-indent-guides-spacing 4)
    (setq-local display-indent-guides-offset 0)
    (setq-local display-indent-guides-blank-lines nil)
    (should (equal (internal--indent-guide-stops 11) nil))))

(ert-deftest xdisp-tests--indent-guide-whitespace-only-line ()
  "A line of only whitespace counts as blank, not as indentation."
  ;; Line 2 holds two spaces; context from neighbours is 8 columns deep.
  (should (equal (xdisp-tests--guide-stops-blank "        a\n  \n        b\n" 11)
                 '((0 . 1) (4 . 2)))))

(ert-deftest xdisp-tests--indent-guide-scope-caps-depth ()
  "Lines inside a scope range are capped at the scope depth."
  (with-temp-buffer
    (insert "                a\n")
    (setq-local display-indent-guides t)
    (setq-local display-indent-guides-spacing 4)
    (setq-local display-indent-guides-offset 0)
    ;; Without a scope, 16 columns give four guides.
    (should (equal (internal--indent-guide-stops 1)
                   '((0 . 1) (4 . 2) (8 . 3) (12 . 4))))
    ;; Cap depth at 2 for the whole buffer.
    (setq-local display-indent-guides-scope (vector 2 (point-min) (point-max)))
    (should (equal (internal--indent-guide-stops 1)
                   '((0 . 1) (4 . 2))))))

(ert-deftest xdisp-tests--indent-guide-scope-outside-range ()
  "Lines outside every scope range are not capped."
  (with-temp-buffer
    (insert "                a\n                b\n")
    (setq-local display-indent-guides t)
    (setq-local display-indent-guides-spacing 4)
    (setq-local display-indent-guides-offset 0)
    ;; Cap applies only to the first line.
    (setq-local display-indent-guides-scope (vector 1 1 19))
    (should (equal (internal--indent-guide-stops 1) '((0 . 1))))
    (should (equal (internal--indent-guide-stops 20)
                   '((0 . 1) (4 . 2) (8 . 3) (12 . 4))))))

(ert-deftest xdisp-tests--indent-guide-scope-malformed ()
  "A malformed scope value is ignored rather than signalling."
  (with-temp-buffer
    (insert "                a\n")
    (setq-local display-indent-guides t)
    (setq-local display-indent-guides-spacing 4)
    (setq-local display-indent-guides-offset 0)
    (dolist (bad (list "not a vector" (vector) (vector 'x 1 2) (vector 2 1)))
      (setq-local display-indent-guides-scope bad)
      (should (equal (internal--indent-guide-stops 1)
                     '((0 . 1) (4 . 2) (8 . 3) (12 . 4)))))))

(ert-deftest xdisp-tests--indent-guides-character-default ()
  "The text-terminal guide character defaults to a box-drawing bar."
  (should (equal display-indent-guides-character
                 ?\N{BOX DRAWINGS LIGHT VERTICAL})))

(ert-deftest xdisp-tests--indent-guides-character-settable ()
  "The text-terminal guide character is buffer-local and settable."
  (with-temp-buffer
    (setq-local display-indent-guides-character ?|)
    (should (equal display-indent-guides-character ?|))
    (should (local-variable-p 'display-indent-guides-character))))

(defun xdisp-tests--positions-across-line (buffer-text)
  "Return the buffer positions `posn-at-x-y' reports across line 1.
Renders BUFFER-TEXT in a temporary window and samples every column."
  (let ((buf (generate-new-buffer " *guide-test*")))
    (unwind-protect
        (with-current-buffer buf
          (insert buffer-text)
          (set-window-buffer (selected-window) buf)
          (goto-char (point-min))
          (redisplay t)
          (let ((res nil)
                (h (line-pixel-height)))
            (dotimes (col 20)
              (push (posn-point
                     (posn-at-x-y (* col (frame-char-width)) (/ h 2)))
                    res))
            (nreverse res)))
      (kill-buffer buf))))

;; These tests need real redisplay, so they only run in a GUI session.
;; The same properties are checked from the shell by
;; test/manual/indent-guides-probe.sh, which reads the glyph matrix
;; directly and can assert on guide columns and depths as well.

(ert-deftest xdisp-tests--indent-guides-preserve-positions ()
  "Enabling guides must not change where a column maps to in the buffer."
  (skip-unless (not noninteractive))
  (let* ((text "        foo\n        bar\n")
         (without (let ((display-indent-guides nil))
                    (xdisp-tests--positions-across-line text)))
         (with (let ((display-indent-guides t)
                     (display-indent-guides-spacing 4)
                     (display-indent-guides-offset 0))
                 (xdisp-tests--positions-across-line text))))
    (should (equal without with))))

(ert-deftest xdisp-tests--indent-guides-preserve-positions-tabs ()
  "Guides inside tab indentation must not change buffer positions."
  (skip-unless (not noninteractive))
  (let* ((text "\t\tfoo\n\t\tbar\n")
         (without (let ((display-indent-guides nil))
                    (xdisp-tests--positions-across-line text)))
         (with (let ((display-indent-guides t)
                     (display-indent-guides-spacing 4)
                     (display-indent-guides-offset 0))
                 (xdisp-tests--positions-across-line text))))
    (should (equal without with))))

;;; xdisp-tests.el ends here
