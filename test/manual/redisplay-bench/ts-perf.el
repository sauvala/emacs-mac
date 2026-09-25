;;; ts-perf.el --- tree-sitter latency scenarios for the mac port  -*- lexical-binding: t -*-

;; Times keystrokes, page scrolls, typing a string quote, and opening a
;; file in python-ts-mode and typescript-ts-mode, each followed by
;; (redisplay t).  Run from a GUI Emacs, not batch:
;;
;;   REPO=$PWD PERF_OUT=/tmp/ts.eld \
;;     mac/Emacs.app/Contents/MacOS/Emacs -Q \
;;     -l test/manual/redisplay-bench/ts-perf.el --eval '(ts-perf-run)'
;;
;; The fixtures are generated into a temporary directory:
;; "large" is about 800 KB, "typical" about 50 KB.  Set
;; TS_PERF_FILES to a colon-separated list of MODE=FILE entries, for
;; example "python-ts-mode=/path/big.py", to time real files instead.
;; TS_PERF_GRAMMARS is a directory holding the grammar libraries
;; (default ~/.emacs.d/tree-sitter).  GCT sets gc-cons-threshold
;; (default 16 MB, to keep collection out of the fontification cost).
;;
;; `jit-lock-defer-on-input' is bound to nil: a scripted loop always
;; has input pending, so deferral would time unfontified redisplay.
;; Each scenario checks that the window was fontified with faces.
;;
;; The output is a list of (SCENARIO MODE SIZE :n :median :p90 :max
;; ...), times in ms.  The quote scenario also reports the parse part
;; (:parse-median, :parse-p90).  See the roadmap's item 13 and
;; .wayfinder/issues/21-ts-latency-scenarios.md.

;;; Code:

(require 'cl-lib)
(require 'treesit)

(setq gc-cons-threshold
      (string-to-number (or (getenv "GCT") (number-to-string (* 16 1024 1024)))))
(setq treesit-extra-load-path
      (list (expand-file-name (or (getenv "TS_PERF_GRAMMARS")
                                  "~/.emacs.d/tree-sitter"))))
(setq jit-lock-defer-on-input nil)
(setq warning-minimum-log-level :error)

(defvar ts-perf-out (getenv "PERF_OUT"))
(defvar ts-perf-results nil)
(defvar ts-perf-dir nil)

;;;; Fixtures

(defconst ts-perf-python-unit
  "

class Widget%d(Base):
    \"\"\"A widget with a docstring that spans
    two lines, number %d.\"\"\"

    LIMIT = %d
    names = [\"alpha\", 'beta', f\"gamma{LIMIT}\", r\"\\d+\"]

    def __init__(self, value: int = %d, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.value = value  # the current value
        self.table = {key: len(key) for key in self.names if key}

    @property
    def doubled(self) -> int:
        return self.value * 2 + self.LIMIT

    async def fetch(self, session, url: str) -> dict:
        async with session.get(url) as response:
            if response.status != 200:
                raise ValueError(f\"bad status {response.status} for {url!r}\")
            return await response.json()

    def walk(self, items):
        for index, item in enumerate(items):
            try:
                yield index, item.transform(lambda x: x ** 2)
            except (KeyError, AttributeError) as error:
                print(\"skipping\", index, error)
            finally:
                self.value -= 1
"
  "One unit of the generated Python fixture, formatted with a counter.")

(defconst ts-perf-typescript-unit
  "

/** Options for widget %d. */
export interface WidgetOptions%d<T extends object = {}> {
  readonly name: string;
  size?: number;
  tags: Array<string>;
  extra: T & { index: %d };
}

export class Widget%d<T extends object> extends Base implements Renderable {
  private static readonly LIMIT = %d;
  protected items: Map<string, number> = new Map();

  constructor(private options: WidgetOptions%d<T>, public label = \"widget\") {
    super();
    this.items.set(`key-${options.name}`, options.size ?? 0);
  }

  get doubled(): number {
    return (this.options.size ?? 0) * 2 + Widget%d.LIMIT;
  }

  async fetch(url: string): Promise<Record<string, unknown>> {
    const response = await fetch(url, { method: 'GET' });
    if (!response.ok) {
      throw new Error(`bad status ${response.status} for ${url}`);
    }
    return (await response.json()) as Record<string, unknown>;
  }

  *walk(items: readonly T[]): Generator<[number, T]> {
    for (const [index, item] of items.entries()) {
      try {
        yield [index, item];
      } catch (error: unknown) {
        console.log(\"skipping\", index, error); // keep going
      }
    }
  }
}
"
  "One unit of the generated TypeScript fixture, formatted with a counter.")

(defun ts-perf--generate (unit ext size)
  "Write a file of about SIZE bytes from UNIT and return its name.
EXT is the file extension."
  (let ((file (expand-file-name (format "fixture-%d.%s" size ext) ts-perf-dir))
        (count (cl-count ?% unit)))
    (with-temp-file file
      (let ((i 0))
        (while (< (buffer-size) size)
          (insert (apply #'format unit (make-list count i)))
          (setq i (1+ i)))))
    file))

(defun ts-perf--files ()
  "Return a list of (MODE SIZE-LABEL FILE) to time."
  (let ((env (getenv "TS_PERF_FILES")))
    (if env
        (mapcar (lambda (entry)
                  (let ((parts (split-string entry "=")))
                    (list (intern (car parts))
                          (file-name-nondirectory (cadr parts))
                          (cadr parts))))
                (split-string env ":" t))
      (setq ts-perf-dir (make-temp-file "ts-perf" t))
      (append
       (and (treesit-language-available-p 'python)
            (list (list 'python-ts-mode 'large
                        (ts-perf--generate ts-perf-python-unit "py" 800000))
                  (list 'python-ts-mode 'typical
                        (ts-perf--generate ts-perf-python-unit "py" 50000))))
       (and (treesit-language-available-p 'typescript)
            (list (list 'typescript-ts-mode 'large
                        (ts-perf--generate ts-perf-typescript-unit "ts" 800000))
                  (list 'typescript-ts-mode 'typical
                        (ts-perf--generate ts-perf-typescript-unit "ts" 50000))))))))

;;;; Timing

(defun ts-perf--stats (times)
  "Return (:n :median :p90 :max) for TIMES."
  (let ((times (sort (copy-sequence times) #'<))
        (n (length times)))
    (list :n n :median (nth (/ n 2) times)
          :p90 (nth (floor (* n 0.9)) times)
          :max (car (last times)))))

(defun ts-perf--fontified-p ()
  "Return non-nil if the selected window is fontified with some faces."
  (let ((start (window-start)) (end (window-end nil t)))
    (and (not (text-property-not-all start end 'fontified t))
         (text-property-not-all start end 'face nil))))

(defun ts-perf--record (scenario mode size times &rest extra)
  "Push a result for SCENARIO in MODE and SIZE with TIMES and EXTRA."
  (push (append (list scenario mode size)
                (ts-perf--stats times)
                (list :fontified (and (ts-perf--fontified-p) t))
                extra)
        ts-perf-results))

(defmacro ts-perf--ms (&rest body)
  "Run BODY and return the elapsed time in ms."
  `(let ((t0 (float-time))) ,@body (* 1000 (- (float-time) t0))))

