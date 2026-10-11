# etaf-gamekit

An MVP for running mature game engines in native Emacs buffers through ETAF.
Glulxe/RemGlk executes interactive fiction; python-chess owns chess rules and
Stockfish supplies computer moves. The frontend handles presentation and input.

Requires Emacs 29.1+, sibling ETAF and etaf-ui checkouts, Python 3.9+, a C compiler
and Make. Engine sources are pinned and downloaded into a user cache; they are
not vendored into this package. macOS can install the pinned Stockfish binary.
On other Unix systems, install Stockfish first or pass its path to the installer.

```sh
python3 scripts/setup-engines.py
# Or: python3 scripts/setup-engines.py --stockfish /path/to/stockfish
```

Add the repository roots of etaf-gamekit and its dependencies to `load-path`:

```elisp
(require 'etaf-gamekit)
;; M-x etaf-gamekit-open-demo: play The Last Beacon.
;; M-x etaf-gamekit-open-chess: select pieces or type a UCI move such as e2e4.
```

Chess includes legal-move highlights, promotion choices, a Stockfish move action,
undo, restart and snapshots. Story sessions support Glk text-buffer/text-grid
windows and line/character input. Each game owns a separate asynchronous process;
closing its buffer releases the session. Unsupported Glk capabilities are
reported explicitly. This release does not provide multiplayer, physics, a
universal game-state model or a claim of compatibility with every Glk story.

See [the manual](docs/manual.md) for play, saving, extension and recovery;
[the package entry](etaf-gamekit.el) is the supported API inventory.
[Architecture](docs/architecture.md) describes the implemented ownership boundary.
Run `make engines`, then `make check` for the public integration suite.
