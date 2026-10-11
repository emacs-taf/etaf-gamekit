;;; -*- lexical-binding: t; -*-
;;; etaf-gamekit-tests.el --- Public game session acceptance

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'ert)
(require 'etaf-gamekit)

(defconst etaf-gamekit-test--directory
  (file-name-directory (or load-file-name buffer-file-name)))

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
  (etaf-gamekit-start
   (list "python3" (expand-file-name "fixtures/adapter.py" etaf-gamekit-test--directory) mode)
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
              (etaf-label :text (or (etaf-gamekit-last-error session) "Ready")))))))

(ert-deftest etaf-gamekit-salvage-controls-change-the-live-world ()
  "Tile selection, target routing and skill controls update a real game."
  (let (session)
    (unwind-protect
        (save-window-excursion
          (setq session (etaf-gamekit-open-demo))
          (etaf-gamekit-test--wait session)
          (let ((runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session))))
            (etaf-runtime-refit runtime 1200 46)
            (etaf-dispatch-event runtime 'salvage-tile-3-12 'press)
            (should (string-match-p "Power core 1" (etaf-gamekit-test--text session)))
            (etaf-dispatch-event runtime 'salvage-route-target 'press)
            (etaf-gamekit-test--wait session)
            (should (equal (car (last (plist-get (plist-get (etaf-gamekit-observation session) :world) :route)))
                           '(12 3)))
            (etaf-dispatch-event runtime 'salvage-pause 'press)
            (etaf-gamekit-test--wait
             session (lambda () (= (plist-get (plist-get (etaf-gamekit-observation session) :pilot) :cores) 1)))
            (etaf-dispatch-event runtime 'salvage-pause 'press)
            (etaf-gamekit-test--wait session)
            (should (string-match-p "1 / 3 CORES" (etaf-gamekit-test--text session)))
            (etaf-dispatch-event runtime 'salvage-shield 'press)
            (etaf-gamekit-test--wait session)
            (should (= (plist-get (plist-get (etaf-gamekit-observation session) :pilot) :energy) 75))
            (etaf-dispatch-event runtime 'salvage-objectives-tab 'press)
            (should (string-match-p "Recover three power cores" (etaf-gamekit-test--text session)))
            (etaf-dispatch-event runtime 'salvage-help 'press)
            (should (string-match-p "FLIGHT MANUAL" (etaf-gamekit-test--text session)))))
      (etaf-gamekit-test--dispose session))))

(ert-deftest etaf-gamekit-salvage-native-keys-retain-rapid-input ()
  "Native directional keys reach the backend in order while paused."
  (let (session)
    (unwind-protect
        (save-window-excursion
          (setq session (etaf-gamekit-open-demo))
          (etaf-gamekit-test--wait session)
          (switch-to-buffer (etaf-gamekit-buffer session))
          (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
            (etaf-refit runtime (selected-window))
            (etaf-focus runtime 'salvage-tile-4-4)
            (execute-kbd-macro (kbd "d d d"))
            (etaf-gamekit-test--wait session)
            (should-not (etaf-gamekit-last-error session))
            (should (equal (car (last (plist-get (plist-get (etaf-gamekit-observation session) :world) :route)))
                           '(7 4)))))
      (etaf-gamekit-test--dispose session))))

(ert-deftest etaf-gamekit-salvage-resizes-with-a-readable-minimum ()
  "Reflow preserves map metrics and panel state; tiny viewports clip the canvas."
  (let (session)
    (unwind-protect
        (save-window-excursion
          (setq session (etaf-gamekit-open-demo))
          (etaf-gamekit-test--wait session)
          (let* ((runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session)))
                 (map-size (etaf-host-ref-size runtime 'salvage-map))
                 (cell-size (etaf-host-ref-size runtime 'salvage-tile-0-0))
                 (minimum (* 38 (car cell-size))))
            (dolist (size '((1428 . 50) (1000 . 42) (900 . 36) (780 . 32)
                            (700 . 50) (640 . 32) (1400 . 34)))
              (etaf-runtime-refit runtime (car size) (cdr size))
              (let ((root (etaf-host-ref-size runtime 'salvage-root)))
                (should (<= (car root) (max minimum (car size))))
                (should (<= (cdr root) (max 30 (cdr size)))))
              (should (equal (etaf-host-ref-size runtime 'salvage-map) map-size))
              (should (equal (etaf-host-ref-size runtime 'salvage-tile-0-0) cell-size))
              (should (etaf-host-ref-size runtime 'salvage-commands))
              (should (or (etaf-host-ref-size runtime 'salvage-cargo)
                          (etaf-host-ref-size runtime 'salvage-show-panels))))
            (etaf-runtime-refit runtime 640 32)
            (etaf-dispatch-event runtime 'salvage-show-panels 'press)
            (should (string-match-p "EXPEDITION CONSOLE" (etaf-gamekit-test--text session)))
            (etaf-dispatch-event runtime 'salvage-objectives-tab 'press)
            (execute-kbd-macro (kbd "<escape>"))
            (etaf-runtime-refit runtime 1200 46)
            (should (string-match-p "Recover three power cores" (etaf-gamekit-test--text session)))
            (etaf-runtime-refit runtime (- minimum 20) 20)
            (should (equal (etaf-host-ref-size runtime 'salvage-map) map-size))
            (should (equal (etaf-host-ref-size runtime 'salvage-root) (cons minimum 30)))))
      (etaf-gamekit-test--dispose session))))

(ert-deftest etaf-gamekit-salvage-snapshot-restores-through-the-session ()
  "A real saved expedition loads paused and remains valid for its frontend."
  (let ((file (make-temp-file "game-snapshot-")) session)
    (unwind-protect
        (save-window-excursion
          (setq session (etaf-gamekit-open-demo))
          (etaf-gamekit-test--wait session)
          (dolist (action `(("shield") ("save" :path ,file) ("restart") ("load" :path ,file)))
            (etaf-gamekit-action session (car action) (cdr action))
            (etaf-gamekit-test--wait session)
            (should (eq (etaf-gamekit-status session) 'ready))
            (should-not (etaf-gamekit-last-error session)))
          (should (= (plist-get (plist-get (etaf-gamekit-observation session) :pilot) :energy) 75))
          (should (string-match-p "Snapshot restored" (etaf-gamekit-test--text session))))
      (etaf-gamekit-test--dispose session)
      (delete-file file))))

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

(provide 'etaf-gamekit-tests)
;;; etaf-gamekit-tests.el ends here
