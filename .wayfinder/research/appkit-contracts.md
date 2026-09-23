# Documented AppKit lifecycle and tracking contracts

Research date: 2026-09-23. Source baseline: `1b08291ec0350cec8fbd1447fe869185f486097d`.
Question: [Establish documented AppKit lifecycle and tracking contracts](../issues/01-appkit-contracts.md).

## Finding

A continuously running main-thread AppKit application with Lisp processing on a worker is compatible with the documented event model. It is a credible direction for replacing the current intermittent application loop, not proof that removing the compatibility preferences will fix macOS 27. The difficult boundary is synchronous callbacks and shared state, rather than finding a newer replacement API.

## Documented constraints

- **Application ownership:** Apple describes creating the application and starting its event loop with `NSApplication.run`. That is the appropriate baseline to prototype; it does not require moving Lisp into the main-thread event handler. [NSApplication](https://developer.apple.com/documentation/appkit/nsapplication)
- **Threads and data:** Apple's threading guide assigns event handling to the main thread, permits forwarding received events to workers, restricts view manipulation to the main thread, and warns that mutable objects need synchronization. Worker Cocoa use needs its own autorelease pools. These are archived guidelines; modern API annotations and SDK declarations must also be checked during implementation. **Inference:** give AppKit objects one main-thread owner and transfer copied data or explicitly owned snapshots across the Lisp boundary. [Thread safety](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/ThreadSafetySummary/ThreadSafetySummary.html)
- **Run-loop modes:** Sources execute only in their registered modes. Cocoa common modes normally include default, modal, and tracking modes; a bare Core Foundation common-mode set initially includes only default. Public custom run-loop sources can carry worker messages. **Inference:** distinguish work safe during nested tracking from work that must await the outer loop, rather than placing every callback indiscriminately in common modes. No retrieved documentation promises latency or fairness for every nested loop. [Run loops](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/RunLoopManagement/RunLoopManagement.html)
- **Application stopping is not a general wakeup mechanism:** `stop:` sets a flag checked after dispatching an actual event; timer/observer calls alone do not force return. In a modal event loop it exits that loop instead. This explains why the existing helper also posts a dummy event, but does not justify retaining stop/run as the long-term worker protocol. [stop:](https://developer.apple.com/documentation/appkit/nsapplication/stop(_:))
- **Modal cancellation has its own contract:** `stopModal` pairs with a modal invocation. Since 10.9 it can stop `runModalForWindow:` from outside an event callback, including a timer or another thread. Prefer a main-thread request in the proposed ownership model; do not confuse modal cancellation with stopping the whole application. [stopModal](https://developer.apple.com/documentation/appkit/nsapplication/stopmodal())
- **Menu preparation:** `menuNeedsUpdate:` runs when display/tracking is beginning and can modify items; validation follows. Apple recommends incremental item callbacks for expensive population. These callbacks do not provide a documented asynchronous continuation for arbitrary Lisp evaluation. **Inference:** a prepared snapshot, a bounded fallback, or an explicitly designed delayed-opening policy is needed if Lisp is busy; the docs do not choose among them. [menuNeedsUpdate](https://developer.apple.com/documentation/appkit/nsmenudelegate/menuneedsupdate(_:))
- **Menu cancellation:** `cancelTrackingWithoutAnimation` dismisses the menu and ends tracking. That establishes a public cancellation operation, not a guarantee that every key event passes through the application's ordinary key-equivalent callback, nor a guarantee about when queued actions release their data. [Menu cancellation](https://developer.apple.com/documentation/appkit/nsmenu/canceltrackingwithoutanimation())
- **Tracking and drawing:** `updateWindows` is automatic after events in default/modal mode but not tracking mode. A continuously running application therefore does not, by itself, prove fresh Lisp redisplay during a drag. [updateWindows](https://developer.apple.com/documentation/appkit/nsapplication/updatewindows())
- **Live resize:** `viewWillStartLiveResize` and `viewDidEndLiveResize` bracket the view's resize session; the SDK says to call the superclass implementations. Content-preservation methods support reduced drawing during live resize. **Inference:** preserve and redraw a safe presentation while coalescing new geometry for Lisp, then request final redisplay; the exact rendering handoff remains a prototype question. [Live resize callback](https://developer.apple.com/documentation/appkit/nsview/viewwillstartliveresize()), [drawing optimization](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CocoaViewsGuide/Optimizing/Optimizing.html)

## Public mechanisms and availability

Availability was cross-checked against the installed Xcode SDK headers under `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/`.

| Mechanism | Evidence and limitation |
|---|---|
| `CFRunLoopSource` plus signal/wakeup | Documented worker-to-loop mechanism in the run-loop guide; can register explicitly for appropriate modes. Prefer this as the conservative prototype baseline. |
| `CFRunLoopPerformBlock` | `CoreFoundation.framework/Headers/CFRunLoop.h:81` declares macOS 10.6+. A candidate for mode-selected delivery; cancellation, lifetime and ordering still belong to the application's protocol. [API](https://developer.apple.com/documentation/corefoundation/cfrunloopperformblock(_:_:_:)) |
| `NSMenu.cancelTracking` / `cancelTrackingWithoutAnimation` | `AppKit.framework/Headers/NSMenu.h:163,166` declare 10.5+ / 10.6+. |
| `NSApplication.run`, tracking/modal mode constants, live-resize callbacks | Present as baseline declarations in the installed headers, without a new macOS 27 availability gate. This is not a complete audit of the fork's oldest supported deployment target. |
| `stopModal` outside event callbacks | Documented behavior change at 10.9; older supported releases, if any, require a separate path or cancellation from a modal callback. |

None of the identified building blocks intrinsically requires 27+. A 27+ opt-in rollout can isolate implementation risk, while eventual support for all supported OS versions remains plausible. The exact supported-version matrix must be established before selecting optional APIs or removing older paths.

## Relationship to current workarounds

Local source observations: `src/macappkit.m:531–578` implements `postDummyEvent`, `stopAfterCallingBlock:`, `runTemporarilyWithBlock:` and `mac_within_app`. `src/macappkit.m:2071–2081` registers the concurrent-processing/update-cycle preferences for 26+ and resize/control-tracking preferences for 27+.

A persistent application loop could replace repeated temporary run/stop entry. Main-thread ownership and explicitly scheduled presentation work could allow the normal update cycle and gesture tracking to remain enabled. Native live-resize handling could remove synthetic input splitting. These are **hypotheses**, not established replacements: the retrieved public documentation does not describe the four undocumented preferences or promise how their removal affects this port.

## Prototype evidence required before a design decision

1. Keep `NSApplication.run` active while deliberately blocking Lisp; exercise edge/corner resize, yellow-button minimize/restore, green-button zoom/fullscreen, and close. Record AppKit thread and run-loop mode without invoking Lisp from instrumentation.
2. Deliver bounded worker messages during default, tracking, and modal loops. Demonstrate no cyclic waits when Lisp asks AppKit for a result while AppKit receives a Lisp-dependent callback. Check nested entry, shutdown, and stale frame references.
3. Exercise dynamic menus while Lisp is idle and busy. Verify freshness policy, validation, C-g dismissal, queued command ownership, and Help submenu behavior. A tracking-end notification is insufficient evidence that the native call stack has unwound.
4. Test resize presentation separately from geometry updates: final size, interim drawing, clipping, rapid reversals, Retina scale/display changes, and terminal Lisp state must converge.
5. Remove each compatibility preference only in isolated candidate builds and compare fresh processes across the eventual supported-version matrix. Add lifecycle, accessibility-window discovery and window-manager checks to the broader acceptance ticket; this report does not establish those results.

## Research method and resolution

Context7 resolved `AppKit` to `/websites/developer_apple_appkit` (official Apple index), then returned run-loop/modal and menu-preparation/cancellation documentation in two queries. No quota or network failure occurred. Apple documentation and local SDK headers supplied the remaining evidence. No GUI experiments or source changes were made.

The research question is sufficiently answered for charting: documented constraints and candidate mechanisms are known. Architecture selection and workaround removal remain blocked on the callback/ownership audit and targeted prototypes, not on an assumption that AppKit lacks public integration APIs.
