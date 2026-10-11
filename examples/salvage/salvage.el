;;; -*- lexical-binding: t; -*-
;;; salvage.el --- Salvage Station's native application

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (etaf-gamekit "0.1.0") (etaf-ui "0.1.0"))
;;; Commentary:
;; A standalone example application built with the GameKit public API.
;; Add this directory to load-path, require salvage, and call salvage-open.
;;
;; Variable: salvage-game
;; The Salvage Station game definition, usable with etaf-gamekit-start.
;; Each start owns a separate Godot world and native ETAF presentation.
;;
;; Function: salvage-open ()
;;;###autoload (autoload 'salvage-open "salvage" nil t)
;; Start and display an independent Salvage Station expedition; return its
;; GameKit instance. The game starts paused; no snapshot is restored implicitly.
;;
;;; Code:
(require 'etaf-gamekit)
(require 'etaf-ui)
(declare-function etaf-gamekit-view "etaf-gamekit" (session &optional field))
(declare-function etaf-gamekit-status "etaf-gamekit" (session))
(declare-function etaf-gamekit-last-error "etaf-gamekit" (session))
(declare-function etaf-gamekit-action "etaf-gamekit" (session operation &optional arguments))

(defconst salvage--directory
  (file-name-directory (or load-file-name buffer-file-name)))

(defconst salvage--theme
  '(:ui-fg "#DBE8F5" :ui-bg "#091522" :ui-muted-fg "#8196AD"
    :ui-border "#2A4258" :ui-panel-fg "#DBE8F5" :ui-panel-bg "#0F2032"
    :ui-panel-border "#2A4258" :ui-accent "#66E0D3" :ui-accent-fg "#08242B"
    :ui-button-primary-bg "#66E0D3" :ui-button-primary-fg "#08242B"
    :ui-button-secondary-bg "#1A3A50" :ui-button-secondary-fg "#9DDCEF"
    :ui-button-ghost-fg "#A7BED1" :ui-disabled-bg "#15283A"
    :ui-disabled-fg "#596F87" :ui-disabled-border "#22394D"
    :ui-success-fg "#70DEC0" :ui-success-bg "#123D3C" :ui-success-border "#245D58"
    :ui-info-fg "#82CDFA" :ui-info-bg "#143247" :ui-info-border "#285574"
    :ui-warning-fg "#F4CB7B" :ui-warning-bg "#413725" :ui-warning-border "#665234"
    :ui-danger-fg "#FF929B" :ui-danger-bg "#462630" :ui-danger-border "#6A3744"
    :ui-progress-track "#21354A" :ui-divider-bg "#2A4258"
    :salvage-wall-bg "#304B62" :salvage-wall-fg "#4D718A"
    :salvage-deck-bg "#102538" :salvage-deck-alt-bg "#142C40"
    :salvage-deck-fg "#34546D" :salvage-route-fg "#73BDEB"
    :salvage-pilot-bg "#6CE4D4" :salvage-pilot-fg "#07343D"
    :salvage-drone-bg "#472B3A" :salvage-drone-fg "#FF8C9D"
    :salvage-core-bg "#3D3929" :salvage-core-fg "#F4CE7C"
    :salvage-dock-bg "#173E3C" :salvage-dock-fg "#83E5C5"
    :salvage-selected-bg "#375C73")
  "Scoped semantic palette for the game; it does not alter the Emacs theme.")

(defun salvage--object-p (value)
  "Whether VALUE is a decoded JSON object."
  (and (proper-list-p value) (zerop (% (length value) 2))
       (cl-loop for (key _value) on value by #'cddr always (keywordp key))))

(defun salvage--integer-p (value minimum maximum)
  "Whether VALUE is an integer in the inclusive bounds."
  (and (integerp value) (<= minimum value maximum)))

(defun salvage--valid-p (view)
  "Validate the game's observation before publishing it."
  (and (salvage--object-p view)
       (equal (plist-get view :schema) "salvage/1")
       (let ((world (plist-get view :world)) (pilot (plist-get view :pilot))
             (mission (plist-get view :mission)) (events (plist-get view :events)))
         (and (salvage--object-p world)
              (salvage--object-p pilot)
              (salvage--object-p mission)
              (equal (plist-get world :width) 32) (equal (plist-get world :height) 18)
              (proper-list-p (plist-get world :terrain))
              (= (length (plist-get world :terrain)) 18)
              (cl-every (lambda (row) (and (stringp row) (= (length row) 32)
                                          (not (string-match-p "[^.#]" row))))
                        (plist-get world :terrain))
              (consp (plist-get world :entities))
              (proper-list-p (plist-get world :entities))
              (cl-every (lambda (entity)
                          (and (salvage--object-p entity)
                               (stringp (plist-get entity :id)) (stringp (plist-get entity :name))
                               (member (plist-get entity :kind) '("pilot" "drone" "core" "dock"))
                               (salvage--integer-p (plist-get entity :x) 0 31)
                               (salvage--integer-p (plist-get entity :y) 0 17)))
                        (plist-get world :entities))
              (proper-list-p (plist-get world :route))
              (cl-every (lambda (cell)
                          (and (proper-list-p cell) (= (length cell) 2)
                               (salvage--integer-p (car cell) 0 31)
                               (salvage--integer-p (cadr cell) 0 17)))
                        (plist-get world :route))
              (cl-every (lambda (key) (memq (plist-get world key) '(t :false))) '(:pulse :shield))
              (cl-every (lambda (pair)
                          (salvage--integer-p (plist-get pilot (car pair)) 0 (cdr pair)))
                        '((:health . 100) (:energy . 100) (:repairs . 2) (:cores . 3)
                          (:score . 975) (:pulse_cooldown . 4) (:shield_remaining . 5)))
              (cl-every (lambda (key) (memq (plist-get mission key) '(t :false))) '(:paused :won :lost))
              (salvage--integer-p (plist-get mission :seconds) 0 most-positive-fixnum)
              (salvage--integer-p (plist-get mission :drones) 0 3)
              (proper-list-p events) (<= (length events) 12)
              (cl-every (lambda (event)
                          (and (salvage--object-p event)
                               (salvage--integer-p (plist-get event :id) 1 most-positive-fixnum)
                               (salvage--integer-p (plist-get event :time) 0 most-positive-fixnum)
                               (stringp (plist-get event :title)) (stringp (plist-get event :detail))
                               (member (plist-get event :kind) '("info" "success" "danger")))) events)
              t))))

(defun salvage--act (session operation &optional args)
  "Send one game OPERATION through the bounded session queue."
  (when (memq (etaf-gamekit-status session) '(ready busy))
    (etaf-gamekit-action session operation args)))

(defun salvage--file (session operation)
  "Choose a local expedition snapshot for OPERATION."
  (when-let* ((path (etaf-call-with-input
                    (lambda () (read-file-name (concat (capitalize operation) " expedition: ")
                                               nil nil (equal operation "load") "salvage.json")))))
    (salvage--act session operation (list :path (expand-file-name path)))))

(defun salvage--entity (world row column)
  "Find the visible object at ROW/COLUMN in WORLD."
  (cl-find-if (lambda (entity) (and (= column (plist-get entity :x))
                                   (= row (plist-get entity :y))))
              (plist-get world :entities)))

(defun salvage--index (items entity-p)
  "Index display ITEMS by coordinate; ENTITY-P selects entity records."
  (let ((cells (make-vector (* 32 18) nil)))
    (dolist (item items)
      (let ((index (if entity-p (+ (* 32 (plist-get item :y)) (plist-get item :x))
                     (+ (* 32 (cadr item)) (car item)))))
        (unless (aref cells index) (aset cells index (if entity-p item t)))))
    cells))

(defun salvage--tile (terrain entities route selected row column part)
  "Resolve PART from indexed display facts at ROW/COLUMN."
  (let* ((index (+ (* row 32) column))
         (entity (aref (etaf-value entities) index))
         (kind (plist-get entity :kind))
         (wall (= (aref (nth row (etaf-value terrain)) column) ?#)))
    (pcase part
      ('text (cond ((equal kind "pilot") "◉") ((equal kind "drone") "▲")
                   ((equal kind "core") "◆") ((equal kind "dock") "▣")
                   (wall "▪") (t "·")))
      ('label (or (plist-get entity :name)
                  (format "%s %d,%d" (if wall "Bulkhead" "Deck") column row)))
      (_ (etaf-theme-token
          (cond
           ((eq part 'background)
            (cond ((and entity (not (equal kind "pilot"))
                        (equal (etaf-value selected) (plist-get entity :id))) :salvage-selected-bg)
                  (kind (intern (concat ":salvage-" kind "-bg")))
                  (wall :salvage-wall-bg)
                  ((cl-evenp (+ (/ row 9) (/ column 10))) :salvage-deck-bg)
                  (t :salvage-deck-alt-bg)))
           (kind (intern (concat ":salvage-" kind "-fg")))
           (wall :salvage-wall-fg)
           ((aref (etaf-value route) index) :salvage-route-fg)
           (t :salvage-deck-fg)))))))

(etaf-define-component salvage--deck (&key session selected)
  :bindings ((world (etaf-computed (lambda () (etaf-gamekit-view session :world)) :test #'equal))
             (terrain (etaf-computed (lambda () (plist-get (etaf-value world) :terrain)) :test #'equal))
             (entities (etaf-computed
                        (lambda () (salvage--index (plist-get (etaf-value world) :entities) t)) :test #'equal))
             (route (etaf-computed
                     (lambda () (salvage--index (plist-get (etaf-value world) :route) nil)) :test #'equal)))
  :view
  (etaf-tile-grid :rows 18 :columns 32 :cell-width 2 :ref 'salvage-map
    :cell-ref (lambda (r c) (intern (format "salvage-tile-%d-%d" r c)))
    :cell-text (lambda (r c) (salvage--tile terrain entities route selected r c 'text))
    :cell-color (lambda (r c) (salvage--tile terrain entities route selected r c 'color))
    :cell-background (lambda (r c) (salvage--tile terrain entities route selected r c 'background))
    :cell-label (lambda (r c) (salvage--tile terrain entities route selected r c 'label))
    :on-cell-press
    (lambda (r c)
      (let* ((data (etaf-value world)) (entity (salvage--entity data r c)))
        (if entity (setf (etaf-value selected) (plist-get entity :id))
          (unless (= (aref (nth r (plist-get data :terrain)) c) ?#)
            (salvage--act session "navigate" (list :x c :y r))))))))

(etaf-define-component salvage--map (&key session selected compact narrow)
  :view
  (etaf-panel :title "01 / STATION DECK" :ref 'salvage-map-panel :width '(ch 70) :padding '((lh 1) (ch 2))
              :item-gap (if compact '(lh 0) '(lh 1))
    (flex :if (not compact) :justify-content 'space-between :width 'stretch
      (etaf-label :text "SECTOR 07     Derelict research station" :variant 'muted)
      (etaf-tag :text "32 × 18" :variant 'info))
    (flex :width 'stretch :justify-content 'center
      (salvage--deck :session session :selected selected))
    (row :item-gap (if narrow '(ch 1) '(ch 3))
      (etaf-label :text (if narrow "◉ YOU" "◉ SURVEYOR") :color "#6CE4D4")
      (etaf-label :text "▲ DRONE" :color "#FF8C9D")
      (etaf-label :text (if narrow "◆ CORE" "◆ POWER CORE") :color "#F4CE7C")
      (etaf-label :text (if narrow "▣ DOCK" "▣ EXTRACTION") :color "#83E5C5"))
    (etaf-label :if (and (not compact) (not narrow)) :text "Click deck to plot a route · Select an object to inspect it" :variant 'muted)))

(etaf-define-component salvage--metrics (&key session compact narrow)
  :bindings ((pilot (etaf-computed (lambda () (etaf-gamekit-view session :pilot)) :test #'equal))
             (mission (etaf-computed (lambda () (etaf-gamekit-view session :mission)) :test #'equal)))
  :view
  (grid :ref 'salvage-metrics :width 'stretch
        :grid-template-columns (if narrow '((fr 1) (fr 1)) '((ch 70) (fr 1)))
        :gap '((lh 0) (ch 2))
    (grid :width 'stretch :grid-template-columns '((fr 1) (fr 1)) :gap '((lh 0) (ch 1))
      (etaf-card :padding '((lh 0) (ch 2))
        (etaf-progress :label "HULL" :value (plist-get (etaf-value pilot) :health) :variant 'success))
      (etaf-card :padding '((lh 0) (ch 2))
        (etaf-progress :label "ENERGY" :value (plist-get (etaf-value pilot) :energy) :variant 'info)))
    (grid :width 'stretch :grid-template-columns '((fr 1) (fr 1)) :gap '((lh 0) (ch 1))
      (etaf-card :padding '((lh 0) (ch 2)) :item-gap (if compact '(lh 0) '(lh 1))
        (etaf-label :text "SALVAGE" :variant 'muted)
        (etaf-label :text (format "%d / 3 CORES" (plist-get (etaf-value pilot) :cores)) :variant 'strong))
      (etaf-card :padding '((lh 0) (ch 2)) :item-gap (if compact '(lh 0) '(lh 1))
        (etaf-label :text "TIME" :variant 'muted)
        (etaf-label :text (format "%02d:%02d" (/ (plist-get (etaf-value mission) :seconds) 60)
                                 (% (plist-get (etaf-value mission) :seconds) 60)) :variant 'strong)))))

(etaf-define-component salvage--inspector (&key session selected compact)
  :bindings ((mission (etaf-computed (lambda () (etaf-gamekit-view session :mission)) :test #'equal))
             (world (etaf-computed (lambda () (etaf-gamekit-view session :world)) :test #'equal))
             (entity (etaf-computed
                      (lambda ()
                        (let ((entities (plist-get (etaf-value world) :entities)))
                          (or (cl-find (etaf-value selected) entities
                                       :key (lambda (item) (plist-get item :id)) :test #'equal)
                              (car entities)))) :test #'equal))
             (kind (etaf-computed (lambda () (plist-get (etaf-value entity) :kind)))))
  :view
  (etaf-panel :ref 'salvage-inspector :title (if compact "02 / TARGET" "02 / TARGET INTELLIGENCE")
              :padding '((lh 1) (ch 2)) :item-gap (if compact '(lh 0) '(lh 1))
    (etaf-label :text (plist-get (etaf-value entity) :name) :variant 'strong)
    (row :item-gap '(ch 1)
      (etaf-tag :text (upcase (etaf-value kind)) :variant (if (equal (etaf-value kind) "drone") 'danger 'info))
      (etaf-label :text (format "DECK %02d · %02d" (plist-get (etaf-value entity) :x)
                               (plist-get (etaf-value entity) :y)) :variant 'muted))
    (etaf-label :wrap-mode 'word :width 'stretch
      :text (pcase (etaf-value kind)
              ("drone" "Hostile security unit. EMP pulse disables drones within 5 tiles.")
              ("core" "Recover this power core by reaching its deck tile.")
              ("dock" "Return here with all three power cores to complete extraction.")
              (_ "Your surveyor. Plot a route on the map or steer with W A S D.")))
    (etaf-button :if (member (etaf-value kind) '("core" "dock")) :label "Plot route to target"
                 :ref 'salvage-route-target :variant 'secondary
                 :disabled (or (eq t (plist-get (etaf-value mission) :won))
                               (eq t (plist-get (etaf-value mission) :lost)))
                 :on-press (lambda ()
                             (let ((target (etaf-value entity)))
                               (salvage--act session "navigate"
                                 (list :x (plist-get target :x) :y (plist-get target :y))))))))

(etaf-define-component salvage--cargo (&key session compact active)
  :bindings ((mission (etaf-computed (lambda () (etaf-gamekit-view session :mission)) :test #'equal))
             (pilot (etaf-computed (lambda () (etaf-gamekit-view session :pilot)) :test #'equal))
             (tab (or active (etaf-ref "cargo"))))
  :view
  (etaf-panel :ref 'salvage-cargo :title "03 / EXPEDITION" :padding '((lh 1) (ch 2))
              :item-gap (if compact '(lh 0) '(lh 1))
    (etaf-tabs :active tab :items '((:key "cargo" :label "Cargo" :ref salvage-cargo-tab)
                                   (:key "mission" :label "Objectives" :ref salvage-objectives-tab))
               :on-change (lambda (value) (setf (etaf-value tab) value)))
    (column :if (equal (etaf-value tab) "cargo") :item-gap (if compact '(lh 0) '(lh 1))
      (flex :justify-content 'space-between :width 'stretch
        (etaf-label :text "◆ Power cores" :color "#F4CE7C")
        (etaf-badge :text (format "%d / 3" (plist-get (etaf-value pilot) :cores)) :variant 'warning))
      (flex :justify-content 'space-between :width 'stretch
        (etaf-label :text "+ Repair kits")
        (etaf-badge :text (plist-get (etaf-value pilot) :repairs) :variant 'success))
      (etaf-button :label (if compact "Repair · +40 hull" "Use repair kit · +40 hull")
                   :help-echo "Use one repair kit to restore up to 40 hull"
                   :ref 'salvage-repair :variant 'secondary
                   :disabled (or (eq t (plist-get (etaf-value mission) :won))
                                 (<= (plist-get (etaf-value pilot) :repairs) 0)
                                 (<= (plist-get (etaf-value pilot) :health) 0)
                                 (>= (plist-get (etaf-value pilot) :health) 100))
                   :on-press (lambda () (salvage--act session "repair"))))
    (column :if (equal (etaf-value tab) "mission") :item-gap '(lh 1)
      (etaf-label :text (format "%s Recover three power cores"
                                (if (= (plist-get (etaf-value pilot) :cores) 3) "✓" "○")))
      (etaf-label :text (format "%s Return to the extraction dock"
                                (if (eq t (plist-get (etaf-value mission) :won)) "✓" "○")) :wrap-mode 'word)
      (etaf-label :text "Optional: disable security drones for +75 salvage each." :variant 'muted :wrap-mode 'word))
    (etaf-divider)
    (flex :justify-content 'space-between :width 'stretch
      (etaf-label :text "SALVAGE SCORE" :variant 'muted)
      (etaf-label :text (format "%04d" (plist-get (etaf-value pilot) :score)) :variant 'strong))))

(etaf-define-component salvage--commands (&key session narrow)
  :bindings ((pilot (etaf-computed (lambda () (etaf-gamekit-view session :pilot)) :test #'equal))
             (mission (etaf-computed (lambda () (etaf-gamekit-view session :mission)) :test #'equal))
             (ended (etaf-computed (lambda () (or (eq t (plist-get (etaf-value mission) :won))
                                                   (eq t (plist-get (etaf-value mission) :lost)))))))
  :view
  (etaf-panel :ref 'salvage-commands :padding '((lh 0) (ch 2)) :width 'stretch
    (flex :if (etaf-value ended) :width 'stretch :justify-content 'space-between
      (etaf-label :ref 'salvage-result :variant 'strong
        :text (if (eq t (plist-get (etaf-value mission) :won))
                  "EXTRACTION COMPLETE · All cores secured" "EXPEDITION LOST · Surveyor signal lost"))
      (etaf-button :label "Start a new expedition" :ref 'salvage-new-expedition
        :on-press (lambda () (salvage--act session "restart"))))
    (flex :if (not (etaf-value ended)) :justify-content 'space-between :width 'stretch :gap '((lh 0) (ch 2))
      (row :item-gap '(ch 2)
        (etaf-button :label (if (eq t (plist-get (etaf-value mission) :paused)) "P  LAUNCH" "P  PAUSE")
                     :ref 'salvage-pause :width '(ch 19)
                     :on-press (lambda () (salvage--act session "pause")))
        (etaf-button :label (if (> (plist-get (etaf-value pilot) :pulse_cooldown) 0)
                                (format "1  EMP · %ds" (plist-get (etaf-value pilot) :pulse_cooldown)) "1  EMP PULSE")
                     :help-echo "20 energy · Disables drones within five tiles"
                     :ref 'salvage-pulse :width '(ch 19) :variant 'secondary
                     :disabled (or (eq t (plist-get (etaf-value mission) :paused))
                                   (> (plist-get (etaf-value pilot) :pulse_cooldown) 0)
                                   (< (plist-get (etaf-value pilot) :energy) 20))
                     :on-press (lambda () (salvage--act session "pulse")))
        (etaf-button :label "2  SHIELD" :ref 'salvage-shield :variant 'secondary
                     :help-echo "25 energy · Protects the hull for five seconds"
                     :width '(ch 19) :disabled (< (plist-get (etaf-value pilot) :energy) 25)
                     :on-press (lambda () (salvage--act session "shield"))))
      (etaf-label :if (not narrow) :text "W A S D · MOVE" :variant 'muted))))

(etaf-define-component salvage--log (&key session compact)
  :bindings ((events (etaf-computed (lambda () (etaf-gamekit-view session :events)) :test #'equal)))
  :view
  (column :ref 'salvage-log :width 'stretch
    (row :for (event (cl-subseq (etaf-value events) 0 (min (if compact 1 3) (length (etaf-value events)))))
         :key (plist-get event :id) :item-gap '(ch 2)
      (etaf-label :text (format "%02d:%02d" (/ (plist-get event :time) 60) (% (plist-get event :time) 60)) :variant 'muted)
      (etaf-tag :text (plist-get event :title) :variant (intern (plist-get event :kind)))
      (etaf-label :text (plist-get event :detail) :variant 'muted :wrap-mode 'word))))

(etaf-define-component salvage--sidebar (&key session selected compact horizontal active)
  :view
  (grid :ref 'salvage-sidebar :width 'stretch
        :grid-template-columns (if horizontal '((fr 1) (fr 1)) '((fr 1)))
        :gap '((lh 1) (ch 2))
    (salvage--inspector :key 'inspection :session session :selected selected :compact compact)
    (salvage--cargo :key 'cargo :session session :compact compact :active active)))

(etaf-define-component salvage--app (&key session)
  :bindings ((ready (etaf-computed (lambda () (equal (etaf-gamekit-view session :schema) "salvage/1"))))
             (selected (etaf-ref "pilot")) (help (etaf-ref nil)) (tools (etaf-ref nil))
             (cargo-tab (etaf-ref "cargo"))
             (viewport (etaf-computed
                        (lambda () (let ((size (etaf-viewport)))
                                     (cons (or (car size) 1024) (or (cdr size) 50)))) :test #'equal))
             (compact (etaf-computed (lambda () (< (cdr (etaf-value viewport)) 44))))
             (dense (etaf-computed (lambda () (< (cdr (etaf-value viewport)) 35))))
             (narrow (etaf-computed (lambda () (< (car (etaf-value viewport)) 760))))
             (stacked (etaf-computed (lambda () (and (etaf-value narrow)
                                                     (>= (cdr (etaf-value viewport)) 48)))))
             (drawer (etaf-computed (lambda () (and (etaf-value narrow) (not (etaf-value stacked)))))))
  :setup (etaf-theme-provide salvage--theme)
  :view
  (flex :width 'stretch :height 'stretch :min-width '(ch 76) :min-height '(lh 30)
        :flex-direction 'column :align-items 'center :background-color "#091522"
    (column :ref 'salvage-root :width 'stretch :max-width '(ch 120)
            :min-width '(ch 76) :min-height '(lh 30) :flex-shrink 0
            :padding (if (or (etaf-value dense) (etaf-value stacked)) '((lh 0) (ch 2)) '((lh 1) (ch 2)))
            :item-gap (if (etaf-value dense) '(lh 0) '(lh 1))
            :background-color "#091522" :color "#DBE8F5"
            :keys (list
                   (list "w" (lambda () (salvage--act session "move" '(:x 0 :y -1))) "Move north")
                   (list "a" (lambda () (salvage--act session "move" '(:x -1 :y 0))) "Move west")
                   (list "s" (lambda () (salvage--act session "move" '(:x 0 :y 1))) "Move south")
                   (list "d" (lambda () (salvage--act session "move" '(:x 1 :y 0))) "Move east")
                   (list "p" (lambda () (salvage--act session "pause")) "Pause or resume")
                   (list "1" (lambda () (salvage--act session "pulse")) "EMP pulse")
                   (list "2" (lambda () (salvage--act session "shield")) "Shield")
                   (list "<f1>" (lambda () (setf (etaf-value help) t)) "Flight manual"))
      (flex :width 'stretch :justify-content 'space-between
        (column
          (etaf-label :text "NEXUS / SALVAGE STATION" :color "#6CE4D4" :variant 'strong)
          (etaf-label :if (not (etaf-value compact)) :text "EXPEDITION 07 · Recover the cores. Make it home." :variant 'muted))
        (row :item-gap '(ch 1)
          (etaf-button :label "Save" :variant 'ghost :ref 'salvage-save
                       :on-press (lambda () (salvage--file session "save")))
          (etaf-button :label "Load" :variant 'ghost :ref 'salvage-load
                       :on-press (lambda () (salvage--file session "load")))
          (etaf-button :label (if (etaf-value narrow) "New" "New run") :variant 'ghost :ref 'salvage-restart
                       :on-press (lambda () (salvage--act session "restart")))
          (etaf-button :if (etaf-value drawer) :label "Panels" :ref 'salvage-show-panels :variant 'secondary
                       :on-press (lambda () (setf (etaf-value tools) t)))
          (etaf-button :label (if (etaf-value narrow) "Help" "Help · F1") :variant 'ghost :ref 'salvage-help
                       :on-press (lambda () (setf (etaf-value help) t)))))
      (etaf-label :if (not (etaf-value ready)) :text "Preparing expedition…" :variant 'muted)
      (salvage--metrics :if (etaf-value ready) :session session :compact (etaf-value dense) :narrow (etaf-value narrow))
      (grid :if (etaf-value ready) :ref 'salvage-body :width 'stretch
            :grid-template-columns (if (etaf-value narrow) '((fr 1)) '((ch 70) (fr 1)))
            :gap '((lh 1) (ch 2))
        (flex :key 'map-pane :width 'stretch :justify-content 'center
          (salvage--map :session session :selected selected
                                    :compact (or (etaf-value compact) (etaf-value stacked)) :narrow (etaf-value narrow)))
        (salvage--sidebar :if (not (etaf-value drawer)) :key 'side-pane
          :session session :selected selected :active cargo-tab
          :horizontal (etaf-value stacked) :compact (or (etaf-value compact) (etaf-value stacked))))
      (salvage--commands :if (etaf-value ready) :session session :narrow (etaf-value narrow))
      (etaf-alert :if (etaf-gamekit-last-error session) :title "Action not completed"
                  :message (etaf-gamekit-last-error session) :variant 'danger)
      (salvage--log :if (etaf-value ready) :session session :compact (etaf-value dense))
      (etaf-dialog :open (and (etaf-value ready) (etaf-value drawer) (etaf-value tools))
                   :title "EXPEDITION CONSOLE" :width '(ch 72) :compact t
                   :on-close (lambda () (setf (etaf-value tools) nil))
        (salvage--sidebar :session session :selected selected :active cargo-tab :horizontal t :compact t))
      (etaf-dialog :open help :title "FLIGHT MANUAL" :width '(ch 68) :compact t
                   :on-close (lambda () (setf (etaf-value help) nil))
        (column :item-gap '(lh 1)
          (etaf-label :text "Recover ◆ cores in all three sectors, then reach ▣ extraction." :wrap-mode 'word)
          (etaf-label :text "W A S D steer. Click empty deck to navigate around bulkheads. Click an object to inspect it." :wrap-mode 'word)
          (etaf-label :text "P pauses the simulation. 1 fires an EMP within five tiles. 2 protects your hull for five seconds." :wrap-mode 'word)
          (etaf-label :text "Use Cargo for repairs. Save and Load preserve the expedition. A restored run starts paused." :wrap-mode 'word))))))

(defun salvage--view (session)
  "Compose the game from the public ETAF and GameKit contracts."
  (etaf-view (salvage--app :session session)))

(etaf-gamekit-define-game salvage-game
  :title "Salvage Station" :backend 'godot
  :options (list :project salvage--directory)
  :view #'salvage--view :validate #'salvage--valid-p)

(defun salvage-open ()
  "Start and display an independent Salvage Station expedition."
  (interactive)
  (let ((session (etaf-gamekit-start salvage-game)))
    (pop-to-buffer (etaf-gamekit-buffer session))
    (etaf-refit (etaf-runtime-for-buffer (etaf-gamekit-buffer session)) (selected-window))
    session))

(provide 'salvage)
;;; salvage.el ends here
