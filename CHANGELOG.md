# Changelog

## Unreleased

### Fixed

- Large flat native observation arrays no longer exhaust Lisp evaluation depth
  while copying data for validators and views.

### Added

- OpenSpiel games support bounded undo/redo, including chance outcomes and the
  acting player's perspective. Reset accepts an explicit seed for a new deal.

### Changed

- OpenSpiel snapshots use format 2 to preserve undo/redo history. Format 1
  snapshots from the initial development version are rejected; finish those
  sessions with that version before upgrading. Other backend snapshots are
  unchanged.
