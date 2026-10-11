# Using etaf-gamekit

## Install and play

`make engine` installs the pinned Godot runtime from the official release assets
listed with SHA-256 checksums in `scripts/engine-sources.json`. Python 3.9+ is
required for setup. The installer supports macOS universal and Linux x86-64/arm64
builds. `python3 scripts/setup-engine.py --godot /path/to/godot` registers an
existing Godot 4.7+ executable instead.

Downloads and installation files stay under
`~/.cache/emacs-taf/game-engines`, or the corresponding `XDG_CACHE_HOME` directory.
The stable command is `bin/godot` inside that cache. `--cache DIRECTORY` selects
another cache; then set `etaf-gamekit-godot-program` to its `bin/godot` before
opening a session. `--check` checks the executable without modifying files;
`--manifest` prints the pinned sources. Setup does not change PATH or Emacs init.

Add this repository and its ETAF/etaf-ui dependencies to `load-path`, require
`etaf-gamekit`, and run `M-x etaf-gamekit-open-demo`. The game starts in tactical
pause, with three cores to recover and three hostile security drones.

| Input | Effect |
| --- | --- |
| P / Launch / Pause | Start or pause simulation time |
| W A S D | Extend the navigation destination by one cardinal tile |
| Click empty deck | Plot a route around bulkheads |
| Click a unit/core/dock | Select it in target intelligence |
| Plot route to target | Navigate to the inspected core or extraction dock |
| 1 / EMP pulse | Spend 20 energy to disable drones within five tiles; four-second cooldown |
| 2 / Shield | Spend 25 energy for five seconds of protection |
| Cargo → Use repair kit | Consume one of two kits to restore up to 40 hull |
| Objectives | Show the recovery and extraction goals |
| F1 / Help | Open the flight manual |

Godot owns motion, collision, pathfinding, enemy movement, energy recovery,
damage, score and victory/defeat. The frontend owns selection, open tabs and
dialogs. Navigation can be plotted while paused. Skills and commands are
validated again by the game process; the frontend cannot override game rules.

The map keeps its intrinsic **32×18 cells**, each two character columns wide
and one text row high. Window changes never stretch the world or its glyphs.
The workbench has a bounded width and stays centered in wider windows; its
header, metrics and controls share the same outer edges. Narrow tall windows
place the side panels below the map. Narrow short windows open them through
**Panels** in the header. Selection and the active cargo tab survive reflow.

The minimum canvas is 76 character columns by 30 text rows; its pixel width
follows the user's font. Smaller viewports clip/scroll the original canvas.
Native soft wrapping is disabled so clipped rows cannot spill into each other.
Secondary captions and spacing reduce at short heights; tile dimensions stay
unchanged.

## Save, recover and close

Save and Load prompt for an explicit local snapshot path. Save publishes the
file atomically. A snapshot preserves position, cargo, remaining enemies,
resources, cooldowns, score, elapsed time and recent events. Loading validates
the snapshot before changing the world and resumes in tactical pause with
navigation routes cleared. Snapshot bytes are owned by this game version;
applications should pass paths rather than interpret or modify saved state.

A rejected action or invalid snapshot keeps the connection usable and displays
its reason. A protocol error, deadline or unexpected process exit marks the
session failed, preserving the last observation. Reopen the game and load an
explicit snapshot to recover. Closing, killing or unmounting the game buffer
releases its process; no implicit save is made. Independent sessions own
independent game state.

The startup/action deadline defaults to 15 seconds and is configured by
`etaf-gamekit-request-timeout`. Up to eight requests may be outstanding, with
acknowledgments accepted in order. Each request's deadline starts when it is
sent; a full queue rejects additional calls synchronously. This bounded queue
preserves short input bursts without accepting unlimited buffered movement.
Unsolicited frames never clear the latest action rejection. A successful
acknowledgment clears it.

## Adapter contract

Supported callers are Emacs applications using the package entry and external
processes implementing this protocol. The Emacs caller owns the returned
session and closes it when finished. The process owns authoritative state.
Observations and capability lists returned to callers are detached copies;
mutating them cannot change the process or session state. Full signatures and
error constraints are in [the entry Commentary](../etaf-gamekit.el).

`etaf-gamekit-start` receives a program/argument list, plus optional `:buffer`,
`:view` and `:validate` keywords. The view factory receives the session and
returns an ETAF View. The validator receives a detached observation and must
return exactly `t`; rejection or a signaled error fails the connection with
context. Omitting the view factory displays connection status. Omitting the
validator still enforces the transport envelope and an object observation.
Programmatic start does not select a window.

```elisp
(let ((session
       (etaf-gamekit-start
        '("my-game-adapter" "--stdio")
        :validate (lambda (state) (stringp (plist-get state :title)))
        :view (lambda (game)
                (etaf-view
                 (etaf-panel :title "Expedition"
                   (etaf-label :text (or (etaf-gamekit-view game :title) "Connecting"))
                   (etaf-label :text (or (etaf-gamekit-last-error game) ""))))))))
  (display-buffer (etaf-gamekit-buffer session)))
```

Use `etaf-gamekit-view` inside views and computed values. Its optional top-level
field argument avoids copying unrelated fields; use value equality on computed
JSON fields to avoid invalidating unchanged panels. `etaf-gamekit-observation`
returns the latest accepted state immediately. Unsolicited display publication
is coalesced to at most 60 Hz; intermediate stream frames may never be painted.
Acknowledged input publishes on the next Emacs event-loop turn, sharing one
publication for a response burst. Rendering time and the event loop add to
these scheduling intervals.

