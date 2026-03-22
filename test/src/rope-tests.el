;;; rope-tests.el --- Tests for rope buffer integration  -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the rope text storage backend.
;; All tests are guarded with `(fboundp 'buffer-enable-rope)' so they
;; are no-ops when Emacs is built without --with-rope.

;;; Code:
(require 'ert)

(ert-deftest rope-test-buffer-enable ()
  "Test enabling rope on an empty buffer."
  (skip-unless (fboundp 'buffer-enable-rope))
  (with-temp-buffer
    (should (eq (buffer-using-rope-p) nil))
    (buffer-enable-rope)
    (should (eq (buffer-using-rope-p) t))))

(ert-deftest rope-test-basic-insert-delete ()
  "Test basic insert and delete operations on a rope buffer."
  (skip-unless (fboundp 'buffer-enable-rope))
  (with-temp-buffer
    (buffer-enable-rope)
    (should (eq (buffer-using-rope-p) t))
    ;; Insert text.
    (insert "Hello, world!")
    (should (string= (buffer-string) "Hello, world!"))
    (should (= (point-max) 14))
    ;; Delete some text.
    (goto-char (point-min))
    (delete-char 7)
    (should (string= (buffer-string) "world!"))
    ;; Insert at beginning.
    (goto-char (point-min))
    (insert "Goodbye, ")
    (should (string= (buffer-string) "Goodbye, world!"))
    ;; Replace range.
    (goto-char (point-min))
    (delete-char 8)
    (insert "Hi")
    (should (string= (buffer-string) "Hi world!"))))

(ert-deftest rope-test-multibyte ()
  "Test multibyte character handling in rope buffers."
  (skip-unless (fboundp 'buffer-enable-rope))
  (with-temp-buffer
    (buffer-enable-rope)
    ;; Insert multibyte text.
    (insert "café")
    (should (string= (buffer-string) "café"))
    (should (= (point-max) 5))  ; 4 chars + 1 for BEG
    ;; Verify byte length is correct (é is 2 bytes in UTF-8).
    (should (= (position-bytes (point-max)) 6))  ; 5 bytes + 1 for BEG_BYTE
    ;; Insert more multibyte.
    (goto-char (point-max))
    (insert " naïve")
    (should (string= (buffer-string) "café naïve"))
    ;; Delete across multibyte boundary.
    (goto-char (point-min))
    (delete-char 4)  ; delete "café"
    (should (string= (buffer-string) " naïve"))))

(ert-deftest rope-test-position-conversion ()
  "Test char/byte position conversion in rope buffers."
  (skip-unless (fboundp 'buffer-enable-rope))
  (with-temp-buffer
    (buffer-enable-rope)
    ;; Pure ASCII: charpos == bytepos.
    (insert "abcdef")
    (should (= (position-bytes 1) 1))
    (should (= (position-bytes 4) 4))
    (should (= (position-bytes 7) 7))
    ;; With multibyte: positions diverge.
    (erase-buffer)
    (insert "aéb")  ; a(1) é(2 bytes) b(1) = 4 bytes total
    (should (= (position-bytes 1) 1))   ; before 'a'
    (should (= (position-bytes 2) 2))   ; before 'é'
    (should (= (position-bytes 3) 4))   ; before 'b' (after 2-byte é)
    (should (= (position-bytes 4) 5)))) ; after 'b'

(ert-deftest rope-test-set-buffer-multibyte ()
  "Test toggling multibyte mode on a rope buffer."
  (skip-unless (fboundp 'buffer-enable-rope))
  (with-temp-buffer
    (buffer-enable-rope)
    ;; Start multibyte, insert ASCII.
    (insert "hello")
    (should (string= (buffer-string) "hello"))
    ;; Switch to unibyte.
    (set-buffer-multibyte nil)
    (should (string= (buffer-string) "hello"))
    ;; Switch back to multibyte.
    (set-buffer-multibyte t)
    (should (string= (buffer-string) "hello"))))

(ert-deftest rope-test-search-forward ()
  "Test search-forward on a rope buffer."
  (skip-unless (fboundp 'buffer-enable-rope))
  (with-temp-buffer
    (buffer-enable-rope)
    (insert "hello world hello")
    (goto-char (point-min))
    (should (search-forward "world" nil t))
    (should (= (point) 12))))

(ert-deftest rope-test-search-backward ()
  "Test search-backward on a rope buffer."
  (skip-unless (fboundp 'buffer-enable-rope))
  (with-temp-buffer
    (buffer-enable-rope)
    (insert "hello world hello")
    (goto-char (point-max))
    (should (search-backward "world" nil t))
    (should (= (point) 7))))

(ert-deftest rope-test-re-search ()
  "Test re-search-forward on a rope buffer."
  (skip-unless (fboundp 'buffer-enable-rope))
  (with-temp-buffer
    (buffer-enable-rope)
    (insert "foo123bar456")
    (goto-char (point-min))
    (should (re-search-forward "[0-9]+" nil t))
    (should (string= (match-string 0) "123"))))

(ert-deftest rope-test-looking-at ()
  "Test looking-at on a rope buffer."
  (skip-unless (fboundp 'buffer-enable-rope))
  (with-temp-buffer
    (buffer-enable-rope)
    (insert "hello")
    (goto-char (point-min))
    (should (looking-at "hel"))
    (should (not (looking-at "world")))))

(ert-deftest rope-test-find-newline ()
  "Test newline scanning on a rope buffer."
  (skip-unless (fboundp 'buffer-enable-rope))
  (with-temp-buffer
    (buffer-enable-rope)
    (insert "line1\nline2\nline3\n")
    (goto-char (point-min))
    ;; Forward search for newlines.
    (should (search-forward "\n" nil t))
    (should (= (point) 7))
    ;; Count lines.
    (should (= (count-lines (point-min) (point-max)) 3))))

(ert-deftest rope-test-line-number ()
  "Test line-number-at-pos on a rope buffer."
  (skip-unless (fboundp 'buffer-enable-rope))
  (with-temp-buffer
    (buffer-enable-rope)
    (insert "line1\nline2\nline3\n")
    (goto-char (point-min))
    (should (= (line-number-at-pos) 1))
    (forward-line 2)
    (should (= (line-number-at-pos) 3))))

(ert-deftest rope-test-current-column ()
  "Test current-column on a rope buffer."
  (skip-unless (fboundp 'buffer-enable-rope))
  (with-temp-buffer
    (buffer-enable-rope)
    (insert "hello world")
    (goto-char 7)
    (should (= (current-column) 6))))

(ert-deftest rope-test-display-count-lines ()
  "Test count-lines via display engine on a rope buffer."
  (skip-unless (fboundp 'buffer-enable-rope))
  (with-temp-buffer
    (buffer-enable-rope)
    (insert "a\nb\nc\nd\ne\n")
    (should (= (count-lines (point-min) (point-max)) 5))))

(ert-deftest rope-test-replace-regexp ()
  "Test replace-regexp-in-string equivalent via re-search + replace-match."
  (skip-unless (fboundp 'buffer-enable-rope))
  (with-temp-buffer
    (buffer-enable-rope)
    (insert "cat dog cat")
    (goto-char (point-min))
    (while (re-search-forward "cat" nil t)
      (replace-match "bird"))
    (should (string= (buffer-string) "bird dog bird"))))

(ert-deftest rope-test-syntax-ppss ()
  "Test syntax-ppss on a rope buffer with Emacs Lisp."
  (skip-unless (fboundp 'buffer-enable-rope))
  (with-temp-buffer
    (buffer-enable-rope)
    (emacs-lisp-mode)
    (insert "(defun foo ()\n  \"docstring\"\n  (+ 1 2))")
    (goto-char (point-max))
    (let ((state (syntax-ppss)))
      (should (= (nth 0 state) 0)))))

(ert-deftest rope-test-skip-chars ()
  "Test skip-chars-forward/backward on a rope buffer."
  (skip-unless (fboundp 'buffer-enable-rope))
  (with-temp-buffer
    (buffer-enable-rope)
    (insert "abc123def")
    (goto-char (point-min))
    (should (= (skip-chars-forward "a-z") 3))
    (should (= (point) 4))
    (should (= (skip-chars-forward "0-9") 3))
    (should (= (point) 7))
    (goto-char (point-max))
    (should (= (skip-chars-backward "a-z") -3))
    (should (= (point) 7))))

(ert-deftest rope-test-skip-syntax ()
  "Test skip-syntax-forward/backward on a rope buffer."
  (skip-unless (fboundp 'buffer-enable-rope))
  (with-temp-buffer
    (buffer-enable-rope)
    (insert "hello world")
    (goto-char (point-min))
    (should (= (skip-syntax-forward "w") 5))
    (should (= (point) 6))))

(ert-deftest rope-test-insert-file-contents ()
  "Test insert-file-contents on a rope buffer."
  (skip-unless (fboundp 'buffer-enable-rope))
  (let ((tmpfile (make-temp-file "rope-test")))
    (unwind-protect
        (progn
          (with-temp-file tmpfile
            (insert "test content\nline 2\n"))
          (with-temp-buffer
            (buffer-enable-rope)
            (insert-file-contents tmpfile)
            (should (string= (buffer-string) "test content\nline 2\n"))))
      (delete-file tmpfile))))

(ert-deftest rope-test-write-region ()
  "Test write-region on a rope buffer."
  (skip-unless (fboundp 'buffer-enable-rope))
  (let ((tmpfile (make-temp-file "rope-test")))
    (unwind-protect
        (progn
          (with-temp-buffer
            (buffer-enable-rope)
            (insert "rope output\n")
            (write-region (point-min) (point-max) tmpfile))
          (with-temp-buffer
            (insert-file-contents tmpfile)
            (should (string= (buffer-string) "rope output\n"))))
      (delete-file tmpfile))))

(provide 'rope-tests)
;;; rope-tests.el ends here
