;;; -*- lexical-binding: t; -*-
;;; salvage-tests.el --- Standalone game application acceptance

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'ert)
(require 'etaf-gamekit)
(defvar salvage-game)

(defconst salvage-test--directory
  (file-name-directory (or load-file-name buffer-file-name)))

(defun salvage-test--wait (session predicate)
  "Wait for SESSION's rendered observation to satisfy PREDICATE."
  (let ((deadline (+ (float-time) 10)))
    (while (and (< (float-time) deadline)
                (not (memq (etaf-gamekit-status session) '(failed closed)))
                (not (funcall predicate)))
      (accept-process-output nil 0.01)))
  (should-not (etaf-gamekit-last-error session))
  (should (funcall predicate)))

(ert-deftest salvage-standalone-project-routes-input-to-its-own-rules ()
  "A relocated game project renders and routes native input through GameKit."
  (let ((directory (make-temp-file "salvage-project-" t)) session)
    (unwind-protect
        (progn
          (dolist (name '("salvage.el" "project.godot" "game.gd"))
            (copy-file (expand-file-name (concat "../examples/salvage/" name)
                                         salvage-test--directory)
                       (expand-file-name name directory)))
          (let ((load-path (cons directory load-path)))
            (require 'salvage))
          (setq session (etaf-gamekit-start salvage-game))
          (let ((runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session))))
            (etaf-runtime-refit runtime 1200 46)
            (salvage-test--wait
             session (lambda () (and (eq (etaf-gamekit-status session) 'ready)
                                      (etaf-host-ref-size runtime 'salvage-map))))
            (should (equal (plist-get (etaf-gamekit-game-info session) :name) 'salvage-game))
            (should (eq (plist-get (etaf-gamekit-view session :mission) :paused) t))
            (etaf-dispatch-event runtime 'salvage-tile-4-6 'press)
            (salvage-test--wait
             session (lambda ()
                       (and (eq (etaf-gamekit-status session) 'ready)
                            (equal (car (last (plist-get (etaf-gamekit-view session :world) :route))) '(6 4))
                            (equal (plist-get (etaf-runtime-host-props-for runtime 'salvage-tile-4-6) :color)
                                   "#73BDEB"))))))
      (when session
        (etaf-gamekit-close session)
        (kill-buffer (etaf-gamekit-buffer session)))
      (when (featurep 'salvage) (unload-feature 'salvage t))
      (delete-directory directory t))))

(provide 'salvage-tests)
;;; salvage-tests.el ends here
