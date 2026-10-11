# etaf-gamekit

Game kernels with rich, native ETAF frontends. GameKit supplies asynchronous
sessions, a versioned command/observation protocol and an included headless Godot
bridge. Applications compose their interface from ETAF and etaf-ui; the game
process owns simulation, rules and saved state.

The maintained game, **Salvage Station**, has a live station map, navigation,
security drones, skills, cargo, target inspection and save/restore. Its frontend
reflows panels around a fixed-size map at different window widths and heights. Godot supplies physics and pathfinding;
it opens no game-rendering window.

Requires Emacs 29.1+, sibling ETAF/etaf-ui checkouts and Godot 4.7+.
Python 3.9+ installs the pinned Godot 4.7.2 binary on macOS or Linux x86-64/arm64:

```sh
make engine
# Or: python3 scripts/setup-engine.py --godot /path/to/godot
```

Add the repository roots of this package and its dependencies to `load-path`:

```elisp
(require 'etaf-gamekit)
(etaf-gamekit-open-demo)
```

Press **P** to launch or pause. Click empty deck to navigate; click an object to
inspect it. **W A S D** steer, **1** fires an EMP and **2** activates a shield.
Recover three cores, then return to the extraction dock. Save and Load preserve
an expedition; restored games start paused.

The core accepts application-defined observation objects rather than a fixed
set of game genres. Other runtimes can implement the same protocol. Multiplayer,
asset downloading and audio mixing are not provided by this MVP.

See [the manual](docs/manual.md) for integration, saving and recovery,
[the package entry](etaf-gamekit.el) for supported APIs, and
[architecture](docs/architecture.md) for ownership and backend selection.
Run `make check` after installing the engine.
