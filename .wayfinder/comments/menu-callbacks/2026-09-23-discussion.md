# Menu and callback contracts discussion

Status: confirmed by the user and resolved. On 2026-09-23 the user asked the
agent to adopt its recommended answers and document them instead of asking;
the user then reviewed the decisions live, accepted them, and revised D9.

## Round 1 decisions (agent-adopted)

- **D1. Callback evaluator thread.** The GUI thread never evaluates Lisp. A
  GUI-to-Lisp callback is a request record that wakes the thread holding or
  next taking the global lock (from its input wait, or from its wait on a
  Lisp-initiated modal request). The GUI waits for the result within the
  ~50 ms budget for menu-bar and content callbacks, and without limit only in
  the Lisp-initiated modal class that ticket 04 exempted. *Why:* removes
  specpdl/handler/longjmp exposure on the GUI thread and the parked-Lisp phase
  flags that ticket 03 found unsafe as a proxy for native tracking.
- **D2. Menu-bar snapshots are published data, not structural requests.**
  Lisp builds an immutable per-frame snapshot and swaps it in atomically,
  then continues without waiting. The GUI applies the newest snapshot only at
  the next `menuNeedsUpdate:` or after tracking ends; it never edits a menu
  while it is displayed. Lisp publishes where it recomputes the menu bar today
  (`update_menu_bar`/`set_frame_menubar` after commands) and on selected-frame
  change. *Why:* under 04's rule that structural requests wait out tracking, a
  synchronous menu-bar update would stall Lisp for as long as a menu is open.
- **D3. Open-time refresh.** At `menuNeedsUpdate:`, if Lisp is at a safe
  point, the GUI requests a refresh of only the submenu being opened (running
  `menu-bar-update-hook` and expanding its keymap or `:filter`) and waits
  within the budget. On timeout or with no safe point it shows the cached
  snapshot. A late refresh result is kept for the next opening, never applied
  to the menu already on screen. *Why:* dynamic menus (Buffers, `:filter`)
  stay fresh when Lisp is idle without breaking the 100 ms target when busy.
- **D4. Ownership and GC roots.** The GUI-side snapshot holds no Lisp
  objects: titles, key equivalents, enabled/checked/radio state, separators,
  a generation number and item ids. The Lisp side keeps a table from
  (generation, item id) to binding and captured context. That table is rooted
  by the Lisp side and released only when a newer generation has superseded it
  and no queued action still references it. *Why:* snapshot lifetime and GC
  stay entirely under Lisp's control; stale GUI data cannot reach reclaimed
  objects.
- **D5. Queued action record and revalidation.** Selecting a menu-bar item
  enqueues one input record carrying generation, item id, frame id, and the
  selected window and buffer captured with the snapshot. On dequeue Lisp
  checks that the generation entry exists, that the frame and window are live
  and the window still shows the buffer, and that the item's `:enable` still
  holds in that context. It then selects that window and runs the binding;
  otherwise it rejects with an echo-area message. Dequeue consumes the record,
  giving at-most-once execution. Popup menus (`x-popup-menu`) keep returning
  their choice to the waiting Lisp call and do not use this path. *Rejected:*
  rejecting every action whose generation is no longer current — simpler but
  rejects ordinary selections after an unrelated menu-bar update.
- **D6. Busy-menu contents.** A cached menu shows its snapshot state as
  published; validity is re-established at execution by D5. A submenu never
  expanded (lazy `:filter` with no cache) shows one disabled "Unavailable
  while Emacs is busy" entry. Menus remain dismissible. *Rejected:* disabling
  every `:enable`/`:visible`/`:filter` item, or everything non-native — makes
  menus useless during long commands for little safety gain, since D5 already
  guards execution.
