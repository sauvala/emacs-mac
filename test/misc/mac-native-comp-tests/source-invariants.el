;;; source-invariants.el --- mac native-comp source checks -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Free Software Foundation, Inc.

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

;; Source-level checks for macOS native-comp packaging behavior.

;;; Code:

(require 'ert)

(defun mac-native-comp-tests--repo-source (file)
  "Return the contents of FILE relative to `source-directory'."
  (with-temp-buffer
    (insert-file-contents (expand-file-name file source-directory))
    (buffer-string)))

(ert-deftest mac-native-comp-finds-gcc-runtime-for-gui-launches ()
  "Darwin libgccjit should find GCC runtime libs without shell PATH help."
  (let ((configure (mac-native-comp-tests--repo-source "configure.ac"))
        (comp (mac-native-comp-tests--repo-source "src/comp.c")))
    (should (string-match-p "MAC_NATIVE_COMP_DRIVER_LIBDIR" configure))
    (should (string-match-p "libemutls_w\\.a" configure))
    (should (string-match-p "find -L" configure))
    (should (string-match-p "MAC_NATIVE_COMP_DRIVER_LIBDIR" comp))
    (should (string-match-p
             (regexp-quote "gcc_jit_context_add_driver_option")
             comp))
    (should (string-match-p
             (regexp-quote "\"-L\" MAC_NATIVE_COMP_DRIVER_LIBDIR")
             comp))))

(provide 'source-invariants)

;;; source-invariants.el ends here
