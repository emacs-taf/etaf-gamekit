# Changelog

## Unreleased

### Fixed

- Godot applies queued commands before physics and flushes a tick's ordered
  replies together, allowing combined controls to share presentation work.
- Streamed states no longer incur another full publication delay when the
  previous rate window has already elapsed.
- Large flat native observation arrays no longer exhaust Lisp evaluation depth
  while copying data for validators and views.

### Added

- Godot projects can select `gamekit/observation_hz` from 1 to 60 for autonomous
  state updates; existing projects retain the 20 Hz default.
- OpenSpiel games support bounded undo/redo, including chance outcomes and the
  acting player's perspective. Reset accepts an explicit seed for a new deal.

### Changed

- Game applications now live in independent repositories under `etaf-games`,
  not in this framework's examples. Install `etaf-salvage`, require that feature
  and use `etaf-salvage-open` in place of the bundled `salvage` example.

- OpenSpiel snapshots use format 2 to preserve undo/redo history. Format 1
  snapshots from the initial development version are rejected; finish those
  sessions with that version before upgrading. Other backend snapshots are
  unchanged.
