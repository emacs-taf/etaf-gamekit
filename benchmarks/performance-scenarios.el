;;; -*- lexical-binding: t; -*-
;;; performance-scenarios.el --- External engine and character surface workloads

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Workload adapters for the workspace performance driver. All session and
;; rendering access goes through supported package interfaces.

;;; Code:
(require 'etaf-gamekit)
(declare-function taf-benchmark-register "performance-driver" (id &rest properties))
(defconst etaf-gamekit-benchmark--directory
  (file-name-directory (or load-file-name buffer-file-name)))

(defun etaf-gamekit-benchmark--text (session)
  "Read SESSION's visible plain text."
  (with-current-buffer (etaf-gamekit-buffer session)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun etaf-gamekit-benchmark--grid (mode density &optional fps)
  "Create a DENSITY character fixture for MODE, optionally streaming at FPS."
  (let* ((session (etaf-gamekit-start
                   (list "python3" (expand-file-name "grid-source.py" etaf-gamekit-benchmark--directory)
                         "--density" (number-to-string density))))
         (runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session)))
         (expected 0) (seen nil) (accepted nil) (started nil) (before 0) snapshot)
    (cl-labels
        ((inspect ()
           (let ((text (etaf-gamekit-benchmark--text session))
                 (frame (plist-get (etaf-gamekit-observation session) :frame)))
             (when frame (cl-pushnew frame accepted))
             (when (string-match "Frame \\([0-9]+\\)" text)
               (cl-pushnew (string-to-number (match-string 1 text)) seen))
             (when (and (eq (etaf-gamekit-status session) 'ready)
                        (>= (or frame -1) expected)
                        (string-match-p (format "Frame %08d" frame) text))
               (setq snapshot (etaf-gamekit-observation session))
               t))))
      (list
       :buffer (etaf-gamekit-buffer session)
       :ready (lambda ()
                (if (eq mode 'batch) (etaf-runtime-refit runtime 1200 45)
                  (etaf-refit runtime (selected-window)))
                (when (inspect)
                  (if (and fps (not started))
                      (progn (setq started t) (etaf-gamekit-action session "play" (list :fps fps)) nil)
                    t)))
       :invoke (lambda (_index)
                 (setq seen nil accepted nil
                       before (plist-get (etaf-gamekit-observation session) :frame)
                       expected (1+ before))
                 (unless fps (etaf-gamekit-action session "step")))
       :settled #'inspect
       :outcome (lambda () (list :produced (- (plist-get snapshot :frame) before)
                                 :accepted_observed (length accepted)
                                 :displayed_observed (length (cl-remove-if
                                                             (lambda (n) (<= n before)) seen))
                                 :final_frame (plist-get snapshot :frame) :density_percent density))
       :verify (lambda ()
                 (let ((text (etaf-gamekit-benchmark--text session))
                       (rows (plist-get snapshot :rows)))
                   (cond ((etaf-gamekit-last-error session) (etaf-gamekit-last-error session))
                         ((not (cl-every (lambda (row) (string-match-p (regexp-quote row) text)) rows))
                          "Displayed grid differs from the backend's latest rows")
                         (t t))))
       :cleanup (lambda () (etaf-gamekit-close session)
                  (when (buffer-live-p (etaf-gamekit-buffer session))
                    (kill-buffer (etaf-gamekit-buffer session))))))))

(dolist (density '(1 20 100))
  (let ((amount density))
    (taf-benchmark-register
     (format "etaf-gamekit.grid.step.%d" amount)
     :version 1 :modes '(batch gui) :isolation 'series :impact 'subtree :budget-ms (/ 1000.0 30)
     :description (format "External 80x24 frame changing %d%% of cells" amount)
     :setup (lambda (mode) (etaf-gamekit-benchmark--grid mode amount)))
    (dolist (rate '(10 20 30))
      (let ((fps rate))
        (taf-benchmark-register
         (format "etaf-gamekit.grid.stream.%d.%d" amount fps)
         :version 1 :modes '(batch gui) :isolation 'series :impact 'subtree
         :budget-ms (+ (/ 1000.0 fps) 33.333)
         :description (format "Next displayed frame at %d Hz; 80x24; %d%% cells change" fps amount)
         :setup (lambda (mode) (etaf-gamekit-benchmark--grid mode amount fps)))))))

(defun etaf-gamekit-benchmark--chess (mode engine)
  "Create a real chess action fixture for MODE; ENGINE requests Stockfish."
  (let* ((session (etaf-gamekit-open-chess))
         (runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session)))
         expected)
    (cl-labels ((settled ()
                 (and (eq (etaf-gamekit-status session) 'ready)
                      (equal (length (plist-get (etaf-gamekit-observation session) :moves)) expected)
                      (string-match-p (format "%d plies played" expected)
                                      (etaf-gamekit-benchmark--text session)))))
      (setq expected 0)
      (list :buffer (etaf-gamekit-buffer session)
            :ready (lambda () (when (eq mode 'batch) (etaf-runtime-refit runtime 1200 45)) (settled))
            :invoke (lambda (index)
                      (setq expected (if engine (1+ index) (if (cl-evenp index) 1 0)))
                      (cond (engine (etaf-dispatch-event runtime 'game-engine 'press))
                            ((cl-evenp index) (etaf-gamekit-action session "move" '(:move "e2e4")))
                            (t (etaf-dispatch-event runtime 'game-undo 'press))))
            :settled #'settled
            :verify (lambda () (or (etaf-gamekit-last-error session) t))
            :outcome (lambda () (list :plies expected :last_move
                                      (plist-get (etaf-gamekit-observation session) :last_move)))
            :cleanup (lambda () (etaf-gamekit-close session)
                       (kill-buffer (etaf-gamekit-buffer session)))))))

(dolist (engine '(nil t))
  (let ((computer engine))
    (taf-benchmark-register
     (if computer "etaf-gamekit.chess.engine" "etaf-gamekit.chess.move")
     :version 1 :modes '(batch gui) :isolation 'series :impact 'subtree
     :budget-ms (if computer 250 100)
     :description (if computer "Stockfish reply and displayed board" "Legal move or undo and displayed board")
     :setup (lambda (mode) (etaf-gamekit-benchmark--chess mode computer)))))

(taf-benchmark-register
 "etaf-gamekit.story.command" :version 1 :modes '(batch gui) :isolation 'series
 :impact 'subtree :budget-ms 100 :description "Glulxe command to visible transcript and status"
 :setup
 (lambda (mode)
   (let* ((session (etaf-gamekit-open-story
                    (expand-file-name "last-beacon.ulx" etaf-gamekit-engine-directory)))
          (runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session)))
          (generation 0))
     (cl-labels ((settled ()
                   (let* ((view (etaf-gamekit-observation session))
                          (line (car (plist-get (car (plist-get view :windows)) :lines))))
                     (and (eq (etaf-gamekit-status session) 'ready)
                          (> (or (plist-get view :generation) 0) generation)
                          line (string-match-p (regexp-quote (string-trim line))
                                               (etaf-gamekit-benchmark--text session))))))
       (list :buffer (etaf-gamekit-buffer session)
             :ready (lambda ()
                      (if (eq mode 'batch) (etaf-runtime-refit runtime 1200 45)
                        (etaf-refit runtime (selected-window)))
                      (settled))
             :invoke (lambda (_index)
                       (setq generation (plist-get (etaf-gamekit-observation session) :generation))
                       (etaf-gamekit-action session "line" '(:value "look")))
             :settled #'settled
             :verify (lambda () (or (etaf-gamekit-last-error session) t))
             :outcome (lambda () (list :generation (plist-get (etaf-gamekit-observation session) :generation)))
             :cleanup (lambda () (etaf-gamekit-close session)
                        (kill-buffer (etaf-gamekit-buffer session))))))))

(provide 'etaf-gamekit-performance-scenarios)
;;; performance-scenarios.el ends here
