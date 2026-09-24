# S1 launch selector resolution

Closed on 2026-09-24 at the user's request.

`EMACS_MAC_PERSISTENT_LOOP` selected each loop in fresh processes for
every scripted run (`run-scenarios.sh old|new|both`), and
`--enable-mac-persistent-loop` set the compiled default, which the
variable overrode in both directions (the user's installed build used
the compiled new-loop default; `=0` selected the old loop for A/B runs).
Default builds kept the old loop's behaviour against the S0 baseline.

The selector itself is removed in S8, at the user's decision to make the
new loop the only loop.
