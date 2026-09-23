# Local wayfinder tracker

This tracker holds fork-local planning. It does not publish to GitHub.
Run `/setup-matt-pocock-skills` if a different tracker is wanted.

## Wayfinding operations

- Issues live in `issues/`; each has a stable `id`, `title`, `status`,
  `labels`, `parent`, and `assignee` in YAML front matter.
- A map has label `wayfinder:map`. Find children by matching its id in `parent`.
- Claim an open issue by setting `assignee` before investigating. An empty
  assignee means unclaimed. Review current files before claiming because other
  sessions may be working here.
- This tracker has no native blocking. Each issue's `Blocked by` section lists
  links to its prerequisites. A ticket is unblocked only when all are closed.
- The frontier is the open, unassigned children with no open prerequisites.
  Choose in filename order. Read issue metadata and prerequisite status, rather
  than relying on a copied list of open tickets in the map.
- Resolution comments live in `comments/<issue-id>/`. Record the answer there,
  link any research asset, close the issue, and clear its assignee. Append one
  linked gist to the map's Decisions so far. Keep answers out of ticket bodies.
- Create tickets before wiring their blocking links. Do not close a human
  decision ticket without the user's live participation.

Research artifacts live in `research/`. Research branches and source revision
are recorded in the corresponding ticket. No application code is changed by
charting this map.