- **D7. Application, Help and Services items.**
  - Native-only items (Hide, Hide Others, Show All, Minimize, Zoom, Bring All
    to Front, Enter Full Screen) run entirely on the GUI thread.
  - About, Preferences and other Lisp-defined application-menu items are
    queued actions under D5. Quit follows the deferred-quit route of tickets 04
    and 06.
  - Help search is AppKit searching the installed items, so it works on the
    cached snapshot; selecting a result follows D5.
  - Services as requester: `validRequestorForSendType:returnType:` currently
    reads `Vmac_service_selection`, `Vselection_converter_alist` and
    `Fmac_selection_owner_p` on the GUI thread without the lock
    (`src/macappkit.m:13653`). The data itself already lives in a named
    pasteboard that Lisp fills, so the requester only needs a published
    snapshot of the service-selection name, ownership and supported types.
    Validation and `writeSelectionToPasteboard:types:` then never touch Lisp.
    Return data (`readSelectionFromPasteboard:`) is already copied and queued
    as an input event.
  - Services as provider: `handle_services_invocation`
    (`src/macappkit.m:13832`) already copies the pasteboard, queues a
    `service perform` event and returns without waiting for Lisp, so
    providers stay asynchronous; no bounded wait is introduced. The lookup
    that decides whether a selector is a handler (`is_services_handler_selector`
    reads `mac-apple-event-map` on the GUI thread) moves to the published
    snapshot. *Correction:* an earlier draft proposed a bounded wait for
    providers; the source showed it is unnecessary.

## Source facts used (verified by the parent agent)

A cheaper agent inventoried the menu machinery; the parent checked the cited
sites at `254f965d9c0`:

- Classic menu-bar activation peeks the Carbon main queue for a menu-bar
  mouse-down or the "move focus to menu bar" hot key (private
  `_IsSymbolicHotKeyEvent`), removes it, stores `MENU_BAR_ACTIVATE_EVENT`,
  and later replays it with `PostEventToQueue` or `mac_fake_menu_bar_click`
  (`src/macappkit.m:1708`, `10468`, `11758`, `12120`). Unexpected tracking
  not started this way is cancelled (`menuDidBeginTracking:`).
- The native path already keeps a `staticpro`'d alist of generation to
  `[FRAME VECTOR ITEMS-USED]` (`src/macmenu.c:53`), with AppKit holding only
  generation and tag. Selection with a dead frame or stale generation is a
  silent no-op (`src/macmenu.c:158`). Items are enabled at build time; the
  only `validateMenuItem:` override is for the toolbar palette
  (`src/macappkit.m:2384`).
- `menuNeedsUpdate:` clears the submenu and schedules
  `cancelAndRetryNativeMenu:` in tracking mode, which cancels tracking and
  reopens through `mac_press_native_menubar`. The worker path replaces the
  Help menu with an empty placeholder while unprepared.
- Help search (`searchForItemsWithSearchString:`) reads `mac-help-topics` on
  the GUI thread; selecting results queues Apple-event-style actions.
- help-echo for highlighted items calls `show_help_echo` synchronously
  through `mac_within_lisp`, only while `popup_activated ()`.
- Phase flags authorizing GUI-thread Lisp: `popup_activated_flag` and
  `mac_select_allow_lisp_evaluation`; bridge primitives are
  `mac_within_lisp*` and `mac_within_gui_allowing_inner_lisp`
  (`src/macappkit.m:17423`).

## Round 2 decisions (agent-adopted)

- **D8. Carbon menu-bar interception retires under the new loop.** AppKit
  tracks the menu bar from the first click and from the keyboard focus hot
  key; D2/D3 supply the contents. Queue peeking, `saved_menu_event`, event
  replay, `mac_fake_menu_bar_click` and cancellation of "unexpected" tracking
  are not used by the new loop. *Why:* the interception exists to run Lisp
  before tracking starts, which D2/D3 make unnecessary, and it depends on
  Carbon queue access and a private symbol.
- **D9. Lisp-initiated menu-bar opening (user-revised).** Nothing fakes a
  menu-bar click or drives the app's own menu bar through accessibility.
  `mac-menu-bar-open` (F10 and `accelerate-menu`) shows the menu-bar keymap as
  an ordinary Lisp-initiated modal popup placed under the menu bar, the
  same path as `popup-menu`. GNU Emacs's NS port likewise has no native F10
  and falls back to `popup-menu` (`lisp/menu-bar.el:2863`). Real keyboard
  navigation of the menu bar is left to the system shortcut "Move focus to
  menu bar" (Control-F2 by default), which AppKit handles natively once D8
  removes the Carbon interception; Emacs only has to pass the key to the
  system, as `mac-pass-control-to-system` already allows. Users who prefer a
  text menu can bind F10 to `tmm-menubar`. *Rejected:* private AppKit
  methods and an Accessibility self-press (automation hacks). *Prototype
  checks:* the popup is acceptable in practice, and Control-F2 reaches AppKit
  tracking under the new loop while Lisp is idle and busy.
