.DEFAULT_GOAL := check
.NOTPARALLEL:
EMACS ?= emacs
LOAD_PATH = -L . -L lisp -L ../etaf-ui -L ../etaf -L ../ebox -L ../ecss -L ../etaf/scripts
SOURCES = lisp/etaf-gamekit-session.el lisp/etaf-gamekit-view.el lisp/etaf-gamekit-salvage.el etaf-gamekit.el benchmarks/performance-scenarios.el tests/etaf-gamekit-tests.el scripts/etaf-gamekit-gui-scenarios.el

.PHONY: compile test check clean structure-check setup-hooks acceptance api-check engine engine-check tool-test
compile:
	rm -f *.elc lisp/*.elc tests/*.elc benchmarks/*.elc scripts/etaf-gamekit-gui-scenarios.elc
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' \
		--eval '(require (quote cl-lib))' \
		--eval '(unless (cl-every (function byte-compile-file) (quote ($(foreach file,$(SOURCES),"$(file)")))) (kill-emacs 1))'
structure-check:
	python3 scripts/check-repository.py
engine:
	python3 scripts/setup-engine.py
engine-check:
	python3 scripts/setup-engine.py --check
acceptance: engine-check
	python3 scripts/run-acceptance.py --emacs "$(EMACS)"
tool-test: engine-check
	python3 -m unittest discover -s tests/tools -p 'test_*.py'
api-check:
	$(EMACS) -Q --batch $(LOAD_PATH) --eval '(setq load-prefer-newer t)' -l scripts/check-api.el
test: acceptance tool-test
check: structure-check compile acceptance tool-test api-check
clean:
	rm -f *.elc lisp/*.elc tests/*.elc benchmarks/*.elc scripts/etaf-gamekit-gui-scenarios.elc
setup-hooks:
	git config --local core.hooksPath .githooks
