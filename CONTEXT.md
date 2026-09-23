# Mac application integration

Vocabulary for the fork's native application integration planning.

## Language

**Native responsiveness**:
The ability to resize and operate native window controls, and dismiss menus,
while Emacs Lisp is busy. Completion of commands that require Lisp is a
separate acceptance condition.

**Documented integration**:
The target event, window, menu, and application lifecycle integration that uses
documented AppKit contracts. It does not imply removing private APIs throughout
unrelated parts of the port.
_Avoid_: Hack-free port

**Compatibility workaround**:
An existing accommodation for OS behavior retained until a replacement passes
the agreed interactive checks. Its presence during migration does not change
the documented-integration destination.