- **D10. Cancel/rebuild/reopen and Help redirection retire under the new
  loop.** `menuNeedsUpdate:` fills the submenu in place from the snapshot or
  the bounded refresh (D3) before it is displayed, so there is no
  empty-then-reopen cycle. Help search reads a `mac-help-topics` copy
  published with the menu-bar snapshot, so the Help menu never needs to be
  swapped out. `scheduleNativeRetry:`, `cancelAndRetryNativeMenu:`,
  `mac_press_native_menubar` reopening, `nativeHelpPlaceholder` and
  `mac_select_allow_lisp_evaluation` remain only on the old loop.
- **D11. Validation.** Menu-bar items get their enabled/checked state from
  the snapshot when the submenu is filled; no per-item `validateMenuItem:`
  evaluates Lisp. Native-only items use normal responder-chain validation.
  Execution-time validity is D5.
- **D12. Phase flags and bridge.** `popup_activated_flag` stays as a
  Lisp-side "menu or dialog in use" guard against nested popups
  (`menu-or-popup-active-p` keeps its meaning) but no longer authorizes
  GUI-thread Lisp. Under the new loop, `mac_within_lisp*` and
  `mac_within_gui_allowing_inner_lisp` are replaced by D1 callback records
  with a small fixed set of kinds: menu-refresh, help-echo, drag feedback,
  content query, and window-parameter changes (the window kinds are
  classified by ticket 06).
- **D13. help-echo is fire-and-forget.** For popup and menu-bar menus alike,
  highlighting posts a coalesced help-echo record (latest item wins) and the
  GUI does not wait. A parked Lisp shows it promptly; a busy Lisp drops
  records superseded before it runs. *Why:* help-echo is advisory and
  needs no answer, so it should not use 04's unbounded modal exception.
- **D14. Popup menus and dialogs.** `x-popup-menu`/`x-popup-dialog` stay
  Lisp-initiated modal requests: Lisp builds the complete tree first, blocks
  until tracking returns, and receives the choice directly. They run in
  default mode (structural). The only callback during tracking is D13.
  C-g during a popup cancels it and returns no choice, so `x-popup-menu`
  quits as today.
- **D15. C-g during menu-bar tracking.** Keep GUI-side recognition from the
  published quit configuration (04). The first C-g cancels tracking
  (root and open submenus), is consumed, and sets no quit request. The
  prototype compares the current `nextEventMatchingMask:` override with a
  local event monitor and keeps whichever sees quit keys during tracking on
  macOS 27; if neither does, that is a prototype failure, not a reason to
  run Lisp during tracking.
- **D16. Per-frame snapshots and frame lifecycle.** Lisp publishes one
  snapshot per frame. The GUI installs the key frame's snapshot on key
  window change without Lisp. When a non-frame window is key, the last
  installed snapshot stays. Frame deletion publishes a retraction; a menu
  already open for that frame stays until dismissed, and its actions are
  rejected by D5. The Lisp-side table (D4) drops the frame's generations
  once no queued record references them.
- **D17. Rejection feedback.** A rejected menu action shows an echo-area
  message naming the item and reason (item unavailable, buffer changed,
  frame closed) and rings the bell only if `visible-bell`/`ring-bell-function`
  already would for `user-error`; implemented as a `user-error` raised
  from the menu-event handler. This replaces today's silent no-op.
- **D18. Application-menu and Help results.** About, Preferences and Help
  search results already travel as queued Apple-event input records; they
  are not context-bound but execute at most once. Quit coalescing belongs to
  ticket 06.
- **D19. Request classes for 04's run-loop modes.**
  | Request | Class |
  | --- | --- |
  | Menu-bar snapshot publication, help topics, service types | Published data, non-blocking |
  | Open-time submenu refresh | GUI-to-Lisp callback, bounded |
  | help-echo | GUI-to-Lisp callback, fire-and-forget |
  | Menu-bar action, Help result, About/Preferences, service perform/paste | Input queue record |
  | Services validation/write | GUI-only, reads published data |
  | `x-popup-menu`, `x-popup-dialog`, `mac-menu-bar-open` popup | Lisp-to-GUI modal, default mode |
  | Tooltip for help-echo | Lisp-to-GUI presentation, all modes |
- **D20. Coexistence and the experimental flags.** All of the above applies
  only under the launch-selected new loop. The old loop keeps its Carbon
  interception, native/worker paths and flags unchanged. Once the new loop
  passes its gates, `EMACS_MAC_NATIVE_MENUS`, `EMACS_MAC_WORKER_MENUS` and
  `--enable-mac-native-menus` are superseded; retiring them is staged by
  ticket 07.
