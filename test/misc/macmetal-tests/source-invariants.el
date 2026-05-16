;;; source-invariants.el --- Tests for macOS Metal renderer source invariants  -*- lexical-binding:t -*-

;;; Commentary:

;; These tests inspect the Metal renderer source directly.  They are intended
;; to catch performance regressions in code that is only compiled when Emacs is
;; configured with --with-metal-rendering.

;;; Code:

(require 'ert)

(defun macmetal-tests--source ()
  "Return the contents of src/macmetal.m."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "src/macmetal.m" source-directory))
    (buffer-string)))

(defun macmetal-tests--function-body (function-name)
  "Return the source body for FUNCTION-NAME in src/macmetal.m."
  (let ((source (macmetal-tests--source)))
    (should (string-match (concat "\n" (regexp-quote function-name) " (")
                          source))
    (let ((start (match-beginning 0)))
      (should (string-match "\n}\n\nvoid\nemacs_metal_frame_end" source start))
      (substring source start (match-beginning 0)))))

(ert-deftest macmetal-flush-render-batches-reuses-frame-vertex-buffer ()
  "Metal batch flushing should not allocate and copy a fresh vertex buffer."
  (let ((body (macmetal-tests--function-body "flush_render_batches")))
    (should-not (string-match-p "newBufferWithBytes" body))
    (should (string-match-p
             (regexp-quote "ctx->vertex_buffers[ctx->current_buffer]")
             body))))

;;; source-invariants.el ends here
