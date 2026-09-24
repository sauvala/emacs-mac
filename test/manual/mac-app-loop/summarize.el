;;; summarize.el --- summarize scenario results  -*- lexical-binding: t -*-
;; emacs -Q --batch -l summarize.el DIR
(let ((dir (car command-line-args-left)))
  (dolist (file (directory-files dir t "\\.eld\\'"))
    (let ((r (with-temp-buffer (insert-file-contents file) (read (current-buffer)))))
      (princ (format "%-22s max-gap=%4.0fms long-gaps=%d"
                     (plist-get r :scenario)
                     (* 1000 (or (plist-get r :gui-max-gap) 0))
                     (or (plist-get r :gui-long-gaps) 0)))
      (dolist (k '(:access :error :busy :buffer :point :commands :before :after
                   :second-live :frames :ticks :thread-alive :during
                   :delete-frame-count :quit-count :subtitles
                   :count :busy2 :messages))
        (when (plist-member r k)
          (princ (format " %s=%S" k (plist-get r k)))))
      (terpri))))
