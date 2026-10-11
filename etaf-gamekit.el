;;; -*- lexical-binding: t; -*-
;;; etaf-gamekit.el --- Game runtimes with native ETAF presentation

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (etaf "0.2.1") (etaf-ui "0.1.0"))
;; Keywords: games

;;; Commentary:
;; GameKit gives external game runtimes one session and message contract.
;; Godot is the included runtime. Games own rules and observations; applications
;; compose any ETAF view from those observations. See docs/manual.md.
;;
;; Error: etaf-gamekit-error
;; Invalid session operation, missing runtime or malformed protocol message.
;; Synchronous rejection sends no input. Asynchronous failure is available
;; through etaf-gamekit-status and etaf-gamekit-last-error.
;;
;; Variable: etaf-gamekit-godot-program
;; Godot 4.7+ executable or PATH command. Defaults to the pinned cache install
;; from scripts/setup-engine.py. Set before opening a Godot session.
;;
;; Variable: etaf-gamekit-request-timeout
;; Positive startup/action deadline in seconds (default 15). Timeout fails the
;; connection and retains its latest observation for recovery and inspection.
;;
;; Function: etaf-gamekit-start (command &key buffer view validate)
;;;###autoload (autoload 'etaf-gamekit-start "etaf-gamekit" nil nil)
;; Start COMMAND, a program/argument string list, and return an opaque session.
;; BUFFER is a name or buffer; omitted creates a fresh buffer. A supplied buffer
;; must be empty and unmounted. VIEW is a function receiving the session and
;; returning an ETAF View; omitted displays connection status. VALIDATE, when
;; supplied, is a pure function receiving a detached observation and returning
;; exactly t for a valid application schema. Rejection fails the connection.
;; Startup is asynchronous. Killing or unmounting the buffer releases the
;; owned process and timers. The wire contract is in docs/manual.md.
;;
;; Function: etaf-gamekit-action (session operation &optional arguments)
;;;###autoload (autoload 'etaf-gamekit-action "etaf-gamekit" nil nil)
;; Send an advertised OPERATION string with keyword-plist ARGUMENTS, returning
;; its increasing request id. Up to eight requests may be outstanding, with
;; acknowledgments accepted in order. Starting, failed/closed, full-queue,
;; unadvertised or unserializable calls signal etaf-gamekit-error.
;; A backend rejection retains the valid state and records last-error. The
;; session returns to ready after all outstanding requests are acknowledged.
;;
;; Function: etaf-gamekit-status (session)
;; Return starting, busy, ready, failed or closed. Reads inside an ETAF View
;; track the coalesced connection display. Ready means a response was accepted,
;; with display publication scheduled within 1/60 second plus rendering time.
;;
;; Function: etaf-gamekit-observation (session)
;; Return a detached copy of the latest accepted backend observation, or nil
;; during startup. It never waits or changes the authoritative backend state.
;;
;; Function: etaf-gamekit-view (session &optional field)
;; Reactively read a detached copy of the coalesced display observation.
;; FIELD, when supplied, is a top-level keyword selecting one field to copy.
;; Use this inside ETAF views/computed values; intermediate streamed frames may
;; be skipped. The caller owns the returned copy, not the backend's state.
;;
;; Function: etaf-gamekit-capabilities (session)
;; Reactively read a detached list of action names advertised by the backend.
;; An action name is not a UI widget; the application's presentation chooses
;; meaningful controls and the game validates every incoming action.
;;
;; Function: etaf-gamekit-last-error (session)
;; Reactively read the latest backend rejection or transport failure, or nil.
;; A successful acknowledged action clears it; unsolicited frames do not.
;; Failed sessions require a new connection.
;;
;; Function: etaf-gamekit-buffer (session)
;; Return the application buffer, which may have been killed.
;;
;; Function: etaf-gamekit-close (session)
;;;###autoload (autoload 'etaf-gamekit-close "etaf-gamekit" nil nil)
;; Idempotently release the session's process, timers and application mount.
;; Preserve its buffer and last observation for inspection. No save is implied.
;;
;; Function: etaf-gamekit-open-godot (project &key buffer view validate)
;;;###autoload (autoload 'etaf-gamekit-open-godot "etaf-gamekit" nil nil)
;; Run PROJECT's project.godot with the shared Godot bridge; return a session.
;; The project supplies gamekit/game_script with the game-side contract in the
;; manual. BUFFER, VIEW and VALIDATE have the same meaning as start. No Godot
;; window opens; all presentation and input remain in ETAF.
;;
;; Function: etaf-gamekit-open-demo ()
;;;###autoload (autoload 'etaf-gamekit-open-demo "etaf-gamekit" nil t)
;; Open Salvage Station, the maintained real-time Godot integration game.
;; Return its session and display its native ETAF application buffer.

;;; Code:
(require 'etaf-ui)
(defconst etaf-gamekit--directory
  (file-name-directory (or load-file-name buffer-file-name)))
(defgroup etaf-gamekit nil "Game runtimes with ETAF presentation." :group 'games)
(defcustom etaf-gamekit-godot-program
  (expand-file-name
   "emacs-taf/game-engines/bin/godot"
   (or (getenv "XDG_CACHE_HOME") (expand-file-name "~/.cache")))
  "Godot executable used by new game sessions."
  :type 'string :group 'etaf-gamekit)
(defcustom etaf-gamekit-request-timeout 15
  "Maximum seconds for a complete adapter response."
  :type 'number :group 'etaf-gamekit)
(define-error 'etaf-gamekit-error "ETAF game error")
(let ((load-path (cons (expand-file-name "lisp" etaf-gamekit--directory) load-path)))
  (require 'etaf-gamekit-session)
  (require 'etaf-gamekit-view)
  (require 'etaf-gamekit-salvage))
(provide 'etaf-gamekit)
;;; etaf-gamekit.el ends here
