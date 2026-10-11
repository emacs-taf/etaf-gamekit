# Using etaf-gamekit

## Install and play

Run `python3 scripts/setup-engines.py` from this repository. Python 3.9+, a C
compiler and Make are required. Downloads have fixed revisions and SHA-256
checksums in `scripts/engine-sources.json`. Sources, licenses, build products and
the Python environment stay in `~/.cache/emacs-taf/game-engines` (or under
`XDG_CACHE_HOME`). Use `--cache DIRECTORY` to choose another location and set
`etaf-gamekit-engine-directory` to it before opening a session.

macOS uses the pinned universal Stockfish release when Stockfish is not on PATH.
Other Unix systems require an installed Stockfish, or `--stockfish PATH`.
`--check` reports installed paths without changing them; `--manifest` prints the
upstream URLs and checksums. The installer never changes Emacs configuration.

Add this repository and its ETAF/etaf-ui dependencies to `load-path`, then
`(require 'etaf-gamekit)`. Run `M-x etaf-gamekit-open-chess` or
`M-x etaf-gamekit-open-demo`. Each opens its own buffer and process.

In chess, click a square or use Tab/arrows and Return. Select a piece and then a
highlighted destination. Set Promotion before a promotion move; the Move field
also accepts full UCI notation such as `e7e8n`. Uppercase pieces are White and
lowercase pieces are Black. **Engine move** asks Stockfish to play for the side
to move; it does not automatically take control of a color. **Undo** removes one
ply. Rules and legal moves come from python-chess. Automatic game endings are
shown; optional draw claims, clocks and network opponents are outside the MVP.

The Last Beacon is a small English Inform 6 story. Try `look`, `take lantern`,
`turn on lantern`, `north`, `take prism`, `north`, then `put prism in beacon`.
The story source lives in `examples/last-beacon.inf`. Other local `.ulx` files
can be opened with `M-x etaf-gamekit-open-story`.

The Command field uses native editing, completion keys, selection and undo.
Return submits; Escape cancels the current field edit. When a story requests a
single character, enter one character or `return`, `escape`, or `space`.
Text windows retain at most 32,000 characters each in this MVP. Native text styles
are flattened to text; status grids retain their fixed columns. This is not a
complete Glk implementation: graphics, sound, timers, hyperlinks, mouse requests
and native file dialogs are unsupported and are not advertised to the story.

## Save, recover and close

Save and Load operate on frontend snapshot files, separately from a story's
native `save` command. Choose a path in the prompt. Chess snapshots preserve the
initial position and move history, so undo still works after loading. Glulx
snapshots bundle opaque interpreter state with the displayed text and require
the same story file and interpreter build; they are not portable Glk saves.
An incompatible or invalid snapshot leaves the accepted game state unchanged.

An illegal move or unsupported action appears in the buffer and leaves the
session ready to try again. A protocol error or unexpected process exit marks
the session failed, preserving the last view and error for inspection. Open a
new session and load an explicit snapshot to recover. Closing or killing the
buffer stops its process; no implicit save is made. Different sessions do not
share engine state or temporary autosaves.

Startup and actions have a 15-second deadline, configured through
`etaf-gamekit-request-timeout`. A timeout terminates that connection and preserves
its last accepted view. Unsolicited display frames cannot erase an action error;
the next acknowledged successful action clears it.

## Integrate an adapter

The supported caller is an Emacs application using the package entry, or an
external process implementing the wire protocol. Emacs callers own the returned
session and close it when finished. They may inspect detached observations and
send advertised actions. They must not mutate observations as a way to change
the game. The full signatures and lifecycle constraints are in
[the package entry](../etaf-gamekit.el).

Programmatic opening does not select a window. After displaying its buffer, call
`etaf-refit` on `etaf-runtime-for-buffer` and that display window before immediate
input. Interactive open commands do this automatically. Board colors use
`:game-board-fg`, `:game-selected-bg`, `:game-legal-bg`,
`:game-square-light-bg` and `:game-square-dark-bg` Theme tokens with light/dark
defaults; provide overrides through ETAF's public Theme contract.

```elisp
;;; -*- lexical-binding: t; -*-
(require 'etaf-gamekit)
(let ((session (etaf-gamekit-open-chess)))
  ;; Startup is asynchronous; call from an event after status becomes ready.
  (run-at-time
   1 nil (lambda ()
           (when (eq (etaf-gamekit-status session) 'ready)
             (etaf-gamekit-action session "move" '(:move "e2e4"))))))
```

