# Changelog

## Unreleased

### Fixed

- Frame-canvas image release declares `image-flush` to the byte compiler, so
  Emacs 29/30 builds no longer report the function as unknown while the
  runtime `require 'image` keeps it available.
- Frame-canvas image release requires the built-in `image` library, so
  `image-flush` is known at byte-compilation time and available at runtime on
  a fresh installation.
- JSON configuration validation marks its serialization check as side-effect
  only, avoiding an unused-value byte-compiler warning on Emacs 29 and 30.
- Godot applies queued commands before physics and flushes a tick's ordered
  replies together, allowing combined controls to share presentation work.
- Streamed states no longer incur another full publication delay when the
  previous rate window has already elapsed.
- Large flat native observation arrays no longer exhaust Lisp evaluation depth
  while copying data for validators and views.

### Added

- Native frame publication: `etaf-gamekit-frame-canvas` shows a canvas
  published as per-line PNG strips, replacing only the rows whose publication
  id changed and falling back to caller text on text displays. Godot projects
  publish strips through the shared `native/godot/frame_strips.gd`, loaded from
  the bridge directory exposed as `Engine.get_meta("gamekit_native_dir")`.
- Godot projects can select `gamekit/observation_hz` from 1 to 60 for autonomous
  state updates; existing projects retain the 20 Hz default.
- OpenSpiel games support bounded undo/redo, including chance outcomes and the
  acting player's perspective. Reset accepts an explicit seed for a new deal.
- The OpenSpiel adapter advertises a `bot` operation that plays one move for the
  side to move: a time-bounded alpha-beta search for xiangqi, and a uniform
  random policy for any turn-based kernel. `undo` and `redo` accept a `:count`
  so a frontend can restore a whole local round in one step.

### Changed

- Game applications now live in independent repositories under `etaf-games`,
  not in this framework's examples. Install `etaf-salvage`, require that feature
  and use `etaf-salvage-open` in place of the bundled `salvage` example.

- OpenSpiel snapshots use format 2 to preserve undo/redo history. Format 1
  snapshots from the initial development version are rejected; finish those
  sessions with that version before upgrading. Other backend snapshots are
  unchanged.
