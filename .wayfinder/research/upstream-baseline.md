# Upstream direction and compatibility baseline

Research date: 2026-09-23. Fork source revision: `1b08291ec0350cec8fbd1447fe869185f486097d`. This report inspects source and public GitHub records; it does not claim a fresh build or interactive GUI test.

## Findings that constrain the plan

The fork already separates the Lisp main thread from the GUI main thread. The redesign must change their synchronization and AppKit event-loop lifetime, not merely move Lisp off the main thread. Keep the present workarounds during migration. Treat upstream's titlebar patch as a comparison candidate, not a documented-API replacement or a completed event-loop redesign.

### Current fork ownership

All following source references are relative to the pinned fork revision above.

- `src/macappkit.m:17902-18042`: `main` starts `mac_start_lisp_main` with `pthread_create`; the new thread calls `emacs_main`, while the initial thread enters `mac_gui_loop`.
- `src/macappkit.m:17282-17404`: GUI and Lisp use block queues and binary semaphores. `mac_gui_loop` waits for Lisp-submitted blocks. `mac_within_gui` waits for GUI completion. This is not an independently running AppKit application loop.
- `src/macappkit.m:17417-17485`: `mac_within_gui_allowing_inner_lisp` allows a synchronous return callback into Lisp. `mac_within_lisp` services GUI work while waiting for that callback. Deferred callbacks drain at the end of the surrounding GUI call. Their safety therefore depends on the caller's current phase, not merely thread identity.
- `src/macappkit.m:538-563`: `runTemporarilyWithBlock:` schedules a block, runs the application, then stops it and posts a dummy event. This is direct code evidence for the maintainer's stop/start diagnosis.
- `src/macappkit.m:11434-11508`: menu tracking and preparation have distinct state. Native preparation may synchronously invoke Lisp only when `mac_select_allow_lisp_evaluation` permits it. The worker path prepares later; command-generation retirement must follow queued actions. Replacing the synchronization scheme must preserve those lifetimes and remove phase-dependent Lisp access from unsolicited AppKit callbacks.

### Existing macOS workarounds

`src/macappkit.m:2062-2083` registers undocumented defaults before creating the application. macOS 26+ disables concurrent event processing and the application update cycle; macOS 27+ additionally selects resize tracking and traditional control tracking. Public `NSUserDefaults` calls do not make the preference keys documented contracts.

`src/macappkit.m:3550-3585` excludes macOS 27+ from the older synthetic mouse-release/press resize technique and uses the live-resize transition instead. Older OS versions retain the legacy path.

Native menu experiments are optional: `configure.ac:696-701` and `src/macappkit.m:132-151` enable both paths with `--enable-mac-native-menus`, otherwise environment presence controls each. Actual menu activation/preparation is restricted to 27+ in `src/macappkit.m:11454-11479`. Unsetting an environment flag does not disable a compiled-in default.

The repository's `AGENTS.md` and `test/manual/mac-menu/README.md:64-125` record earlier interactive checks. They report resize/minimize/menu progress, retry and Help-menu fixes, and C-g cancellation. They also leave broader titlebar/menu/retry coverage incomplete. Those are historical observations, not tests performed for this report; green-button zoom/fullscreen, window discovery, display changes, and busy-Lisp behavior require fresh acceptance evidence.

## Upstream status, verified from GitHub

