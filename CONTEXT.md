# Mac application integration

Vocabulary for the fork's native application integration planning.

## Language

**Native responsiveness**:
The ability to resize and operate native window controls, and dismiss menus,
while Emacs Lisp is busy. Completion of commands that require Lisp is a
separate acceptance condition.

**Native presentation**:
The visible window and menu response available while Lisp is busy. Editor
content may show its last completed state until Lisp can redraw.

**Lisp completion**:
The execution of an accepted request that needs Lisp, including command
validation, save prompts, hooks, and editor redisplay.

**Documented integration**:
The target event, window, menu, and application lifecycle integration that uses
documented AppKit contracts. It does not imply removing private APIs throughout
unrelated parts of the port.
_Avoid_: Hack-free port

**Compatibility workaround**:
An existing accommodation for OS behavior retained until a replacement passes
the agreed interactive checks. Its presence during migration does not change
the documented-integration destination.
