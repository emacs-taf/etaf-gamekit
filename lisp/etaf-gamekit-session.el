;;; -*- lexical-binding: t; -*-
;;; etaf-gamekit-session.el --- Asynchronous game adapter lifecycle

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:
(require 'cl-lib)
(require 'json)
(require 'etaf-ui)
(defvar etaf-gamekit--directory)
(defvar etaf-gamekit-engine-directory)
(defvar etaf-gamekit-request-timeout)
(declare-function etaf-gamekit--mount "etaf-gamekit-view" (session))

(cl-defstruct (etaf-gamekit--session (:constructor etaf-gamekit--make-session))
  process buffer stderr timer deadline (input "") (next-id 0) pending
  (revision 0) capabilities observation error (status 'starting)
  (view-ref (etaf-ref nil)) (capabilities-ref (etaf-ref nil)) (status-ref (etaf-ref "Starting engine…"))
  (error-ref (etaf-ref "")))

(defun etaf-gamekit-status (session)
  "Return SESSION's current connection state."
  (etaf-gamekit--session-status session))

(defun etaf-gamekit-buffer (session)
  "Return SESSION's application buffer."
  (etaf-gamekit--session-buffer session))

(defun etaf-gamekit-last-error (session)
  "Return SESSION's latest rejection or transport error."
  (etaf-gamekit--session-error session))

(defun etaf-gamekit-observation (session)
  "Return a detached copy of SESSION's latest backend view."
  (cl-labels ((clone (value)
                (cond ((stringp value) (copy-sequence value))
                      ((consp value) (cons (clone (car value)) (clone (cdr value))))
                      (t value))))
    (clone (etaf-gamekit--session-observation session))))

(defun etaf-gamekit--publish (session)
  "Publish SESSION's newest accepted projection in one reactive batch."
  (setf (etaf-gamekit--session-timer session) nil)
  (when (and (buffer-live-p (etaf-gamekit-buffer session))
             (etaf-runtime-for-buffer (etaf-gamekit-buffer session)))
    (etaf-batch
      (setf (etaf-value (etaf-gamekit--session-view-ref session))
            (etaf-gamekit--session-observation session)
            (etaf-value (etaf-gamekit--session-status-ref session))
            (pcase (etaf-gamekit-status session)
              ('starting "Starting engine…") ('busy "Engine working…")
              ('failed "Engine disconnected") ('closed "Closed") (_ "Ready"))
            (etaf-value (etaf-gamekit--session-error-ref session))
            (or (etaf-gamekit-last-error session) "")
            (etaf-value (etaf-gamekit--session-capabilities-ref session))
            (etaf-gamekit--session-capabilities session)))))

(defun etaf-gamekit--schedule (session)
  "Coalesce SESSION's observations into at most sixty displays per second."
  (unless (etaf-gamekit--session-timer session)
    (setf (etaf-gamekit--session-timer session)
          (run-at-time (/ 1.0 60) nil #'etaf-gamekit--publish session))))

(defun etaf-gamekit--fail (session message)
  "Record MESSAGE and release SESSION's failed transport."
  (unless (eq (etaf-gamekit-status session) 'closed)
    (when-let* ((deadline (etaf-gamekit--session-deadline session)))
      (cancel-timer deadline) (setf (etaf-gamekit--session-deadline session) nil))
    (setf (etaf-gamekit--session-status session) 'failed
          (etaf-gamekit--session-error session) message
          (etaf-gamekit--session-pending session) nil)
    (when-let* ((process (etaf-gamekit--session-process session)))
      (when (process-live-p process) (signal-process process 'SIGTERM)))
    (etaf-gamekit--schedule session)))

(defun etaf-gamekit--object-p (value)
  "Whether decoded VALUE is a JSON object represented as a keyword plist."
  (and (proper-list-p value) (zerop (% (length value) 2))
       (cl-loop for (key _value) on value by #'cddr always (keywordp key))))

(defun etaf-gamekit--view-valid-p (view)
  "Whether VIEW can be safely consumed by the declared presentation."
  (and (etaf-gamekit--object-p view) (stringp (plist-get view :title))
       (stringp (plist-get view :status))
       (pcase (plist-get view :kind)
         ("chess"
          (and (proper-list-p (plist-get view :board))
               (= (length (plist-get view :board)) 8)
               (cl-every (lambda (row)
                           (and (stringp row)
                                (string-match-p "\\`[prnbqkPRNBQK.]\\(?: [prnbqkPRNBQK.]\\)\\{7\\}\\'" row)))
                         (plist-get view :board))
               (proper-list-p (plist-get view :legal))
               (proper-list-p (plist-get view :moves))
               (or (null (plist-get view :last_move))
                   (stringp (plist-get view :last_move)))
               (cl-every (lambda (move)
                           (and (stringp move)
                                (string-match-p "\\`[a-h][1-8][a-h][1-8][qrbn]?\\'" move)))
                         (append (plist-get view :legal) (plist-get view :moves)))))
         ("grid"
          (let ((columns (plist-get view :columns)) (rows (plist-get view :rows)))
            (and (integerp columns) (<= 1 columns 320) (proper-list-p rows)
                 (<= 1 (length rows) 120)
                 (cl-every (lambda (row) (and (stringp row)
                                              (not (string-match-p "[\n\r\t]" row))
                                              (<= (string-width row) columns))) rows))))
         ("story"
          (and (proper-list-p (plist-get view :windows))
               (integerp (plist-get view :generation))
               (proper-list-p (plist-get view :input))
               (cl-every (lambda (input)
                           (and (etaf-gamekit--object-p input)
                                (integerp (plist-get input :id))
                                (member (plist-get input :type) '("line" "char"))))
                         (plist-get view :input))
               (cl-every
                (lambda (window)
                  (and (etaf-gamekit--object-p window) (integerp (plist-get window :id))
                       (pcase (plist-get window :type)
                         ("buffer" (stringp (plist-get window :text)))
                         ("grid" (and (proper-list-p (plist-get window :lines))
                                      (integerp (plist-get window :gridheight))
                                      (= (plist-get window :gridheight)
                                         (length (plist-get window :lines)))
                                      (etaf-gamekit--view-valid-p
                                       (list :kind "grid" :title "" :status ""
                                             :columns (plist-get window :gridwidth)
                                             :rows (plist-get window :lines)))))
                         (_ nil))))
                (plist-get view :windows))))
         (_ nil))))

(defun etaf-gamekit--accept (session message)
  "Validate and accept one decoded adapter MESSAGE for SESSION."
  (unless (etaf-gamekit--object-p message)
    (signal 'etaf-gamekit-error '("Adapter response must be a JSON object")))
  (let ((id (plist-get message :id)) (revision (plist-get message :revision))
        (view (plist-get message :view)) (capabilities (plist-get message :capabilities))
        (failure (plist-get message :error)))
    (unless (and (equal (plist-get message :version) 1)
                 (integerp revision) (> revision (etaf-gamekit--session-revision session))
                 (or (null id) (equal id (etaf-gamekit--session-pending session)))
                 (etaf-gamekit--view-valid-p view)
                 (proper-list-p capabilities) (cl-every #'stringp capabilities)
                 (or (null failure) (stringp failure)))
      (signal 'etaf-gamekit-error '("Malformed, stale or uncorrelated adapter response")))
    (setf (etaf-gamekit--session-revision session) revision
          (etaf-gamekit--session-observation session) view
          (etaf-gamekit--session-capabilities session) capabilities)
    (when (or id failure)
      (setf (etaf-gamekit--session-error session) failure))
    (when id
      (when-let* ((deadline (etaf-gamekit--session-deadline session)))
        (cancel-timer deadline) (setf (etaf-gamekit--session-deadline session) nil))
      (setf (etaf-gamekit--session-pending session) nil
            (etaf-gamekit--session-status session) 'ready))
    (etaf-gamekit--schedule session)))

(defun etaf-gamekit--filter (session chunk)
  "Decode bounded JSON-lines from adapter CHUNK for SESSION."
  (unless (memq (etaf-gamekit-status session) '(closed failed))
    (condition-case failure
        (let ((pending (concat (etaf-gamekit--session-input session) chunk)))
          (while (string-match "\n" pending)
            (let ((line (substring pending 0 (match-beginning 0))))
              (setq pending (substring pending (match-end 0)))
              (when (> (string-bytes line) (* 1024 1024))
                (signal 'etaf-gamekit-error '("Adapter message exceeds 1 MiB")))
              (unless (string-empty-p line)
                (etaf-gamekit--accept
                 session (json-parse-string line :object-type 'plist :array-type 'list
                                            :null-object nil :false-object :false)))))
          (when (> (string-bytes pending) (* 1024 1024))
            (signal 'etaf-gamekit-error '("Unterminated adapter message exceeds 1 MiB")))
          (setf (etaf-gamekit--session-input session) pending))
      ((json-parse-error etaf-gamekit-error)
       (etaf-gamekit--fail session (error-message-string failure))))))

(defun etaf-gamekit--send (session operation arguments)
  "Send validated OPERATION and ARGUMENTS to SESSION."
  (let* ((id (1+ (etaf-gamekit--session-next-id session)))
         (encoded (condition-case failure
                      (concat (json-serialize
                               (list :id id :op operation
                                     :args (or arguments (make-hash-table)))
                               :false-object :false) "\n")
                    (error (signal 'etaf-gamekit-error
                                   (list (error-message-string failure)))))))
    (setf (etaf-gamekit--session-next-id session) id
          (etaf-gamekit--session-pending session) id)
    (unless (eq (etaf-gamekit-status session) 'starting)
      (setf (etaf-gamekit--session-status session) 'busy))
    (condition-case failure
        (process-send-string (etaf-gamekit--session-process session) encoded)
      (error
       (etaf-gamekit--fail session (error-message-string failure))
       (signal 'etaf-gamekit-error (list (error-message-string failure)))))
    (setf (etaf-gamekit--session-deadline session)
          (run-at-time etaf-gamekit-request-timeout nil
                       (lambda ()
                         (when (equal id (etaf-gamekit--session-pending session))
                           (etaf-gamekit--fail session "Engine response timed out")))))
    (etaf-gamekit--schedule session)
    id))

(defun etaf-gamekit-action (session operation &optional arguments)
  "Send SESSION an advertised OPERATION with keyword-plist ARGUMENTS."
  (unless (and (eq (etaf-gamekit-status session) 'ready)
               (member operation (etaf-gamekit--session-capabilities session))
               (proper-list-p arguments) (zerop (% (length arguments) 2))
               (cl-loop for (key _value) on arguments by #'cddr always (keywordp key)))
    (signal 'etaf-gamekit-error '("Action needs a ready session, an advertised operation and keyword arguments")))
  (etaf-gamekit--send session operation arguments))

(defun etaf-gamekit-close (session)
  "Release SESSION's process, timer and mount, preserving its buffer."
  (unless (eq (etaf-gamekit-status session) 'closed)
    (when-let* ((deadline (etaf-gamekit--session-deadline session)))
      (cancel-timer deadline) (setf (etaf-gamekit--session-deadline session) nil))
    (setf (etaf-gamekit--session-status session) 'closed
          (etaf-gamekit--session-pending session) nil)
    (when-let* ((timer (etaf-gamekit--session-timer session)))
      (cancel-timer timer) (setf (etaf-gamekit--session-timer session) nil))
    (when-let* ((process (etaf-gamekit--session-process session)))
      (when (process-live-p process) (signal-process process 'SIGTERM)))
    (when (buffer-live-p (etaf-gamekit--session-stderr session))
      (kill-buffer (etaf-gamekit--session-stderr session)))
    (when (buffer-live-p (etaf-gamekit-buffer session))
      (when-let* ((runtime (etaf-runtime-for-buffer (etaf-gamekit-buffer session))))
        (etaf-unmount runtime))))
  nil)

(defun etaf-gamekit-start (command &optional buffer-or-name)
  "Start adapter COMMAND, mount BUFFER-OR-NAME and return its opaque session."
  (unless (and (numberp etaf-gamekit-request-timeout) (> etaf-gamekit-request-timeout 0)
               (consp command) (proper-list-p command) (cl-every #'stringp command))
    (signal 'etaf-gamekit-error '("Command must be a nonempty program/argument list")))
  (let* ((buffer (if buffer-or-name (get-buffer-create buffer-or-name)
                   (generate-new-buffer "*ETAF Game*")))
         (session (etaf-gamekit--make-session :buffer buffer)))
    (unless (and (zerop (buffer-size buffer)) (not (etaf-runtime-for-buffer buffer)))
      (signal 'etaf-gamekit-error '("The game buffer must be empty and unmounted")))
    (condition-case failure
        (progn
          (setf (etaf-gamekit--session-stderr session) (generate-new-buffer " *Game engine stderr*"))
          (etaf-gamekit--mount session)
          (with-current-buffer buffer
            (add-hook 'kill-buffer-hook (lambda () (etaf-gamekit-close session)) nil t))
          (setf (etaf-gamekit--session-process session)
                (make-process
                 :name (generate-new-buffer-name "etaf-gamekit-engine")
                 :command command :connection-type 'pipe :coding 'utf-8-unix :noquery t
                 :stderr (etaf-gamekit--session-stderr session)
                 :filter (lambda (_process text) (etaf-gamekit--filter session text))
                 :sentinel
                 (lambda (process event)
                   (when (and (memq (process-status process) '(exit signal failed))
                              (not (memq (etaf-gamekit-status session) '(closed failed))))
                     (etaf-gamekit--fail
                      session
                      (concat (string-trim event)
                              (when (buffer-live-p (etaf-gamekit--session-stderr session))
                                (with-current-buffer (etaf-gamekit--session-stderr session)
                                  (concat ": " (buffer-substring-no-properties
                                                (max (point-min) (- (point-max) 2000))
                                                (point-max)))))))))))
          (etaf-gamekit--send session "start" nil)
          session)
      (error
       (etaf-gamekit-close session)
       (signal (car failure) (cdr failure))))))

(defun etaf-gamekit--program (relative fallback)
  "Find cached RELATIVE or executable FALLBACK, with an actionable error."
  (let ((path (expand-file-name relative etaf-gamekit-engine-directory)))
    (or (and (file-executable-p path) path) (and fallback (executable-find fallback))
        (signal 'etaf-gamekit-error
                (list (format "Missing %s; run python3 scripts/setup-engines.py" relative))))))

(defun etaf-gamekit--command (adapter)
  "Return the installed runner prefix for ADAPTER."
  (list (etaf-gamekit--program "python/bin/python3" "python3")
        (expand-file-name "scripts/run-engine.py" etaf-gamekit--directory)
        "--adapter" adapter))

(defun etaf-gamekit--display (session)
  "Show SESSION and fit a buffer that was mounted before it had a window."
  (pop-to-buffer (etaf-gamekit-buffer session))
  (etaf-refit (etaf-runtime-for-buffer (etaf-gamekit-buffer session)) (selected-window)))

(defun etaf-gamekit-open-chess (&optional fen buffer-or-name)
  "Open a chess session at FEN in BUFFER-OR-NAME."
  (interactive)
  (let ((session (etaf-gamekit-start
                  (append (etaf-gamekit--command "chess")
                          (list "--stockfish" (etaf-gamekit--program "bin/stockfish" "stockfish"))
                          (when fen (list "--fen" fen))) buffer-or-name)))
    (when (called-interactively-p 'interactive) (etaf-gamekit--display session))
    session))

(defun etaf-gamekit-open-story (story &optional buffer-or-name)
  "Open a Glulx STORY session in BUFFER-OR-NAME."
  (interactive "fGlulx story: ")
  (unless (file-readable-p story) (signal 'etaf-gamekit-error '("Story file is unreadable")))
  (let ((session (etaf-gamekit-start
                  (append (etaf-gamekit--command "glulx")
                          (list "--glulxe" (etaf-gamekit--program "bin/glulxe" "glulxe")
                                "--story" (expand-file-name story))) buffer-or-name)))
    (when (called-interactively-p 'interactive) (etaf-gamekit--display session))
    session))

(defun etaf-gamekit-open-demo ()
  "Open the installed Last Beacon example and return its session."
  (interactive)
  (let ((session (etaf-gamekit-open-story
                  (expand-file-name "last-beacon.ulx" etaf-gamekit-engine-directory))))
    (etaf-gamekit--display session)
    session))

(provide 'etaf-gamekit-session)
;;; etaf-gamekit-session.el ends here
