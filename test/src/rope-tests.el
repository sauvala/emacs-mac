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

(provide 'rope-tests)
;;; rope-tests.el ends here
