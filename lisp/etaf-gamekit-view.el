;;; -*- lexical-binding: t; -*-
;;; etaf-gamekit-view.el --- Catalog compositions for game observations

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:
(require 'etaf-ui)
(require 'etaf-gamekit-session)

(defun etaf-gamekit--square (row column)
  "Name a displayed chess square at ROW and COLUMN."
  (format "%c%d" (+ ?a column) (- 8 row)))

(defun etaf-gamekit--piece (state row column)
  "Read ROW and COLUMN from backend STATE's board projection."
  (aref (nth row (plist-get (etaf-value state) :board)) (* 2 column)))

(defun etaf-gamekit--square-label (state row column)
  "Name the observed square for help and keyboard discovery."
  (let* ((piece (etaf-gamekit--piece state row column))
         (name (cdr (assq (downcase piece)
                          '((?p . "pawn") (?n . "knight") (?b . "bishop")
                            (?r . "rook") (?q . "queen") (?k . "king"))))))
    (format "%s: %s" (etaf-gamekit--square row column)
            (if name (concat (if (< piece ?a) "White " "Black ") name) "empty"))))

(defun etaf-gamekit--board-color (key light dark)
  "Read a chess presentation token, defaulting to LIGHT or DARK for the frame."
  (etaf-theme-token key (if (eq (etaf-theme-current-mode) 'dark) dark light)))

(defun etaf-gamekit--file-action (session operation)
  "Prompt for a snapshot filename and send SESSION OPERATION."
  (let ((file (etaf-call-with-input
               (lambda () (read-file-name (concat (capitalize operation) " snapshot: ")
                                          nil nil (equal operation "load") "game.json")))))
    (when file (etaf-gamekit-action session operation (list :path (expand-file-name file))))))

(etaf-define-component etaf-gamekit--chess-view (&key session state)
  :bindings ((selected (etaf-ref nil)) (promotion (etaf-ref "q"))
             (draft (etaf-ref "")))
  :view
  (column :item-gap '(lh 1)
    (row :item-gap '(ch 3)
      (column
        (etaf-label :text "  a b c d e f g h" :variant 'muted)
        (row
          (column :width '(ch 2)
            (etaf-label :for (rank '(8 7 6 5 4 3 2 1)) :key rank :text rank))
          (etaf-tile-grid
           :rows 8 :columns 8 :cell-width 2
           :color (etaf-gamekit--board-color :game-board-fg "#172033" "#F8FAFC")
           :cell-ref (lambda (r c) (intern (concat "square-" (etaf-gamekit--square r c))))
           :cell-label (lambda (r c) (etaf-gamekit--square-label state r c))
           :cell-text (lambda (r c) (char-to-string (etaf-gamekit--piece state r c)))
           :cell-background
           (lambda (r c)
             (let ((square (etaf-gamekit--square r c)) (from (etaf-value selected)))
               (cond
                ((equal square from) (etaf-gamekit--board-color :game-selected-bg "#F3CC5C" "#805F16"))
                ((and from (cl-some (lambda (move)
                                     (and (string-prefix-p from move)
                                          (equal square (substring move 2 4))))
                                   (plist-get (etaf-value state) :legal)))
                 (etaf-gamekit--board-color :game-legal-bg "#9AD6B0" "#216343"))
                ((zerop (% (+ r c) 2)) (etaf-gamekit--board-color :game-square-light-bg "#E8EEF6" "#475569"))
                (t (etaf-gamekit--board-color :game-square-dark-bg "#8FA3BE" "#1E293B")))))
           :on-cell-press
           (lambda (r c)
             (when (eq (etaf-gamekit-status session) 'ready)
               (let* ((square (etaf-gamekit--square r c)) (from (etaf-value selected))
                      (move (and from (concat from square)))
                      (legal (plist-get (etaf-value state) :legal)))
                 (cond
                  ((and move (or (member move legal)
                                 (member (concat move (etaf-value promotion)) legal)))
                   (etaf-gamekit-action session "move"
                                     (list :move (if (member move legal) move
                                                   (concat move (etaf-value promotion)))))
                   (setf (etaf-value selected) nil))
                  ((equal from square) (setf (etaf-value selected) nil))
                  (t (setf (etaf-value selected) square)))))))))
      (column :width '(ch 34) :item-gap '(lh 1)
        (etaf-label :text "Select a piece, then a highlighted square." :wrap-mode 'word)
        (etaf-label :text "White: uppercase · Black: lowercase" :variant 'muted :wrap-mode 'word)
        (etaf-select :bind promotion :label "Promotion" :presentation 'dropdown :width '(ch 16)
                     :options '(("q" . "Queen") ("r" . "Rook")
                                ("b" . "Bishop") ("n" . "Knight")))
        (etaf-label :text (concat "Last move: " (or (plist-get (etaf-value state) :last_move) "—")))
        (etaf-label :text (format "%d plies played" (length (plist-get (etaf-value state) :moves))))))
    (etaf-text-input :bind draft :ref 'game-move :label "Move" :width '(ch 30)
                     :placeholder "e2e4 or e7e8q"
                     :on-submit (lambda (value)
                                  (etaf-gamekit-action session "move" (list :move (string-trim value)))
                                  (setf (etaf-value draft) "")))))

(etaf-define-component etaf-gamekit--glk-window (&key window)
  :view
  (column
    (etaf-text-grid :if (equal (plist-get window :type) "grid")
                    :rows (plist-get window :gridheight)
                    :columns (plist-get window :gridwidth) :label "Story status"
                    :row-text (lambda (row) (nth row (plist-get window :lines))))
    (box :if (equal (plist-get window :type) "buffer")
         :height '(lh 16) :overflow 'scroll :scroll-anchor 'end
         :ref (intern (format "story-output-%d" (plist-get window :id)))
         (etaf-label :text (plist-get window :text) :width 'stretch :wrap-mode 'word))))

(etaf-define-component etaf-gamekit--story-view (&key session state)
  :bindings ((draft (etaf-ref "")))
  :view
  (column :item-gap '(lh 1)
    (etaf-gamekit--glk-window :for (window (plist-get (etaf-value state) :windows))
                           :key (plist-get window :id) :window window)
    (etaf-text-input :bind draft :label "Command" :ref 'game-command :width '(ch 60)
                     :placeholder "look · inventory · north"
                     :on-submit
                     (lambda (value)
                       (let* ((input (car (plist-get (etaf-value state) :input)))
                              (kind (plist-get input :type)))
                         (etaf-gamekit-action session kind
                                           (list :window (plist-get input :id)
                                                 :value (if (and (equal kind "char")
                                                                 (string-empty-p value))
                                                            "return" value)))
                         (setf (etaf-value draft) ""))))))

(etaf-define-component etaf-gamekit--app (&key session)
  :bindings ((state (etaf-gamekit--session-view-ref session))
             (connection (etaf-gamekit--session-status-ref session))
             (failure (etaf-gamekit--session-error-ref session))
             (capabilities (etaf-gamekit--session-capabilities-ref session)))
  :setup (etaf-on-unmounted (lambda () (etaf-gamekit-close session)))
  :view
  (etaf-panel :title (or (plist-get (etaf-value state) :title) "ETAF GameKit")
    (slot :name 'header
      (etaf-label :text (etaf-value connection) :variant 'muted))
    (etaf-label :text (or (plist-get (etaf-value state) :status) "Connecting to the game engine…")
                :variant 'strong)
    (row :item-gap '(ch 1)
      (etaf-button :label "Engine move" :ref 'game-engine
                   :if (member "engine" (etaf-value capabilities))
                   :disabled (not (equal (etaf-value connection) "Ready"))
                   :on-press (lambda () (etaf-gamekit-action session "engine")))
      (etaf-button :label "Undo" :ref 'game-undo
                   :if (member "undo" (etaf-value capabilities))
                   :disabled (not (equal (etaf-value connection) "Ready"))
                   :on-press (lambda () (etaf-gamekit-action session "undo")))
      (etaf-button :label "Save" :ref 'game-save
                   :if (member "save" (etaf-value capabilities))
                   :disabled (not (equal (etaf-value connection) "Ready"))
                   :on-press (lambda () (etaf-gamekit--file-action session "save")))
      (etaf-button :label "Load" :ref 'game-load
                   :if (member "load" (etaf-value capabilities))
                   :disabled (not (equal (etaf-value connection) "Ready"))
                   :on-press (lambda () (etaf-gamekit--file-action session "load")))
      (etaf-button :label "Restart" :ref 'game-restart
                   :if (member "restart" (etaf-value capabilities))
                   :disabled (not (equal (etaf-value connection) "Ready"))
                   :on-press (lambda () (etaf-gamekit-action session "restart")))
      (etaf-button :label "Close" :ref 'game-close :variant 'ghost
                   :on-press (lambda () (etaf-gamekit-close session))))
    (etaf-label :if (not (string-empty-p (etaf-value failure)))
                :text (etaf-value failure) :variant 'danger :wrap-mode 'word)
    (etaf-gamekit--chess-view :if (equal (plist-get (etaf-value state) :kind) "chess")
                          :session session :state state)
    (etaf-gamekit--story-view :if (equal (plist-get (etaf-value state) :kind) "story")
                          :session session :state state)
    (etaf-text-grid :if (equal (plist-get (etaf-value state) :kind) "grid")
                    :rows (length (plist-get (etaf-value state) :rows))
                    :columns (plist-get (etaf-value state) :columns)
                    :row-text (lambda (row) (nth row (plist-get (etaf-value state) :rows)))
                    :label "Live character surface")))

(defun etaf-gamekit--mount (session)
  "Compose SESSION's application from the public catalog."
  (etaf-mount (etaf-gamekit-buffer session) (etaf-view (etaf-gamekit--app :session session))))

(provide 'etaf-gamekit-view)
;;; etaf-gamekit-view.el ends here