`etaf-gamekit-start` accepts a program/argument list, without shell interpretation.
The process reads and writes UTF-8 JSON objects, one per line, up to 1 MiB each.
Standard output belongs to this protocol; diagnostics go to standard error.
The host first sends `{"id":1,"op":"start","args":{}}`. Later requests have
strictly increasing integer IDs, an advertised operation string and an argument
object. There is at most one outstanding request.

Every complete response contains:

```json
{"version":1,"id":1,"revision":1,"capabilities":["move","save","load"],
 "view":{"kind":"chess","title":"Chess","status":"White to move", "board":[],
         "legal":[],"moves":[],"last_move":null,"finished":false},"error":null}
```

The example shows the envelope; an actual chess board must contain eight rows
of eight piece letters separated by single spaces. `legal` and `moves` contain
UCI strings. A response acknowledges its request even when `error` is a string;
then `view` must describe the state the backend actually retained. `revision`
increases on every response. An unsolicited observation may use `id:null`; it
never acknowledges a pending action. The frontend can skip intermediate display
frames, but always retains the newest accepted observation and response error.

`story` views contain ordered Glk window descriptors (`id`, `type`, geometry,
`text` for buffer windows, or `gridwidth`, `gridheight`, `lines` for grids), an
`input` array with window IDs and `line`/`char` types, and a `generation` number.
`grid` views contain `rows`, an array of fixed-width single-line strings, and
`columns`. Grid rows cannot contain tabs or exceed their declared display width.
These are presentation contracts, not a common game-world schema.

The built-in runner is also a supported command:

```sh
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/emacs-taf/game-engines"
printf '%s\n' '{"id":1,"op":"start","args":{}}' |
  "$CACHE/python/bin/python3" scripts/run-engine.py --adapter chess \
  --stockfish "$CACHE/bin/stockfish"
```

Its chess operations are `move` (`move` string), `engine`, `undo`, `restart`,
`save` and `load` (`path` string). Glulx adds `line`/`char` (`value` and optional
`window`), and `resize` (`width` 20–320, `height` 5–120), with `restart`, `save`
and `load`. Start Glulx with `--adapter glulx --glulxe PATH --story FILE`.
All arguments are JSON object fields. Adapter children must release their own
subprocesses on EOF or SIGTERM. No adapter receives another session's state.

## Validation

`make check` runs structure and API boundary checks, byte compilation, public
Emacs integration scenarios and command-level engine tests. `make engines`
installs the required real backends; missing engines are failures, not skipped
tests. Correctness and GUI/performance acceptance are separate.

From the workspace root, list and run the maintained workloads:

```sh
python3 scripts/performance.py list --load-path etaf-gamekit \
  --scenario-file etaf-gamekit/benchmarks/performance-scenarios.el
python3 scripts/performance.py run --mode batch --load-path etaf-gamekit \
  --scenario-file etaf-gamekit/benchmarks/performance-scenarios.el \
  --scenario 'etaf-gamekit.*' --sets 3 --samples 30 --warmups 5
```

For a real graphical Emacs with this checkout freshly loaded, use `--mode gui
--server NAME` with the same arguments. The shared driver owns sampling,
settlement, source checks and evidence. Grid steps measure request-to-display;
stream workloads observe the next displayed frame while an independent producer
runs continuously at 10, 20 or 30 Hz, changing 1%, 20% or 100% of an 80×24 surface.
Each sample records produced and observed displayed frame counts. Settlement is
polled every 5 ms; these counts are observations, not a display refresh-rate meter.
Background GUI measurements include forced redisplay but do not establish physical
keyboard/mouse-to-screen latency. Inspect the final grid and perform the play
workflow below as well as reading the timing result.

In the full user configuration, open chess and select `e2`, then `e4`; check the
selection/target colors, moved piece and last-move label. Navigate squares with
arrows, submit a UCI move in the native field, and use Engine move and Undo.
Open the demo, type the commands above with Return, save before placing the prism,
win, then load and confirm the restored room and inventory. Resize the window,
check the transcript and status grid, and close the buffers. Keep unrelated Emacs
sessions and application focus unchanged. The native command-input ERT scenario
can also run inside that graphical instance after loading the public test file.
