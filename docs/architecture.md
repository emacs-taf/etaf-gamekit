# Architecture

The game process is authoritative. Chess delegates legality and position history
to python-chess and search to Stockfish. Interactive fiction delegates execution,
undo and the world model to Glulxe. RemGlk exposes the game's text I/O. Neither
ETAF nor this frontend reimplements those algorithms.

The session layer owns one asynchronous transport, request correlation, accepted
observations and buffer lifetime. One action may be pending at a time. Response
revisions increase; stale or unrelated responses fail the connection. Display
publication is coalesced to sixty frames per second, while action responses
and their errors remain observable through the session API.

The view layer composes etaf-ui controls. TileGrid supplies chess coordinates,
activation and help; TextGrid supplies dense retained rows. TextInput supplies
native in-buffer editing. Selection, promotion preference and unsent drafts are
frontend state. Backend positions and story worlds are not writable frontend
state. Apps use ETAF's public API and do not reach into Ebox.

The Python command is a protocol adapter, not another game engine. Its normalized
wire views are deliberately limited to the MVP's chess, story and character-grid
presentations. New engines can implement that protocol; a new presentation needs
an explicit frontend composition instead of pretending every game has a board.

Glulx advances in Glulxe's single-turn mode. Each action runs against a copy of
the last accepted opaque autosave pair. Output is decoded as complete JSON
objects, including multiline RemGlk stanzas. A rejected capability or crashed
interpreter leaves the previous snapshot and display available. Snapshots bundle
opaque native bytes with the derived display and require the same story and
interpreter build. The adapter never decodes or edits the VM state.

The catalog distinguishes interactive tile cells from passive character rows.
This keeps coordinate selection reusable without building thousands of focus
objects for a dense character surface. Neither component owns game rules,
networking, animation timing or a second copy of application state.
