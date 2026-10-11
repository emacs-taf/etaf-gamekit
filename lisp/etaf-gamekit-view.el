;;; -*- lexical-binding: t; -*-
;;; etaf-gamekit-view.el --- Lifetime around caller-owned presentations

;; SPDX-License-Identifier: GPL-3.0-or-later
;;; Code:
(require 'etaf-ui)
(require 'etaf-gamekit-session)

(etaf-define-component etaf-gamekit--root (&key session)
  :setup (progn (etaf-on-unmounted (lambda () (etaf-gamekit-close session))) nil)
  :view
  (expr
   (if (etaf-gamekit--session-presentation session)
       (funcall (etaf-gamekit--session-presentation session) session)
     (etaf-view
      (etaf-panel :title "Game session"
        (etaf-label :text (symbol-name (etaf-gamekit-status session)))
        (etaf-label :text (or (etaf-gamekit-last-error session) "Connected through GameKit")))))))

(defun etaf-gamekit--mount (session)
  "Mount SESSION's presentation with an owned lifetime boundary."
  (etaf-mount (etaf-gamekit-buffer session) (etaf-view (etaf-gamekit--root :session session))))

(provide 'etaf-gamekit-view)
;;; etaf-gamekit-view.el ends here
