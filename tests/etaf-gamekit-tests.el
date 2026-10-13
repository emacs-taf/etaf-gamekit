;;; -*- lexical-binding: t; -*-
;;; etaf-gamekit-tests.el --- Public game session acceptance

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'ert)
(require 'etaf-gamekit)
(require 'etaf-ui)

(defconst etaf-gamekit-test--directory
  (file-name-directory (or load-file-name buffer-file-name)))

(etaf-gamekit-register-backend 'gamekit-test-peer
  :title "Controllable protocol peer" :features '(test-peer)
  :launch (lambda (options)
            (list "python3" (expand-file-name "fixtures/adapter.py" etaf-gamekit-test--directory)
                  (plist-get options :mode))) :replace t)

(defun etaf-gamekit-test--wait (session &optional predicate)
  "Wait for SESSION's state and publication, optionally until PREDICATE holds."
  (let ((deadline (+ (float-time) 10)))
    (while (and (< (float-time) deadline)
                (or (memq (etaf-gamekit-status session) '(starting busy))
                    (and predicate (not (funcall predicate)))))
      (accept-process-output nil 0.01))
    (sleep-for 0.06)
    (should-not (memq (etaf-gamekit-status session) '(starting busy)))
    (when predicate (should (funcall predicate)))))

(defun etaf-gamekit-test--dispose (session)
  "Release SESSION and the buffer owned by this scenario."
  (when session
    (etaf-gamekit-close session)
    (when (buffer-live-p (etaf-gamekit-buffer session))
      (kill-buffer (etaf-gamekit-buffer session)))))

(defun etaf-gamekit-test--text (session)
  "Read SESSION's rendered text without properties."
  (with-current-buffer (etaf-gamekit-buffer session)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun etaf-gamekit-test--peer (mode &optional validator)
  "Connect a public session to the fixture in MODE with optional VALIDATOR."
  (etaf-gamekit-define-game etaf-gamekit-test--peer-game
   :title "Transport contract" :backend 'gamekit-test-peer
   :validate (or validator
                 (lambda (value)
                   (and (equal (plist-get value :schema) "fixture/1")
                        (proper-list-p (plist-get value :rows))
                        (cl-every #'stringp (plist-get value :rows)) t)))
   :view (lambda (session)
           (etaf-view
            (column
              (etaf-text-grid :columns 8 :rows 1
                :row-text (lambda (row) (or (nth row (etaf-gamekit-view session :rows)) "")))
              (etaf-label :text (or (etaf-gamekit-last-error session) "Ready"))))))
  (etaf-gamekit-start etaf-gamekit-test--peer-game :options (list :mode mode)))

(etaf-gamekit-define-game etaf-gamekit-test--tabletop
  :title "Tabletop rules" :backend 'boardgame-io
  :options (list :game (expand-file-name "fixtures/tabletop.cjs" etaf-gamekit-test--directory)
                 :num-players 2 :player "0" :seed "contract"))

(etaf-gamekit-define-game etaf-gamekit-test--poker
  :title "Poker rules" :backend 'openspiel
  :options '(:game "kuhn_poker" :player 0 :seed 42))

(etaf-gamekit-define-game etaf-gamekit-test--xiangqi
  :title "Xiangqi rules" :backend 'openspiel
  :options '(:game "xiangqi" :player 0 :seed 7))

(ert-deftest etaf-gamekit-game-definitions-create-independent-instances ()
  "A game definition creates independent worlds and supplies its view metadata."
  (etaf-gamekit-define-game etaf-gamekit-test--independent
    :title "Independent game" :backend 'gamekit-test-peer :options '(:mode "split")
    :view (lambda (instance)
            (etaf-view (text (expr (plist-get (etaf-gamekit-game-info instance) :title))))))
  (let (first second)
    (unwind-protect
        (progn
          (setq first (etaf-gamekit-start etaf-gamekit-test--independent)
                second (etaf-gamekit-start etaf-gamekit-test--independent))
          (should (string-match-p "Independent game" (etaf-gamekit-test--text first)))
          (should-not (eq (etaf-gamekit-buffer first) (etaf-gamekit-buffer second)))
          (etaf-gamekit-test--wait first) (etaf-gamekit-test--wait second)
          (etaf-gamekit-action first "step") (etaf-gamekit-test--wait first)
          (should (= (plist-get (etaf-gamekit-observation first) :count) 1))
          (should (= (plist-get (etaf-gamekit-observation second) :count) 0))
          (aset (plist-get (etaf-gamekit-game-info first) :title) 0 ?X)
          (should (equal (plist-get (etaf-gamekit-game-info first) :title) "Independent game"))
          (should-error (etaf-gamekit-start 'godot) :type 'etaf-gamekit-error))
      (etaf-gamekit-test--dispose first) (etaf-gamekit-test--dispose second))))

(ert-deftest etaf-gamekit-backend-registration-preserves-owned-games ()
  "Replacing/removing an adapter affects future starts without taking live games."
  (let ((options (list :mode "split" :payload (vector (copy-sequence "safe"))))
        first second)
    (unwind-protect
        (progn
          (etaf-gamekit-register-backend 'gamekit-extension-test :title "Extension" :features '(test)
            :launch (lambda (configuration)
                      (aset (aref (plist-get configuration :payload) 0) 0 ?X)
                      (list "python3" (expand-file-name "fixtures/adapter.py" etaf-gamekit-test--directory)
                            (plist-get configuration :mode))))
          (etaf-gamekit-define-game etaf-gamekit-test--extension
            :backend 'gamekit-extension-test :options options)
          (setq first (etaf-gamekit-start etaf-gamekit-test--extension))
          (etaf-gamekit-test--wait first)
          (should (equal (aref (plist-get options :payload) 0) "safe"))
          (should-error
           (etaf-gamekit-register-backend 'gamekit-extension-test :title "Duplicate" :launch #'identity)
           :type 'etaf-gamekit-error)
          (etaf-gamekit-register-backend 'gamekit-extension-test :title "Replacement" :replace t
            :launch (lambda (_) (list "python3" (expand-file-name "fixtures/adapter.py" etaf-gamekit-test--directory) "crash")))
          (setq second (etaf-gamekit-start etaf-gamekit-test--extension))
          (etaf-gamekit-test--wait second)
          (should (eq (etaf-gamekit-status second) 'failed))
          (should (etaf-gamekit-unregister-backend 'gamekit-extension-test))
          (should-error (etaf-gamekit-start etaf-gamekit-test--extension) :type 'etaf-gamekit-error)
          (etaf-gamekit-action first "step") (etaf-gamekit-test--wait first)
          (should (= (plist-get (etaf-gamekit-observation first) :count) 1)))
      (etaf-gamekit-test--dispose first) (etaf-gamekit-test--dispose second)
      (etaf-gamekit-unregister-backend 'gamekit-extension-test))))

(ert-deftest etaf-gamekit-game-configurations-are-validated-and-detached ()
  "Game options are detached data; invalid definitions and overrides fail clearly."
  (let ((options (list :mode (copy-sequence "split"))))
    (etaf-gamekit-define-game etaf-gamekit-test--configured :backend 'gamekit-test-peer :options options)
    (aset (plist-get options :mode) 0 ?X)
    (let ((session (etaf-gamekit-start etaf-gamekit-test--configured)))
      (unwind-protect
          (progn (etaf-gamekit-test--wait session) (should (eq (etaf-gamekit-status session) 'ready)))
        (etaf-gamekit-test--dispose session))))
  (should-error (etaf-gamekit-start etaf-gamekit-test--poker :options '("game" "kuhn_poker"))
                :type 'etaf-gamekit-error)
  (should-error (etaf-gamekit-start etaf-gamekit-test--poker :options '(:typo 1))
                :type 'etaf-gamekit-error)
  (should-error (etaf-gamekit-define-game etaf-gamekit-test--invalid :backend 3)
                :type 'etaf-gamekit-error))

(ert-deftest etaf-gamekit-games-route-actions-to-different-native-kernels ()
  "Game definitions run boardgame.io turns and OpenSpiel poker through one API."
  (let ((tabletop (etaf-gamekit-start etaf-gamekit-test--tabletop))
        (poker (etaf-gamekit-start etaf-gamekit-test--poker)))
    (unwind-protect
        (progn
          (etaf-gamekit-test--wait tabletop) (etaf-gamekit-test--wait poker)
          (should (eq (plist-get (etaf-gamekit-game-info tabletop) :backend) 'boardgame-io))
          (etaf-gamekit-action tabletop "move" '(:name "claim" :args [2]))
          (etaf-gamekit-test--wait tabletop)
          (should (= (plist-get (plist-get (plist-get (etaf-gamekit-observation tabletop) :state) :G) :pool) 10))
          (etaf-gamekit-action tabletop "event" '(:name "endTurn"))
          (etaf-gamekit-test--wait tabletop)
          (should (equal (plist-get (plist-get (plist-get (etaf-gamekit-observation tabletop) :state) :ctx) :currentPlayer) "1"))
          (dolist (action '(("act" :action 0) ("set-player" :player 1) ("act" :action 0)))
            (etaf-gamekit-action poker (car action) (cdr action))
            (etaf-gamekit-test--wait poker)
            (should-not (etaf-gamekit-last-error poker)))
          (should (eq (plist-get (etaf-gamekit-observation poker) :terminal) t))
          (should (equal (etaf-gamekit-view poker) (etaf-gamekit-observation poker)))
          (should-not (plist-get (etaf-gamekit-observation poker) :legal_actions)))
      (etaf-gamekit-test--dispose tabletop) (etaf-gamekit-test--dispose poker))))

(ert-deftest etaf-gamekit-game-snapshots-restore-through-the-same-action-api ()
  "Opaque native/replay snapshots restore observations without frontend parsing."
  (dolist (case (list (list etaf-gamekit-test--tabletop "move" '(:name "claim" :args [2]))
                     (list etaf-gamekit-test--poker "act" '(:action 0))))
    (let ((session (etaf-gamekit-start (car case))) (file (make-temp-file "gamekit-snapshot-")))
      (unwind-protect
          (progn
            (etaf-gamekit-test--wait session)
            (etaf-gamekit-action session (cadr case) (caddr case)) (etaf-gamekit-test--wait session)
            (let ((before (etaf-gamekit-observation session)))
              (dolist (action `(("save" :path ,file) ("reset") ("load" :path ,file)))
                (etaf-gamekit-action session (car action) (cdr action))
                (etaf-gamekit-test--wait session)
                (should-not (etaf-gamekit-last-error session)))
              (should (equal (etaf-gamekit-observation session) before))))
        (etaf-gamekit-test--dispose session) (delete-file file)))))

(ert-deftest etaf-gamekit-openspiel-bot-answers-for-the-side-to-move ()
  "The OpenSpiel adapter plays a search move and keeps it undoable."
  (let ((session (etaf-gamekit-start etaf-gamekit-test--xiangqi)))
    (unwind-protect
        (progn
          (etaf-gamekit-test--wait session)
          (should (member "bot" (etaf-gamekit-capabilities session)))
          (etaf-gamekit-action session "bot" '(:policy "search" :depth 3 :seconds 1))
          (etaf-gamekit-test--wait session)
          (should-not (etaf-gamekit-last-error session))
          (let* ((observation (etaf-gamekit-observation session))
                 (report (plist-get observation :bot)))
            (should (= 1 (plist-get observation :action_count)))
            (should (= 1 (plist-get observation :current_player)))
            (should (eq t (plist-get observation :can_undo)))
            (should (equal "search" (plist-get report :policy)))
            (should (= 3 (plist-get report :depth)))
            (should (stringp (plist-get report :label))))
          (etaf-gamekit-action session "undo" '(:count 2))
          (etaf-gamekit-test--wait session)
          (should-not (etaf-gamekit-last-error session))
          (should (= 0 (plist-get (etaf-gamekit-observation session) :action_count)))
          (should (eq t (plist-get (etaf-gamekit-observation session) :can_redo))))
      (etaf-gamekit-test--dispose session))))

(ert-deftest etaf-gamekit-bot-policies-follow-the-game ()
  "The search policy needs a supported evaluation; random plays any turn-based game."
  (let ((session (etaf-gamekit-start etaf-gamekit-test--poker)))
    (unwind-protect
        (progn
          (etaf-gamekit-test--wait session)
          (should (member "bot" (etaf-gamekit-capabilities session)))
          (etaf-gamekit-action session "bot" '(:policy "search" :depth 2 :seconds 1))
          (etaf-gamekit-test--wait session)
          (should (etaf-gamekit-last-error session))
          (etaf-gamekit-action session "bot" '(:policy "random"))
          (etaf-gamekit-test--wait session)
          (should-not (etaf-gamekit-last-error session))
          (should (= 1 (plist-get (etaf-gamekit-observation session) :action_count))))
      (etaf-gamekit-test--dispose session))))

(ert-deftest etaf-gamekit-transport-fragments-detached-values-and-bounded-input ()
  "Fragments decode safely, reads detach ownership and eight inputs retain order."
  (let ((session (etaf-gamekit-test--peer "split")))
    (unwind-protect
        (progn
          (etaf-gamekit-test--wait session)
          (dolist (view (list (etaf-gamekit-observation session) (etaf-gamekit-view session)))
            (aset (car (plist-get view :rows)) 0 ?X))
          (aset (car (etaf-gamekit-capabilities session)) 0 ?X)
          (should (equal (car (plist-get (etaf-gamekit-observation session) :rows)) "frame-0"))
          (should (equal (etaf-gamekit-capabilities session) '("step")))
          (should-error (etaf-gamekit-action session "absent") :type 'etaf-gamekit-error)
          (should-error (etaf-gamekit-action session "step" (list :bad (current-buffer)))
                        :type 'etaf-gamekit-error)
          (should-error (etaf-gamekit-action session "step" (list :huge (make-string (* 1024 1024) ?x)))
                        :type 'etaf-gamekit-error)
          (dotimes (_ 8) (etaf-gamekit-action session "step"))
          (should-error (etaf-gamekit-action session "step") :type 'etaf-gamekit-error)
          (etaf-gamekit-test--wait session)
          (should (= (plist-get (etaf-gamekit-observation session) :count) 8))
          (should (eq (etaf-gamekit-status session) 'ready)))
      (etaf-gamekit-test--dispose session))))

(ert-deftest etaf-gamekit-large-observations-remain-detached ()
  "A large flat native tensor remains usable without consuming Lisp call depth."
  (let ((session (etaf-gamekit-test--peer "large")))
    (unwind-protect
        (progn
          (etaf-gamekit-test--wait session)
          (should (eq (etaf-gamekit-status session) 'ready))
          (let ((tensor (etaf-gamekit-view session :tensor)))
            (should (= 4000 (length tensor)))
            (should (= 3999 (car (last tensor))))
            (setcar tensor -1)
            (should (= 0 (car (plist-get (etaf-gamekit-observation session) :tensor)))))
          (etaf-gamekit-action session "step")
          (etaf-gamekit-test--wait session)
          (should (= 1 (plist-get (etaf-gamekit-view session) :count))))
      (etaf-gamekit-test--dispose session))))

(ert-deftest etaf-gamekit-transport-coalesces-to-the-newest-visible-frame ()
  "A burst preserves the final backend observation and displayed characters."
  (let ((session (etaf-gamekit-test--peer "burst")))
    (unwind-protect
        (progn
          (etaf-gamekit-test--wait session)
          (etaf-gamekit-action session "step")
          (etaf-gamekit-test--wait session
            (lambda () (equal (car (plist-get (etaf-gamekit-observation session) :rows)) "00000100")))
          (should (string-match-p "00000100" (etaf-gamekit-test--text session))))
      (etaf-gamekit-test--dispose session))))

(ert-deftest etaf-gamekit-transport-rejects-stale-invalid-and-dead-peers ()
  "Invalid schemas, stale replies, oversized messages and dead peers fail clearly."
  (dolist (mode '("stale" "malformed" "bad-object" "bad-observation" "missing-field"
                 "empty-error" "uncorrelated" "oversized" "crash" "hang"))
    (let* ((etaf-gamekit-request-timeout 0.3)
           (session (etaf-gamekit-test--peer mode)))
      (unwind-protect
          (progn
            (etaf-gamekit-test--wait session)
            (when (equal mode "stale")
              (etaf-gamekit-action session "step") (etaf-gamekit-test--wait session))
            (should (eq (etaf-gamekit-status session) 'failed))
            (should (stringp (etaf-gamekit-last-error session)))
            (when (equal mode "crash")
              (should (string-match-p "fixture engine stopped" (etaf-gamekit-last-error session)))
              (should-not (string-match-p "Process .* finished" (etaf-gamekit-last-error session))))
            (should-error (etaf-gamekit-action session "step") :type 'etaf-gamekit-error))
        (etaf-gamekit-test--dispose session)))))

(ert-deftest etaf-gamekit-schema-validator-errors-fail-the-session ()
  "A supplied validator failure is reported with connection state and context."
  (let ((session (etaf-gamekit-test--peer "split" (lambda (_) (error "Bad schema revision")))))
    (unwind-protect
        (progn
          (etaf-gamekit-test--wait session)
          (should (eq (etaf-gamekit-status session) 'failed))
          (should (string-match-p "Bad schema revision" (etaf-gamekit-last-error session))))
      (etaf-gamekit-test--dispose session))))

(ert-deftest etaf-gamekit-close-unmount-and-buffer-death-release-the-child ()
  "Explicit close, unmount and buffer death release the child idempotently."
  (dolist (operation '(close unmount kill))
    (let ((session (etaf-gamekit-test--peer "split")))
      (unwind-protect
          (progn
            (etaf-gamekit-test--wait session)
            (let ((pid (plist-get (etaf-gamekit-observation session) :pid)))
              (pcase operation
                ('close (etaf-gamekit-close session))
                ('unmount (etaf-unmount (etaf-runtime-for-buffer (etaf-gamekit-buffer session))))
                ('kill (kill-buffer (etaf-gamekit-buffer session))))
              (etaf-gamekit-close session)
              (should (eq (etaf-gamekit-status session) 'closed))
              (let ((deadline (+ (float-time) 3)))
                (while (and (process-attributes pid) (< (float-time) deadline))
                  (accept-process-output nil 0.01)))
              (should-not (process-attributes pid))))
        (etaf-gamekit-test--dispose session)))))

(ert-deftest etaf-gamekit-observations-preserve-an-action-rejection ()
  "An unsolicited display frame cannot erase the last action's rejection."
  (let ((session (etaf-gamekit-test--peer "rejection")))
    (unwind-protect
        (progn
          (etaf-gamekit-test--wait session)
          (etaf-gamekit-action session "step")
          (etaf-gamekit-test--wait session)
          (should (eq (etaf-gamekit-status session) 'ready))
          (should (equal (etaf-gamekit-last-error session) "Action rejected"))
          (should (string-match-p "Action rejected" (etaf-gamekit-test--text session))))
      (etaf-gamekit-test--dispose session))))

(defun etaf-gamekit-test--clock-project (rate)
  "Create an owned SDK fixture configured with Godot setting RATE."
  (let ((directory (make-temp-file "gamekit-clock-" t)))
    (copy-file (expand-file-name "fixtures/clock.gd" etaf-gamekit-test--directory)
               (expand-file-name "clock.gd" directory))
    (with-temp-file (expand-file-name "project.godot" directory)
      (insert "config_version=5\n[application]\nrun/flush_stdout_on_print=true\n"
              "[gamekit]\ngame_script=\"res://clock.gd\"\nobservation_hz=" rate "\n"))
    directory))

(etaf-gamekit-define-game etaf-gamekit-test--clock :backend 'godot :title "Native clock")

(ert-deftest etaf-gamekit-godot-project-controls-stream-cadence ()
  "A project's rate changes autonomous observation spacing, not its clock."
  (dolist (rate '(1 60))
    (let ((directory (etaf-gamekit-test--clock-project (number-to-string rate))) session)
      (unwind-protect
          (progn
            (setq session (etaf-gamekit-start etaf-gamekit-test--clock :options (list :project directory)))
            (etaf-gamekit-test--wait session)
            (etaf-gamekit-action session "run")
            (etaf-gamekit-test--wait session)
            ;; Compare two native timestamps; no dependency on wall-clock
            ;; benchmark budgets or any private bridge representation.
            (let ((previous (plist-get (etaf-gamekit-observation session) :seconds)))
              (etaf-gamekit-test--wait session
                (lambda () (> (plist-get (etaf-gamekit-observation session) :seconds) previous))))
            (let* ((before (plist-get (etaf-gamekit-observation session) :seconds))
                   (deadline (+ (float-time) 5)) after)
              (while (and (< (float-time) deadline)
                          (<= (setq after (plist-get (etaf-gamekit-observation session) :seconds)) before))
                (accept-process-output nil 0.002))
              (let ((advance (- after before)))
                (should (> advance 0))
                (if (= rate 1) (should (> advance 0.5)) (should (< advance 0.25)))))
            (should-not (etaf-gamekit-last-error session)))
        (etaf-gamekit-test--dispose session) (delete-directory directory t)))))

(ert-deftest etaf-gamekit-godot-preserves-batched-input-order ()
  "A full outstanding native command burst acknowledges every input in order."
  (let ((directory (etaf-gamekit-test--clock-project "60")) session)
    (unwind-protect
        (progn
          (setq session (etaf-gamekit-start etaf-gamekit-test--clock :options (list :project directory)))
          (etaf-gamekit-test--wait session)
          (dotimes (index 8) (etaf-gamekit-action session "tag" (list :value index)))
          (etaf-gamekit-test--wait session)
          (let ((tags (plist-get (etaf-gamekit-observation session) :tags)))
            (should (= (length tags) 8))
            (should (cl-every #'= tags '(0 1 2 3 4 5 6 7))))
          (should-not (etaf-gamekit-last-error session)))
      (etaf-gamekit-test--dispose session) (delete-directory directory t))))

(ert-deftest etaf-gamekit-godot-rejects-invalid-stream-rates ()
  "Invalid project settings fail startup and surface the actionable reason."
  (dolist (rate '("0" "61" "\"fast\""))
    (let ((directory (etaf-gamekit-test--clock-project rate)) session)
      (unwind-protect
          (progn
            (setq session (etaf-gamekit-start etaf-gamekit-test--clock :options (list :project directory)))
            (etaf-gamekit-test--wait session)
            (should (eq (etaf-gamekit-status session) 'failed))
            (should (string-match-p "observation_hz must be" (etaf-gamekit-last-error session))))
        (etaf-gamekit-test--dispose session) (delete-directory directory t)))))

(provide 'etaf-gamekit-tests)
;;; etaf-gamekit-tests.el ends here