[Window edge/corner drag-resize does nothing on macOS 27](https://github.com/jdtsmith/emacs-mac/issues/151) remained open when queried. Its reporter identifies macOS 27 build 26A428 and Emacs 31 source `617ada906640ac5694cbec9f5fccf2246b17e21d`. Programmatic frame resizing and tiling work while border drags do not. [Window discovery and automation observations](https://github.com/jdtsmith/emacs-mac/issues/151#issuecomment-5699528862) report zero windows exposed to System Events. That is a reported symptom, not proof that the event loop is its sole cause.

The [maintainer's diagnosis](https://github.com/jdtsmith/emacs-mac/issues/151#issuecomment-5746850733) attributes recurring problems to stopping and starting the application/run loop around events. The maintainer reports progress toward a substantial redesign but supplies no redesign branch or design in that comment. This expresses intent; it is not a reusable published architecture.

[Fix traffic-light and toolbar buttons on macOS 27](https://github.com/jdtsmith/emacs-mac/pull/153) remained open and unmerged. Head: `cb47b9a12019e0d0b718be19479f70307bc2bcb7`; base: `617ada906640ac5694cbec9f5fccf2246b17e21d`. The [published diff](https://github.com/jdtsmith/emacs-mac/pull/153/files) adds 37 lines to `handleOneNSEvent:`. For a left mouse-down in a titlebar/toolbar area it sends the event, then pumps all events in the default run-loop mode until left mouse-up. It also recognizes `NSToolbarFullScreenWindow` through `NSClassFromString`, an internal class name. The added code has no runtime macOS-version gate despite the PR title. It does not replace the overall start/stop architecture or fix border live-resize. In contrast, nemesis changes undocumented preferences and retains the existing event pump.

I queried all published branch names and open PR titles. No complete redesign proposal was identified in this bounded survey. The synchronization-named `gcd-sync-no-deadlock` branch tip (`010627c13ed31d9d3d0ad94be244a70616264d82`) only avoids synchronizing onto the current drawing queue; this does not establish a redesign. Do not interpret this search as proof that no unpublished or differently named work exists. Before implementation, seek a concrete published design/revision from the maintainer if coordination becomes useful; no messages were sent by this research.

Adjacent open proposals deserve comparison during architecture work:

- [Avoid keymap access from the GUI thread in unsafe windows](https://github.com/jdtsmith/emacs-mac/pull/135), head `0b2375744ca8aa53845b94a4b469faa3a2437dd1`: reports accessibility-triggered keymap access during unsafe Lisp phases and proposes a guard. This supports including unsolicited accessibility/menu callbacks in the ownership audit; it does not prove a complete solution.
- [Prevent frame churn from starving dispatch work](https://github.com/jdtsmith/emacs-mac/pull/144), head `03b406b604fdcf8a6c13bddb15485e69de13216b`: describes GUI/Lisp waits caused by dispatch-worker exhaustion and separates blocking queues. Its reported tests belong to that proposal, not this fork audit.

## Supported versions: three different claims

| Claim | Evidence | Planning consequence |
|---|---|---|
| Declared Mac-port GUI compatibility | `README-mac:3-4` and `README.txt:3-4` say OS X 10.10 through macOS 26. | Preserve 10.10 as the declared lower bound unless an explicit later decision revises support. The upper bound is stale relative to the 27 work. |
| Optional rendering baseline | `README-mac:272-277` says experimental full Metal rendering requires macOS 14+. | Do not generalize that option's floor to the default Core Graphics build. |
| SDK/deployment compilation | `configure.ac:7617-7638` tests maximum allowed SDK version for Metal availability; `configure.ac:7677-7697` tests minimum required deployment version for UniformTypeIdentifiers. `src/macappkit.h` contains older-SDK compatibility declarations. | SDK version, deployment target, and runtime support are separate. These checks do not certify runtime behavior on every declared OS. |
| Current tested systems | Repository notes and issue comments above report macOS 27 experiments. | No cross-version test matrix was verified by this research. Do not call 10.10-27 tested support. |

The `configure.ac:2882` 10.6 check occurs in the NS/Cocoa configuration section, so it is not evidence that this Mac-port fork promises 10.6 support. A shipped binary's effective floor also depends on its deployment target and linked dependencies; neither was established here. The plan must record OS, CPU architecture, SDK/toolchain, renderer and deployment target separately when defining the validation matrix.

## Resolution and remaining decisions

This baseline investigation can close. It establishes the existing ownership constraints, declared support floor, current workaround differences, and publicly visible upstream direction. It does not select a new event-loop architecture.

The next architecture decision must specify how the main thread keeps AppKit running while Lisp is busy, how synchronous callbacks obtain safe data, and how menu commands, rendering resources and frame lifetimes survive asynchronous delivery. The migration/validation decision must retain old behavior until real interactions pass, explicitly include accessibility window discovery and automation, and cover the declared older-OS range rather than silently narrowing support to 27+.
