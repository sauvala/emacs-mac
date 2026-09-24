#!/usr/bin/env python3
"""List the windows of a running Emacs process via the Accessibility API.

Part of the S0 evidence kit (.wayfinder/issues/08-s0-instrumentation.md):
used for the accessibility/window-manager acceptance scenario (discover
ordinary editor windows, verify identity/title/geometry/minimized state,
while Lisp is idle or busy). It talks to the OS purely through
`osascript`/System Events; it makes no change to Emacs and does not
require the fixture to be loaded.

Usage:
    windows.py [process-name]

process-name defaults to "Emacs" (the mac port's bundle process name).
Prints a JSON array to stdout, one object per window:

    {"name": ..., "position": [x, y], "size": [w, h], "minimized": bool}

Exit status is nonzero, with a message on stderr, if:
  - the named process is not running under System Events, or
  - accessibility permission has not been granted to the terminal/osascript
    (System Events reports "not allowed assistive access" or similar).

This is a read-only diagnostic; it does not click, move, or resize
anything.
"""

import json
import subprocess
import sys

APPLESCRIPT = """
on run argv
    set procName to item 1 of argv
    tell application "System Events"
        if not (exists process procName) then
            error "process not found: " & procName
        end if
        tell process procName
            set winList to {}
            repeat with w in windows
                set winName to ""
                try
                    set winName to name of w
                end try
                set winPos to {0, 0}
                try
                    set winPos to position of w
                end try
                set winSize to {0, 0}
                try
                    set winSize to size of w
                end try
                set winMin to false
                try
                    set winMin to value of attribute "AXMinimized" of w
                end try
                set end of winList to {winName, winPos, winSize, winMin}
            end repeat
            return winList
        end tell
    end tell
end run
"""


def run_osascript(process_name):
    proc = subprocess.run(
        # -s s prints the result in source form, keeping the braces and
        # quotes; the default human-readable form flattens nested lists
        # on macOS 27.
        ["osascript", "-s", "s", "-e", APPLESCRIPT, process_name],
        capture_output=True,
        text=True,
    )
    return proc


def parse_applescript_list(output):
    """Parse osascript's default list-of-records text output.

    osascript prints AppleScript lists as e.g.:
      {"Foo", {0, 23}, {800, 600}, false}, {"Bar", {10, 10}, {400, 300}, true}
    at the top level (the outer braces of the whole list are stripped by
    osascript itself when printing a top-level list result). We parse this
    by hand rather than depend on any non-stdlib AppleScript/JSON bridge.
    """
    output = output.strip()
    if not output:
        return []

    windows = []
    i = 0
    n = len(output)

    def skip_ws(i):
        while i < n and output[i] in " \t\n,":
            i += 1
        return i

    def parse_value(i):
        i = skip_ws(i)
        if i >= n:
            raise ValueError("unexpected end of osascript output")
        ch = output[i]
        if ch == '"':
            j = i + 1
            buf = []
            while j < n and output[j] != '"':
                if output[j] == "\\" and j + 1 < n:
                    buf.append(output[j + 1])
                    j += 2
                else:
                    buf.append(output[j])
                    j += 1
            return "".join(buf), j + 1
        if ch == "{":
            j = i + 1
            items = []
            j = skip_ws(j)
            while j < n and output[j] != "}":
                val, j = parse_value(j)
                items.append(val)
                j = skip_ws(j)
            return items, j + 1
        # bareword: true/false/missing value/number
        j = i
        while j < n and output[j] not in ",{}\n":
            j += 1
        word = output[i:j].strip()
        if word == "true":
            return True, j
        if word == "false":
            return False, j
        if word == "missing value":
            return None, j
        try:
            if "." in word:
                return float(word), j
            return int(word), j
        except ValueError:
            return word, j

    records = []
    while i < n:
        i = skip_ws(i)
        if i >= n:
            break
        value, i = parse_value(i)
        # Source-form output is one list of records; older default
        # output was the records without the outer braces.
        if isinstance(value, list) and all(isinstance(v, list) for v in value):
            records.extend(value)       # also an empty list: no windows
        else:
            records.append(value)
    for record in records:
        if not isinstance(record, list) or len(record) != 4:
            raise ValueError(f"unexpected record shape: {record!r}")
        name, pos, size, minimized = record
        windows.append(
            {
                "name": name if isinstance(name, str) else "",
                "position": [int(pos[0]), int(pos[1])] if isinstance(pos, list) else None,
                "size": [int(size[0]), int(size[1])] if isinstance(size, list) else None,
                "minimized": bool(minimized) if isinstance(minimized, bool) else False,
            }
        )
    return windows


def main(argv):
    process_name = argv[1] if len(argv) > 1 else "Emacs"
    result = run_osascript(process_name)

    stderr = result.stderr.strip()
    if result.returncode != 0:
        lowered = stderr.lower()
        if "not allowed assistive access" in lowered or "-1719" in stderr or "-25211" in stderr:
            print(
                "windows.py: accessibility permission not granted.\n"
                "windows.py: grant it under System Settings > Privacy & Security >\n"
                "windows.py: Accessibility for the terminal app (or osascript) running this.",
                file=sys.stderr,
            )
        elif "process not found" in lowered:
            print(f"windows.py: no running process named '{process_name}'", file=sys.stderr)
        else:
            print(f"windows.py: osascript failed: {stderr}", file=sys.stderr)
        return 1

    try:
        windows = parse_applescript_list(result.stdout)
    except ValueError as e:
        print(f"windows.py: could not parse osascript output: {e}", file=sys.stderr)
        print(f"windows.py: raw output was: {result.stdout!r}", file=sys.stderr)
        return 1

    print(json.dumps(windows, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
