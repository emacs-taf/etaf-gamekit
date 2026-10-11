# Architecture

GameKit separates an authoritative game kernel from native ETAF presentation.
The session contract transports commands and observations; it does not prescribe
boards, stories, widgets or a universal world model. Each application defines a
versioned observation schema and composes its own interface through ETAF and
etaf-ui. The [manual](manual.md#adapter-contract) owns the wire contract.

## Ownership and data flow

The external process owns rules, simulation time, saved state and action
validation. The Emacs session owns transport, request correlation, observation
validation and buffer lifetime. The application owns presentation, selection,
open panels and unsent input. Observations are detached values, not writable
references into authoritative game state.

Accepted observations update the session immediately. Unsolicited publication
is coalesced to at most sixty updates per second; intermediate frames may be
skipped. Acknowledged input is published on the next Emacs event-loop turn,
without waiting for the stream interval; a burst still shares one publication. Value equality prevents unchanged observation fields from
invalidating unrelated panels. Transport failure preserves the last accepted
observation and its error; closing or unmounting a session releases its process.

Salvage Station uses Godot's physics bodies, collision detection, fixed physics
steps and AStarGrid2D pathfinding. Game-specific rules, observation projection
and snapshots live in its game script. The shared Godot bridge supplies stdin
handling, ordered requests and changed-state publication at up to 20 Hz. It
opens no rendering window. All map cells, status panels, controls, dialogs and
input belong to ETAF. There is no video-frame transport in this path.

TileGrid owns reusable coordinate activation and intrinsic cell metrics.
Window adaptation reflows the surrounding panels without stretching the game
world. TextGrid supplies retained character rows for dense passive surfaces and the
transport benchmark. Neither catalog component owns game rules or backend
state. The application only calls public ETAF and etaf-ui interfaces; Ebox
remains behind ETAF.

## Backend selection

One transport protocol does not require one runtime for every game. A backend
must expose validated actions and a useful observation projection, have clear
lifetime ownership, and define save/restore behavior when it advertises it.
Serialization alone is insufficient: a save blob may be opaque and cannot
substitute for the observation needed by a rich frontend.

| Workload | Selection | Integration status |
| --- | --- | --- |
| Real-time worlds with collision, navigation and simulation | Godot in headless mode | Included bridge and maintained Salvage Station game |
| Turn-based cards, tabletop and multiplayer phases | boardgame.io is the preferred candidate for a concrete tabletop application | No adapter or dependency installed |
| Established chess, Go, shogi or mahjong rules and strong search | The game's native protocol/kernel, such as UCI, GTP, USI or mjai | Select and adapt only with a maintained game |
| Broad rules/AI experiments | OpenSpiel | Candidate library, not the default runtime |
| Existing portable puzzles | Simon Tatham's collection | Requires adapting its frontend/drawing contract; not automatically high-level JSON state |
| Persistent text worlds, roguelikes or branching narrative | Evennia, non-rendering rot.js/tcod facilities, or Ink as appropriate | Optional specialized candidates |
| Panel-heavy management games with small rule sets | A separate pure application state kernel | Can remain in-process; persistence may use ETAF DB without requiring GameKit transport |

Godot is retained because its [headless mode](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_dedicated_servers.html)
works without a display and its [navigation](https://docs.godotengine.org/en/stable/classes/class_astargrid2d.html)
and [physics bodies](https://docs.godotengine.org/en/stable/classes/class_characterbody2d.html)
are useful independently of rendering. A general runtime still requires game
rules and an observation projection. The same is true of a framework such as
[boardgame.io](https://boardgame.io/), which provides state management, turns,
phases and multiplayer rather than supplying every game's rules.

The broader candidates are not interchangeable packages of ready-made rich
interfaces. [OpenSpiel serialization](https://github.com/google-deepmind/open_spiel/blob/master/docs/api_reference/game_serialize_game_and_state.md)
is an engine serialization string, not a common JSON observation schema.
[Tatham's collection](https://www.chiark.greenend.org.uk/~sgtatham/puzzles/)
contains dozens of puzzle types and has a portable frontend/backend design;
its drawing interface still needs an ETAF-specific presentation decision.
Neither breadth nor headless support justifies installing an unused adapter.

## Rich presentation and assets

The session accepts any JSON observation object validated by the application.
It has no chess/story/grid type union. Applications can expose entities, hands,
events, inventories, timelines and resource IDs in their own schema. A resource
ID should resolve through the application's content manifest to a local asset
or explicit media source; simulation state should not contain image bytes,
rendered frames or executable UI descriptions.

Applications may compose ETAF's public image/video facilities and etaf-ui's
media viewer with the same observation API. GameKit does not yet provide asset
acquisition, animation scheduling, audio mixing or network synchronization.
Those capabilities must have a concrete consuming game and acceptance tests
before they become shared services. Salvage Station currently uses themed
native cells and panels and needs no downloaded art assets.

The maintained acceptance priority is a complete real-time game: authoritative
simulation, rich native controls, width/height adaptation, save recovery and
measured input-to-display latency. A tabletop adapter follows only when a
concrete game exercises additional requirements. This keeps the core independent
of any engine while making the included path complete and reproducible.
