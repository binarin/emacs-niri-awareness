;;; niri-frame-visible.el --- Advise frame-visible-p with niri window visibility -*- lexical-binding: t -*-

;; Copyright (C) 2025

;; Author: Emacs niri awareness
;; Keywords: niri, frames, visibility
;; Package-Requires: ((emacs "28.1") (niri-rpc "0") (niri-frame "0"))

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; This package advises `frame-visible-p' to take the actual niri window
;; geometry into account.  When `track-niri-frame-visibility-mode' is
;; enabled, `frame-visible-p' can return nil for frames that are not
;; sufficiently visible on any output, even when Emacs normally considers
;; the frame visible.
;;
;; This is useful for packages that use `frame-visible-p' to decide
;; whether to display things (e.g. notifications, popups, etc.) — with
;; niri's scrolling tiling layout, a frame may be "visible" from Emacs's
;; perspective but scrolled off-screen.
;;
;; The visibility threshold is controlled by `niri-frame-visible-threshold'.
;; At the default of 0.5, a frame must have at least 50% of its area within
;; the bounds of at least one output.
;;
;; Preconditions:
;;  - `niri-rpc-connect' must have been called.
;;  - `niri-frame-enable' must have been called.
;;  - The niri version must provide tile position information (recent
;;    versions of niri include `tile_pos_in_workspace_view' in window
;;    layouts).  If this information is unavailable (unpatched older
;;    niri), `frame-visible-p' is not modified.
;;
;; Usage:
;;
;;   (require 'niri-rpc)
;;   (require 'niri-frame)
;;   (require 'niri-frame-visible)
;;   (niri-rpc-connect)
;;   (niri-frame-enable)
;;   (track-niri-frame-visibility-mode 1)

;;; Code:

(require 'niri-rpc)
(require 'niri-frame)
(require 'cl-lib)

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; Customization
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(defgroup niri-frame-visible nil
  "Override `frame-visible-p' based on niri window visibility."
  :group 'niri-frame)

(defcustom niri-frame-visible-threshold 0.5
  "Fraction of a frame that must be visible on at least one output.
When `track-niri-frame-visibility-mode' is enabled, `frame-visible-p'
will return nil for frames whose niri window has less than this
fraction of its area overlapping any output.

Must be a float between 0.0 and 1.0.  A value of 0.5 means at
least 50% of the frame must be on-screen."
  :type 'float
  :group 'niri-frame-visible)

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; Visibility computation
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(defun niri-frame-visible--rect-visible-p (rect)
  "Return non-nil if RECT is sufficiently visible on any output.

RECT is a list of four numbers (X Y WIDTH HEIGHT) in logical
pixels, representing the frame's niri window in the virtual
coordinate space.

A rect is considered visible if the intersection of its area with
at least one output's logical rect is at least
`niri-frame-visible-threshold' of the rect's total area."
  (cl-destructuring-bind (wx wy ww wh) rect
    (let ((total-area (float (* ww wh))))
      (if (<= total-area 0)
          nil
        (catch 'visible
          (maphash
           (lambda (_name output)
             (when-let* ((logical (niri-rpc-output-logical output)))
               (let* ((ox (niri-rpc-logical-output-x logical))
                      (oy (niri-rpc-logical-output-y logical))
                      (ow (niri-rpc-logical-output-width logical))
                      (oh (niri-rpc-logical-output-height logical))
                      ;; Intersection of the window rect with this output
                      (ix (max wx ox))
                      (iy (max wy oy))
                      (ix2 (min (+ wx ww) (+ ox ow)))
                      (iy2 (min (+ wy wh) (+ oy oh)))
                      (iw (- ix2 ix))
                      (ih (- iy2 iy)))
                 (when (and (> iw 0) (> ih 0))
                   (when (>= (float (* iw ih))
                             (* total-area niri-frame-visible-threshold))
                     (throw 'visible t))))))
           niri-rpc--outputs-cache)
          nil)))))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; Advice for frame-visible-p
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

;; NOTE: `frame-visible-p' is a C primitive (subr), so it only supports
;; `:before', `:after', and `:around' advice.  `:filter-result' and
;; `:filter-args' are not available for primitives.  We use `:around'
;; advice, which gives us the original function and lets us filter the
;; return value after calling it.

(defun niri-frame-visible--advice (orig-fun &rest args)
  "Around advice for `frame-visible-p'.

ORIG-FUN is the original `frame-visible-p', ARGS is its argument
list (a single FRAME argument).

Calls the original function, then filters the result:
  - When the original returns nil, returns nil unchanged.
  - When the original returns non-nil, checks whether FRAME is
    actually visible on any niri output.  First checks if the
    window is visible in its column (i.e. not a hidden tab in a
    tabbed column).  Then checks if the window geometry is
    sufficiently visible (per `niri-frame-visible-threshold').
    If the geometry is unavailable (e.g. older niri without tile
    position info, niri connection lost), the original non-nil
    result is passed through unchanged.

All errors in the geometry check are caught and silently degrade
to the original `frame-visible-p' result.  This ensures that a
stale or missing niri connection never breaks Emacs display code
(which calls `frame-visible-p' frequently)."
  (let* ((frame (car args))
         (original-result (apply orig-fun args)))
    (if original-result
        (condition-case nil
            ;; Original says visible — check niri visibility.
            (if-let* ((niri-id (niri-frame-niri-id frame)))
                (let ((win (gethash niri-id niri-rpc--windows)))
                  ;; First check column visibility (tabbed columns).
                  (if (and win
                           (not (niri-rpc-window-layout-is-visible-in-column
                                 (niri-rpc-window-layout win))))
                      ;; Hidden tab in a tabbed column — not visible.
                      nil
                    ;; Now check geometry-based visibility.
                    (if-let* ((rect (niri-rpc-window-absolute-rect niri-id)))
                        (niri-frame-visible--rect-visible-p rect)
                      original-result)))
              ;; No niri-id — trust the original result.
              original-result)
          (error
           ;; niri-rpc connection lost or other error — degrade
           ;; gracefully to the original result.
           original-result))
      ;; Original says not visible — pass through.
      nil)))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; Minor mode
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

;;;###autoload
(define-minor-mode track-niri-frame-visibility-mode
  "Toggle niri-aware frame visibility tracking.

When enabled, `frame-visible-p' is advised to take the actual
niri window geometry into account.  A frame that is scrolled
off-screen or otherwise outside the viewport will be reported as
not visible, even when Emacs normally considers it visible.

The fraction of the frame that must be on-screen is controlled by
`niri-frame-visible-threshold' (default 0.5 = 50%).

This requires an active niri-rpc connection and frame tracking
enabled via `niri-frame-enable'.  When niri geometry information
is unavailable (e.g. older niri versions), `frame-visible-p'
behaves normally."
  :global t
  :group 'niri-frame-visible
  (if track-niri-frame-visibility-mode
      (advice-add 'frame-visible-p :around #'niri-frame-visible--advice)
    (advice-remove 'frame-visible-p #'niri-frame-visible--advice)))

(provide 'niri-frame-visible)
;;; niri-frame-visible.el ends here
