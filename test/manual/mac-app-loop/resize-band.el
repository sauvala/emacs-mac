;;; resize-band.el --- fixture for resize-band.sh  -*- lexical-binding: t -*-

;; Grow the frame downward in 8 ms steps, as a trackpad drag does,
;; with a green internal border and the layer background #202020, so
;; that resize-band.py can measure the undrawn band between Emacs's
;; drawing and the window's bottom edge.  Load with -Q; exits by itself.

(setq frame-resize-pixelwise t)
(set-background-color "#202020")
(set-foreground-color "#b0b0b0")
(set-frame-parameter nil 'internal-border-width 8)
(set-face-background 'internal-border "#30d030")
(set-frame-position nil 40 60)
(set-frame-size nil 700 400 t)
(delete-other-windows)
(dotimes (i 40) (insert (format "Line %02d The quick brown fox.\n" i)))
(run-at-time 3 nil
  (lambda ()
    (let* ((x (- (frame-outer-width) 3)) (y (- (frame-outer-height) 3))
           (acts (list (list 0.3 'down x y))) (time 0.3))
      (dotimes (i 120)
        (setq time (+ time 0.008))
        (push (list time 'drag x (+ y (* 3 (1+ i)))) acts))
      (push (list (+ time 0.3) 'up x (+ y 360)) acts)
      (mac-loop-test-schedule (nreverse acts)))
    (run-at-time 3 nil #'kill-emacs)))
