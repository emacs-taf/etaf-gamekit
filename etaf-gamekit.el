;;; -*- lexical-binding: t; -*-
;;; etaf-gamekit.el --- External game engines in native ETAF buffers

;; SPDX-License-Identifier: GPL-3.0-or-later
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (etaf "0.2.1") (etaf-ui "0.1.0"))
;; Keywords: games

;;; Commentary:
;; Run mature game engines out of process and compose their observations with
;; ETAF's public component catalog.  The backend owns game rules and saves.
;; See docs/manual.md for installation, lifecycle and the adapter wire contract.
;;
;; Error: etaf-gamekit-error
;; An invalid session action, missing engine or malformed adapter message.
;; Rejected synchronous calls do not send input.  Asynchronous failures are
;; available through etaf-gamekit-status and etaf-gamekit-last-error.
;;
;; Variable: etaf-gamekit-engine-directory
;; Cache directory populated by scripts/setup-engines.py.  Defaults to
;; $XDG_CACHE_HOME/emacs-taf/game-engines or ~/.cache/emacs-taf/game-engines.
;; Set before opening a built-in game; existing sessions keep their command.
;;
;; Variable: etaf-gamekit-request-timeout
;; Positive seconds allowed for startup or an action (default 15). A timeout
;; fails the connection, preserves its last observation and terminates the child.
;;
;; Function: etaf-gamekit-start (command &optional buffer-or-name)
;;;###autoload (autoload 'etaf-gamekit-start "etaf-gamekit" nil nil)
;; Start COMMAND (a program/argument string list) and return an opaque session.
;; The child implements the version-1 JSON-lines contract in docs/manual.md.
;; BUFFER-OR-NAME defaults to a fresh game buffer; an existing buffer must be
;; empty and unmounted.  Startup is asynchronous.  Killing or unmounting the
;; buffer releases its process, timer and stderr buffer.  Each session has
;; at most one outstanding action; observations may be coalesced for display.
;;
;; Function: etaf-gamekit-action (session operation &optional arguments)
;;;###autoload (autoload 'etaf-gamekit-action "etaf-gamekit" nil nil)
;; Send the advertised OPERATION string with ARGUMENTS, a keyword plist.
;; Return its increasing request id.  A busy, failed or closed session, an
;; unadvertised operation or malformed arguments signals etaf-gamekit-error.
;; A backend rejection retains the backend's accepted observation, returns to
;; ready and sets etaf-gamekit-last-error; it does not imply a successful move.
;;
;; Function: etaf-gamekit-status (session)
;; Return starting, busy, ready, failed or closed.  A ready session has accepted
;; a complete response; its display is scheduled within 1/60 s, plus rendering.
;;
;; Function: etaf-gamekit-observation (session)
;; Return a detached copy of the latest accepted view plist, or nil at startup.
;; This is backend output, never writable game state.  No process wait occurs.
;;
;; Function: etaf-gamekit-last-error (session)
;; Return the latest backend rejection or transport failure string, or nil.
;; A successful response clears it.  Failed sessions require a new connection.
;;
;; Function: etaf-gamekit-buffer (session)
;; Return the session's application buffer, which may have been killed.
;;
;; Function: etaf-gamekit-close (session)
;;;###autoload (autoload 'etaf-gamekit-close "etaf-gamekit" nil nil)
;; Idempotently stop the owned process/timer and unmount the application.
;; Retain its buffer and latest observation for inspection.  No save is implied.
;;
;; Function: etaf-gamekit-open-chess (&optional fen buffer-or-name)
;;;###autoload (autoload 'etaf-gamekit-open-chess "etaf-gamekit" nil t)
;; Open chess with python-chess rules and optional Stockfish moves; return the
;; session.  FEN defaults to the standard initial position.  Engine installation
;; uses etaf-gamekit-engine-directory.  Interactive invocation displays the buffer.
;;
;; Function: etaf-gamekit-open-story (story &optional buffer-or-name)
;;;###autoload (autoload 'etaf-gamekit-open-story "etaf-gamekit" nil t)
;; Open a local Glulx STORY with Glulxe/RemGlk and return the session.  Text-buffer
;; and text-grid windows plus line/character input are supported.  Graphics,
;; sound, timers, hyperlinks and Glk file dialogs are outside this MVP contract.
;; Use the frontend Save/Load controls for same-build opaque VM snapshots.
;;
;; Function: etaf-gamekit-open-demo ()
;;;###autoload (autoload 'etaf-gamekit-open-demo "etaf-gamekit" nil t)
;; Open the maintained Last Beacon story compiled by scripts/setup-engines.py.
;; Return its session and display the game buffer.

;;; Code:
(require 'etaf-ui)
(defconst etaf-gamekit--directory
  (file-name-directory (or load-file-name buffer-file-name)))
(defgroup etaf-gamekit nil "External game engines in ETAF." :group 'games)
(defcustom etaf-gamekit-engine-directory
  (expand-file-name "emacs-taf/game-engines"
                    (or (getenv "XDG_CACHE_HOME") (expand-file-name "~/.cache")))
  "Directory containing the installed game engines and example story."
  :type 'directory :group 'etaf-gamekit)
(defcustom etaf-gamekit-request-timeout 15
  "Maximum seconds for one complete adapter response."
  :type 'number :group 'etaf-gamekit)
(define-error 'etaf-gamekit-error "ETAF game error")
(let ((load-path (cons (expand-file-name "lisp" etaf-gamekit--directory) load-path)))
  (require 'etaf-gamekit-session)
  (require 'etaf-gamekit-view))
(provide 'etaf-gamekit)
;;; etaf-gamekit.el ends here