(defun ts-perf--goto-middle ()
  "Move point to the end of a code line near the middle of the buffer."
  (goto-char (point-min))
  (forward-line (/ (count-lines (point-min) (point-max)) 2))
  (while (looking-at-p "[ \t]*$") (forward-line 1))
  (end-of-line)
  (recenter))

(defun ts-perf--open (mode file)
  "Visit FILE in MODE and return its buffer."
  (let ((buffer (find-file-noselect file)))
    (with-current-buffer buffer (funcall mode))
    (switch-to-buffer buffer)
    buffer))

(defun ts-perf--scenarios (mode size file)
  "Time the scenarios for FILE in MODE, labelled SIZE."
  ;; Opening: from visiting the file to a fontified first screen.
  (let (times)
    (dotimes (i 10)
      (garbage-collect)
      (push (ts-perf--ms (ts-perf--open mode file) (redisplay t)) times)
      (unless (= i 9) (kill-buffer (current-buffer))))
    (ts-perf--record 'open mode size times))
  (delete-other-windows)
  ;; Page scrolls from the top, wrapping at the end.
  (goto-char (point-min))
  (redisplay t)
  (garbage-collect)
  (let (times)
    (dotimes (_ 150)
      (push (ts-perf--ms
             (condition-case nil (scroll-up-command)
               (end-of-buffer (goto-char (point-min))))
             (redisplay t))
            times))
    (ts-perf--record 'scroll-page mode size times))
  ;; Keystrokes at the end of a code line.
  (ts-perf--goto-middle)
  (redisplay t)
  (garbage-collect)
  (let (times)
    (dotimes (_ 300)
      (push (ts-perf--ms (self-insert-command 1 ?x) (redisplay t)) times))
    (ts-perf--record 'keystroke mode size times))
  ;; Typing a quote, which turns the rest of the buffer into a string
  ;; for the parser.  The deletion is not timed.
  (ts-perf--goto-middle)
  (back-to-indentation)
  (redisplay t)
  (garbage-collect)
  (let ((parser (car (treesit-parser-list)))
        times parse-times)
    (dotimes (_ 100)
      (let* ((t0 (float-time))
             (t1 (progn (insert "\"")
                        (treesit-parser-root-node parser)
                        (float-time))))
        (redisplay t)
        (push (* 1000 (- (float-time) t0)) times)
        (push (* 1000 (- t1 t0)) parse-times))
      (delete-char -1)
      (redisplay t))
    (let ((parse (ts-perf--stats parse-times)))
      (ts-perf--record 'quote mode size times
                       :parse-median (plist-get parse :median)
                       :parse-p90 (plist-get parse :p90))))
  (set-buffer-modified-p nil)
  (kill-buffer (current-buffer)))

(defun ts-perf-run ()
  "Run every scenario, write the results to `ts-perf-out' and exit."
  (set-frame-size nil 200 60)
  (redisplay t)
  (sleep-for 1)
  (dolist (entry (ts-perf--files))
    (apply #'ts-perf--scenarios entry))
  (setq ts-perf-results (nreverse ts-perf-results))
  (with-temp-file ts-perf-out
    (let ((print-length nil))
      (prin1 (list :emacs emacs-version
                   :tree-sitter (and (fboundp 'treesit-library-abi-version)
                                     (treesit-library-abi-version))
                   :gc-cons-threshold gc-cons-threshold
                   :results ts-perf-results)
             (current-buffer))))
  (when ts-perf-dir (delete-directory ts-perf-dir t))
  (kill-emacs 0))

;;; ts-perf.el ends here
