;;; source-invariants.el --- Tests for macOS terminal source invariants  -*- lexical-binding:t -*-

;;; Commentary:

;; These tests inspect macOS terminal source directly.  They catch regressions
;; in performance-sensitive paths that are difficult to exercise in non-GUI
;; test runs.

;;; Code:

(require 'ert)

(defun macterm-tests--source ()
  "Return the contents of src/macterm.c."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "src/macterm.c" source-directory))
    (buffer-string)))

(defun macterm-tests--function-body (function-name next-marker)
  "Return FUNCTION-NAME source body from src/macterm.c up to NEXT-MARKER."
  (let ((source (macterm-tests--source)))
    (should (string-match (concat "\n" (regexp-quote function-name) " (")
                          source))
    (let ((start (match-beginning 0)))
      (should (string-match (regexp-quote next-marker) source start))
      (substring source start (match-beginning 0)))))

(ert-deftest macterm-metal-cg-image-draw-uses-texture-cache ()
  "The Metal CGImage draw path should not upload and destroy every draw."
  (let ((body (macterm-tests--function-body
               "mac_draw_cg_image"
               "\n/* Mac replacement for XCreateBitmapFromBitmapData.  */")))
    (should (string-match-p "emacs_metal_get_cached_cg_image" body))
    (should-not (string-match-p "emacs_metal_upload_cg_image" body))
    (should-not (string-match-p "emacs_metal_destroy_texture" body))))

;;; source-invariants.el ends here
