;;; -*- lexical-binding: t; -*-
;;; etaf-gamekit-tests.el --- Public game session acceptance

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:
(require 'ert)
(require 'etaf-gamekit)

(defconst etaf-gamekit-test--directory
  (file-name-directory (or load-file-name buffer-file-name)))

(defun etaf-gamekit-test--wait (session)
  "Wait for SESSION's public state and its displayed publication."
  (let ((deadline (+ (float-time) 10)))
    (while (and (memq (etaf-gamekit-status session) '(starting busy))
                (< (float-time) deadline))
      (accept-process-output nil 0.01))
    (sleep-for 0.06)
    (should-not (memq (etaf-gamekit-status session) '(starting busy)))))

(defun etaf-gamekit-test--dispose (session)
  "Release SESSION and the buffer owned by this scenario."
  (when session
    (etaf-gamekit-close session)
    (when (buffer-live-p (etaf-gamekit-buffer session)) (kill-buffer (etaf-gamekit-buffer session)))))

(defun etaf-gamekit-test--peer (mode)
  "Connect a public session to the protocol fixture in MODE."
  (etaf-gamekit-start
   (list "python3" (expand-file-name "fixtures/adapter.py" etaf-gamekit-test--directory) mode)))

(ert-deftest etaf-gamekit-chess-displays-moves-rejections-and-engine-replies ()
  "Catalog interactions change a real engine position and display rejection."
  (let (session)
    (unwind-protect
        (progn
          (setq session (etaf-gamekit-open-chess))
          (etaf-gamekit-test--wait session)
          (should (eq (etaf-gamekit-status session) 'ready))
          (let ((runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session))))
            (should runtime)
            (etaf-dispatch-event runtime 'square-e2 'press)
            (etaf-dispatch-event runtime 'square-e4 'press)
            (etaf-gamekit-test--wait session)
            (should (equal (plist-get (etaf-gamekit-observation session) :last_move) "e2e4"))
            (let ((accepted (etaf-gamekit-observation session)))
              (etaf-gamekit-action session "move" '(:move "e2e5"))
              (etaf-gamekit-test--wait session)
              (should (equal (plist-get accepted :fen)
                             (plist-get (etaf-gamekit-observation session) :fen)))
              (should (string-match-p "Illegal move" (etaf-gamekit-last-error session))))
            (etaf-dispatch-event runtime 'game-engine 'press)
            (etaf-gamekit-test--wait session)
            (should-not (etaf-gamekit-last-error session))
            (should (= (length (plist-get (etaf-gamekit-observation session) :moves)) 2))
            (should (with-current-buffer (etaf-gamekit-buffer session)
                      (string-match-p "White to move"
                                      (buffer-substring-no-properties (point-min) (point-max)))))))
      (etaf-gamekit-test--dispose session))))

(ert-deftest etaf-gamekit-story-input-save-and-restore-use-native-state ()
  "A story snapshot restores its room and held object through the public API."
  (let ((file (make-temp-file "game-snapshot-")) session)
    (unwind-protect
        (progn
          (setq session (etaf-gamekit-open-story
                         (expand-file-name "last-beacon.ulx" etaf-gamekit-engine-directory)))
          (etaf-gamekit-test--wait session)
          (dolist (action `(("line" :value "take lantern") ("save" :path ,file)
                            ("line" :value "north") ("load" :path ,file)
                            ("line" :value "inventory")))
            (etaf-gamekit-action session (car action) (cdr action))
            (etaf-gamekit-test--wait session)
            (should-not (etaf-gamekit-last-error session)))
          (let* ((view (etaf-gamekit-observation session))
                 (windows (plist-get view :windows))
                 (grid (cl-find-if (lambda (window) (equal (plist-get window :type) "grid")) windows)))
            (should (string-match-p "Workshop" (car (plist-get grid :lines))))
            (should (with-current-buffer (etaf-gamekit-buffer session)
                      (string-match-p "a brass lantern"
                                      (buffer-substring-no-properties (point-min) (point-max)))))))
      (etaf-gamekit-test--dispose session)
      (delete-file file))))

(ert-deftest etaf-gamekit-story-native-input-submits-a-command ()
  "Native field typing and Return reach the engine and update the transcript."
  (let (session)
    (unwind-protect
        (save-window-excursion
          (setq session (etaf-gamekit-open-story
                         (expand-file-name "last-beacon.ulx" etaf-gamekit-engine-directory)))
          (etaf-gamekit-test--wait session)
          (switch-to-buffer (etaf-gamekit-buffer session))
          (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
            (etaf-refit runtime (selected-window))
            (etaf-dispatch-event runtime 'game-command 'press)
            (should (etaf-text-input-active-p runtime))
            (execute-kbd-macro (vconcat "take lantern" (kbd "RET")))
            (should-not (etaf-text-input-active-p runtime))
            (etaf-gamekit-test--wait session)
            (should-not (etaf-gamekit-last-error session))
            (should (string-match-p "Taken"
                                    (etaf-gamekit-test--text session)))))
      (etaf-gamekit-test--dispose session))))

(defun etaf-gamekit-test--text (session)
  "Read SESSION's rendered text without properties."
  (with-current-buffer (etaf-gamekit-buffer session)
    (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest etaf-gamekit-transport-handles-fragments-and-detaches-observations ()
  "Partial JSON waits for completion; callers cannot mutate accepted views."
  (let ((session (etaf-gamekit-test--peer "split")))
    (unwind-protect
        (progn
          (etaf-gamekit-test--wait session)
          (let ((view (etaf-gamekit-observation session)))
            (aset (car (plist-get view :rows)) 0 ?X)
            (should (equal (car (plist-get (etaf-gamekit-observation session) :rows)) "frame-0")))
          (should-error (etaf-gamekit-action session "absent") :type 'etaf-gamekit-error)
          (should-error (etaf-gamekit-action session "step" (list :bad (current-buffer)))
                        :type 'etaf-gamekit-error)
          (should (eq (etaf-gamekit-status session) 'ready))
          (etaf-gamekit-action session "step")
          (should-error (etaf-gamekit-action session "step") :type 'etaf-gamekit-error)
          (etaf-gamekit-test--wait session)
          (should (eq (etaf-gamekit-status session) 'ready)))
      (etaf-gamekit-test--dispose session))))

(ert-deftest etaf-gamekit-transport-coalesces-to-the-newest-visible-frame ()
  "A burst preserves the final backend observation and displayed characters."
  (let ((session (etaf-gamekit-test--peer "burst")))
    (unwind-protect
        (progn
          (etaf-gamekit-test--wait session)
          (etaf-gamekit-action session "step")
          (etaf-gamekit-test--wait session)
          (let ((deadline (+ (float-time) 5)))
            (while (and (< (float-time) deadline)
                        (not (equal (car (plist-get (etaf-gamekit-observation session) :rows)) "00000100")))
              (accept-process-output nil 0.01)))
          (sleep-for 0.06)
          (should (equal (car (plist-get (etaf-gamekit-observation session) :rows)) "00000100"))
          (should (with-current-buffer (etaf-gamekit-buffer session)
                    (string-match-p "00000100" (buffer-substring-no-properties (point-min) (point-max))))))
      (etaf-gamekit-test--dispose session))))

(ert-deftest etaf-gamekit-transport-rejects-stale-invalid-and-dead-peers ()
  "Bad protocol, a timeout and process death become inspectable failures."
  (dolist (mode '("stale" "malformed" "bad-object" "bad-window" "crash" "hang"))
    (let* ((etaf-gamekit-request-timeout 0.15)
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

(ert-deftest etaf-gamekit-close-and-buffer-death-release-the-child ()
  "Closing and killing a buffer stop its owned child, idempotently."
  (dolist (kill '(nil t))
    (let ((session (etaf-gamekit-test--peer "split")))
      (unwind-protect
          (progn
            (etaf-gamekit-test--wait session)
            (let ((pid (plist-get (etaf-gamekit-observation session) :pid)))
              (if kill (kill-buffer (etaf-gamekit-buffer session)) (etaf-gamekit-close session))
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
          (should (with-current-buffer (etaf-gamekit-buffer session)
                    (string-match-p "Action rejected"
                                    (buffer-substring-no-properties (point-min) (point-max))))))
      (etaf-gamekit-test--dispose session))))

(provide 'etaf-gamekit-tests)
;;; etaf-gamekit-tests.el ends here
