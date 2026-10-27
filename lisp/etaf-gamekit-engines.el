;;; -*- lexical-binding: t; -*-
;;; etaf-gamekit-engines.el --- Install the engine runtimes GameKit launches

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Commentary:
;; Godot is a system program, so the archive cannot ship its binary.  It does
;; ship the pinned setup script, and this module runs that script from the
;; installed package, so an archive installation reaches a working runtime with
;; one command.  The script verifies the release checksum before unpacking and
;; writes only under the user cache; nothing here edits PATH or init files.

;;; Code:
(require 'cl-lib)

(defvar etaf-gamekit--directory)
(defvar etaf-gamekit-godot-program)

(defconst etaf-gamekit--engine-log-buffer "*ETAF engine install*"
  "Buffer receiving progress from an engine setup run.")

(defvar etaf-gamekit--engine-install-process nil
  "Engine setup process that is currently running, or nil.")

(defun etaf-gamekit--engine-setup-script ()
  "Return the engine setup script shipped with this package, or nil.
Candidates are the directory this package loaded from, `locate-library' and the
installed package descriptor.  Native compilation moves `load-file-name' into
the byte-compilation cache, so a candidate counts only when it really holds the
script."
  (let* ((installed (car (alist-get 'etaf-gamekit (bound-and-true-p package-alist))))
         (candidates (delq nil
                           (list (and (boundp 'etaf-gamekit--directory) etaf-gamekit--directory)
                                 (let ((library (locate-library "etaf-gamekit")))
                                   (and library (file-name-directory library)))
                                 (and installed (fboundp 'package-desc-dir)
                                      (package-desc-dir installed))))))
    (cl-loop for directory in candidates
             for script = (expand-file-name "native/godot/install-godot.py" directory)
             when (file-readable-p script)
             return script)))

(defun etaf-gamekit--engine-failure-line ()
  "Return the setup script's failure line from the current log buffer."
  (save-excursion
    (goto-char (point-max))
    (if (re-search-backward "^Engine setup failed:.*$" nil t)
        (match-string 0)
      (when (re-search-backward "[^[:space:]]" nil t)
        (buffer-substring (line-beginning-position) (line-end-position))))))

(defun etaf-gamekit--engine-install-sentinel (process _event)
  "Report the outcome of engine setup PROCESS and clear the running marker."
  (when (memq (process-status process) '(exit signal))
    (setq etaf-gamekit--engine-install-process nil)
    (let ((status (process-exit-status process))
          (log (process-buffer process)))
      (if (and (eq (process-status process) 'exit) (zerop status))
          (message "ETAF: Godot runtime ready at %s; Godot games can start now"
                   (or (executable-find etaf-gamekit-godot-program)
                       etaf-gamekit-godot-program))
        (message "ETAF: Godot install failed. %s See %s"
                 (or (and (buffer-live-p log)
                          (with-current-buffer log (etaf-gamekit--engine-failure-line)))
                     "The setup script exited without a report.")
                 etaf-gamekit--engine-log-buffer)))))

;;;###autoload
(defun etaf-gamekit-install-godot (&optional godot)
  "Install the pinned Godot runtime that GameKit games run.
GODOT registers an existing Godot 4.7 or newer executable instead of
downloading the pinned release.  The packaged setup script verifies the
release's SHA-256 before unpacking and writes only under
`~/.cache/emacs-taf/game-engines', honouring XDG_CACHE_HOME; it starts no
package manager and leaves PATH and init files alone.  Installation runs in the
background: progress goes to `etaf-gamekit--engine-log-buffer' and the echo
area reports the result.  One run happens at a time, and a failure keeps an
already working runtime in place."
  (interactive
   (list (and current-prefix-arg
              (expand-file-name (read-file-name "Godot 4.7 or newer: " nil nil t)))))
  (when (process-live-p etaf-gamekit--engine-install-process)
    (user-error "An engine install is already running; see %s"
                etaf-gamekit--engine-log-buffer))
  (let ((script (etaf-gamekit--engine-setup-script))
        (python (executable-find "python3")))
    (unless script
      (user-error "This installation has no native/godot/install-godot.py; reinstall etaf-gamekit"))
    (unless python
      (user-error "Python 3.9 or newer is required to install the Godot runtime"))
    (let* ((command (append (list python script) (when godot (list "--godot" godot))))
           (buffer (get-buffer-create etaf-gamekit--engine-log-buffer)))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "Installing the Godot runtime: %s\n\n"
                          (mapconcat #'identity command " "))))
        (setq default-directory (file-name-directory script)))
      (display-buffer buffer)
      (setq etaf-gamekit--engine-install-process
            (make-process :name "etaf-gamekit-install-godot"
                          :buffer buffer
                          :command command
                          :noquery t
                          :sentinel #'etaf-gamekit--engine-install-sentinel))
      (message "ETAF: installing the Godot runtime; progress in %s"
               etaf-gamekit--engine-log-buffer))))

(provide 'etaf-gamekit-engines)
;;; etaf-gamekit-engines.el ends here