Transport uses UTF-8 JSON objects separated by newlines, with at most 1 MiB per
JSON value. stdout is exclusively protocol data; diagnostic text belongs on
stderr. Requests contain protocol version 1, a positive increasing integer ID,
an operation string and an argument object. Emacs arguments use keyword plists
for objects and vectors for arrays. The first operation is `start`.

```json
{"version":1,"id":1,"op":"start","args":{}}
{"version":1,"id":2,"op":"navigate","args":{"x":12,"y":3}}
```

Every response includes these fields; additional application state belongs in
`observation`:

```json
{"version":1,"id":2,"revision":7,"capabilities":["navigate","save","load"],"observation":{"schema":"my-game/1","title":"Station","entities":[]},"error":null}
```

`revision` is a strictly increasing integer across responses and unsolicited
observations. An acknowledgment echoes the oldest outstanding request ID;
an unsolicited observation uses `id: null` and `error: null`. `capabilities` is
an array of advertised action names. A rejected action echoes its ID, provides
a nonempty error string and returns the current valid observation. A stale,
uncorrelated or malformed response fails the connection. EOF means shutdown.

Decoded objects are keyword plists, arrays are lists, false is `:false`, and
null is nil. The application chooses its observation schema; there is no
chess/story/grid enumeration. Observations describe game facts, not ETAF widget
trees or executable code. A game can include resource IDs in its schema and
resolve them through its own content manifest to local image/video assets.
Binary media and frame streams do not belong in these snapshots. The core does
not download assets, schedule animation or mix audio.

## Use the Godot bridge

`etaf-gamekit-open-godot` accepts a directory containing `project.godot` and the
same presentation/validation keywords as `start`. It starts the configured
Godot executable with `--headless --no-header` and the shared bridge in
`native/godot/gamekit.gd`. Games do not implement stdin readers or transport.

Set `gamekit/game_script` in the project to a script that extends Node or Node2D.
The bridge creates it as a child of the scene root. The script supplies:

- `capabilities() -> Array`: currently advertised action names.
- `command(operation: String, args: Dictionary) -> String`: apply a valid action;
  return an empty string on success or an explanatory rejection without partial mutation.
- `observe() -> Dictionary`: a complete, JSON-serializable observation of current state.

The bridge handles `start` itself. Game methods and simulation run on Godot's
main thread; a separate worker reads stdin. It emits acknowledged observations
immediately after commands and changed unsolicited observations at up to 20 Hz.
Closing stdin stops the runtime. Game scripts must keep stdout free of other
messages and use stderr for diagnostics.

A minimal project can contain:

```ini
; project.godot
config_version=5
[application]
config/name="Counter"
[gamekit]
game_script="res://game.gd"
```

```gdscript
# game.gd
extends Node
var count := 0
func capabilities() -> Array:
    return ["increment"]
func command(operation: String, _args: Dictionary) -> String:
    if operation != "increment":
        return "Unsupported action"
    count += 1
    return ""
func observe() -> Dictionary:
    return {"schema": "counter/1", "count": count}
```

```elisp
(etaf-gamekit-open-godot
 "/path/to/counter"
 :view (lambda (game)
         (etaf-view
          (etaf-panel :title "Counter"
            (etaf-label :text (format "%s" (or (etaf-gamekit-view game :count) 0)))
            (etaf-button :label "Increment"
              :disabled (memq (etaf-gamekit-status game) '(starting failed closed))
              :on-press (lambda () (etaf-gamekit-action game "increment")))))))
```

Salvage Station is the complete example of this contract. Its game project is
in `examples/salvage`, and its ETAF composition is loaded by the package entry.
Other engines need the same wire envelope, not a Godot dependency. Backend
selection and media boundaries are explained in [architecture](architecture.md).

## Validation and latency

`make check` runs structure/API validation, byte compilation, public session and
UI scenarios, and real Godot protocol/game scenarios. The latter play through
recovery and extraction rather than replacing the runtime with a fake engine.
Transport failure cases use a controlled external peer.

From the workspace root, select the package's maintained performance adapter:

```sh
python3 scripts/performance.py run --mode batch \
  --scenario-file etaf-gamekit/benchmarks/performance-scenarios.el \
  --load-path etaf-gamekit --scenario '^etaf-gamekit\.' \
  --sets 3 --samples 30 --warmups 5
```

It covers 80×24 text surfaces at several change densities and stream rates,
object inspection, a click through Godot pathfinding to a painted route, and
complete-game viewport refitting with fixed cell dimensions. Scenario budgets are targets, not measured
claims: 16 ms for local selection and 50 ms for backend route or full refit.
Use the workspace [performance workflow](https://forgejo.vhkd.top/emacs-taf/emacs-taf/src/branch/main/docs/manual.md) for independent
sample sets, comparisons and GUI validation. Batch results and background GUI
redisplay do not establish foreground OS input latency.

The maintained visual scenario in `scripts/etaf-gamekit-gui-scenarios.el`
uses ETAF's shared GUI verifier. In a graphical Emacs that already loads this
checkout, load the verifier and scenario adapter, then schedule the run with a
fresh evidence directory:

```elisp
(load "/path/to/etaf/scripts/emacs-gui-verifier.el" nil t t)
(load "/path/to/etaf-gamekit/scripts/etaf-gamekit-gui-scenarios.el" nil t t)
(run-at-time 0 nil #'etaf-gamekit-gui-run "/tmp/salvage-gui-evidence")
```

The scenario checks wide, ordinary, compact, short and tall layouts, fixed cell
metrics, minimum clipping, native movement, panels, object inspection, Help,
extraction and restart. It restores the frame dimensions and leaves the game
paused. Use a dedicated validation frame when changing the current layout would
interrupt other work. The shared verifier preserves application focus and writes
`result.json` plus window screenshots. Inspect those images before accepting
appearance; a passing result alone certifies only the functional assertions.