- **D21. Menu prototype.** On top of 04's persistent-loop prototype, add:
  per-frame snapshot publication, bounded open-time refresh, the
  generation table and revalidated action record, C-g cancellation, Help
  search on published topics, published Services data, the popup-based
  `mac-menu-bar-open`, and Control-F2 menu-bar navigation. Run the ticket 03 menu scenarios in fresh processes
  with Lisp idle, waiting in the minibuffer, and in a busy loop that never
  waits for input:
  menus open within 100 ms from cache; dynamic submenus are fresh when idle;
  selection runs exactly once in the original context or is rejected with
  a message after buffer switch, frame deletion and forced GC; Escape and
  C-g dismiss without executing, reopening or interrupting Lisp; Help search
  finds and runs a topic; a Services send and a provider invocation work;
  no cancel/reopen, Carbon queue access or GUI-thread Lisp evaluation occurs
  (verified by instrumentation). Fails if any case needs an undocumented
  preference or GUI-thread Lisp. `test/manual/mac-menu/check.py` is extended
  to cover the new table's lifetime rules (release only when superseded and
  unreferenced), which remains a standalone check, not GC evidence.

## User review

The user accepted every decision except the original D9 (a popup substitute,
with an Accessibility press as the alternative), asking for a way to avoid
event-faking hacks. D9 was revised to popup plus the system menu-bar
shortcut, which the user accepted. The user also accepted D17's `user-error`
feedback. Help text for highlighted menu-bar items (D13) is kept as proposed.

## Implementation notes (2026-09-24, agent-adopted, awaiting user review)

- **D5 `:enable` recheck.** `mac-menu-bar-execute-selection` rebuilds the
  item's key path from the snapshot vector, temporarily selects the
  snapshot's window, looks up the raw binding under `[menu-bar ...]` in
  the active maps, and runs `parse_menu_item` on it, so `:filter`,
  `:visible`, `:enable` and `menu-enable` are evaluated as when the menu
  was built. An item that is gone, invisible or disabled is rejected as
  "item disabled"/"item unavailable". The window selection is restored
  before rejecting.
- **D6 placeholder not needed.** Under the persistent loop,
  `set_frame_menubar` always fills deeply, which evaluates every
  `:filter` whenever the snapshot is published. No submenu reaches the
  GUI unexpanded, so the "Unavailable while Emacs is busy" entry is never
  shown and was not implemented. Revisit this if deep-fill cost forces a
  return to lazy submenus.
- **D16 retraction.** `free_frame_menubar` clears the command vector,
  window and buffer of the deleted frame's snapshots, but keeps the
  entries with their frame. A queued selection then reports "frame
  closed", and help-echo treats the snapshot as dead.
- **D15.** Under the persistent loop, the root `EmacsMenu` records
  tracking from its begin and end notifications. The existing
  `nextEventMatchingMask:` hook cancels the root and its submenus on a
  quit key and consumes the key. It uses the same recognizer as the
  busy-quit path and evaluates no Lisp. It has not been verified with
  real tracking; the local event monitor alternative was not needed.
- **Deep-fill cost.** Measured with `menu-fill-cost`: a forced
  menu-bar update took about 21 ms (plain `-Q`) and 42 ms (200 buffers
  and six major modes) under the persistent loop, against 0.8 ms and
  7.5 ms for the old loop's shallow update. About half was the Lisp
  build and half the AppKit fill. The fill ran every time, because the
  `EQ` comparison always failed: the rebuild conses fresh strings and
  stores `:enable` values such as Recover Session's file list. The
  adopted fix has two parts. Under the persistent loop, redisplay during
  a command only marks the menu bar pending, and a 0.2 s repeating idle
  timer (`mac-update-pending-menu-bars`) does the deep fill. Redisplay
  while already idle, such as from a timer, fills immediately. The
  comparison treats strings as equal by text and `:enable`/`:selected`
  values by truthiness. An idle update then costs about 9 ms and 23 ms,
  with no AppKit refill when nothing visible changed. Menus can be up to
  0.2 s of idle time stale after a command, and D5 revalidation covers
  that window. *Rejected:* a deep fill on every redisplay, because it
  adds 20-40 ms to buffer switches and first edits; restoring
  open-time filling, because that needs D3's bounded GUI-to-Lisp request
  during tracking.
