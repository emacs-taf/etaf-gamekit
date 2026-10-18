;;; -*- lexical-binding: t; -*-
;;; etaf-gamekit-view.el --- Lifetime around caller-owned presentations

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'etaf-gamekit-game)

(etaf-define-component etaf-gamekit--root (&key session)
  :setup (progn (etaf-on-unmounted (lambda () (etaf-gamekit-close session))) nil)
  :view
  (expr
   (if (etaf-gamekit--session-presentation session)
       (funcall (etaf-gamekit--session-presentation session) session)
     (etaf-view
      (column :role 'region
        (text (expr (plist-get (etaf-gamekit-game-info session) :title)))
        (text (expr (symbol-name (etaf-gamekit-status session))))
        (text (expr (or (etaf-gamekit-last-error session) ""))))))))

(defun etaf-gamekit--mount (session)
  "Mount SESSION's presentation with an owned lifetime boundary."
  (etaf-mount (etaf-gamekit-buffer session) (etaf-view (etaf-gamekit--root :session session))))

(defun etaf-gamekit-display (session)
  "Show SESSION's presentation in its own buffer and return the buffer.
A session owns one presentation, so this mounts at most once: a host that
renders the same session in a window calls `etaf-gamekit-create'-style
sessions instead (see `etaf-gamekit-start') and never mounts twice."
  (unless (etaf-gamekit--session-displayed session)
    (setf (etaf-gamekit--session-displayed session) t)
    (etaf-gamekit--mount session))
  (etaf-gamekit-buffer session))

(provide 'etaf-gamekit-view)
;;; etaf-gamekit-view.el ends here
