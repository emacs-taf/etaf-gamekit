.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
GAMEKIT_PYTHON ?= python3
GAMEKIT_CACHE ?= $(if $(XDG_CACHE_HOME),$(XDG_CACHE_HOME),$(HOME)/.cache)/emacs-taf/game-engines
LOAD_PATH = -L . -L lisp -L ../etaf-ui -L ../etaf -L ../ebox -L ../ecss
SOURCES = lisp/etaf-gamekit-session.el lisp/etaf-gamekit-backends.el lisp/etaf-gamekit-game.el lisp/etaf-gamekit-frame.el lisp/etaf-gamekit-view.el etaf-gamekit.el benchmarks/performance-scenarios.el tests/etaf-gamekit-tests.el

.PHONY: compile test check clean structure-check setup-hooks acceptance api-check engine engine-check tool-test engine-all engine-boardgame-io engine-openspiel
compile: clean
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' --eval '(require (quote cl-lib))' --eval '(unless (cl-every (function byte-compile-file) (quote ($(foreach file,$(SOURCES),"$(file)")))) (kill-emacs 1))'
structure-check:
	python3 scripts/check-repository.py
engine:
	python3 scripts/setup-engine.py
engine-boardgame-io:
	npm ci --prefix native/boardgame-io --ignore-scripts --no-audit --no-fund
engine-openspiel:
	$(GAMEKIT_PYTHON) -c 'import sys; assert sys.version_info >= (3, 11), "Set GAMEKIT_PYTHON to Python 3.11 or newer"'
	$(GAMEKIT_PYTHON) -m venv "$(GAMEKIT_CACHE)/openspiel"
	"$(GAMEKIT_CACHE)/openspiel/bin/python" -m pip install -r native/openspiel/requirements.txt
engine-all: engine engine-boardgame-io engine-openspiel
engine-check:
	python3 scripts/setup-engine.py --check
	node native/boardgame-io/bridge.cjs --version
	"$(GAMEKIT_CACHE)/openspiel/bin/python" native/openspiel/bridge.py --version
acceptance: engine-check
	python3 scripts/run-acceptance.py --emacs "$(EMACS)"
tool-test: engine-check
	python3 -m unittest discover -s tests/tools -p 'test_*.py'
api-check:
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(setq load-prefer-newer t)' -l scripts/check-api.el
test: acceptance tool-test
check: structure-check compile acceptance tool-test api-check
clean:
	rm -f *.elc lisp/*.elc tests/*.elc benchmarks/*.elc scripts/*.elc
setup-hooks:
	git config --local core.hooksPath .githooks
