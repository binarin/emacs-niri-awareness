;;; niri-frame.el --- Map niri windows to Emacs frames -*- lexical-binding: t -*-

;; Copyright (C) 2025

;; Author: Emacs niri awareness
;; Keywords: niri, frames
;; Package-Requires: ((emacs "28.1") (niri-rpc "0"))

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; This package builds on niri-rpc.el to establish a bidirectional
;; mapping between niri windows and Emacs frames.
;;
;; The problem: niri reports windows by PID and title.  When multiple
;; Emacs frames share the same title, we cannot disambiguate them.
;;
;; The solution: when a new frame is created, we inject a unique tag
;; into its Wayland window title via the frame's `name' parameter.
;; When the corresponding niri WindowOpenedOrChanged event arrives,
;; we extract the tag, establish the mapping, and remove the tag
;; from the title.
;;
;; Usage:
;;
;;   (require 'niri-rpc)
;;   (require 'niri-frame)
;;   (niri-rpc-connect)
;;   (niri-frame-enable)  ; starts tracking frames
;;
;;   ;; Get the niri window id for the selected frame:
;;   (niri-frame-niri-id (selected-frame))
;;
;;   ;; Get the Emacs frame for a niri window id:
;;   (niri-frame-get-frame 42)
;;
;;   ;; List all tracked frames and their niri window ids:
;;   (niri-frame-frames)

;;; Code:

(require 'niri-rpc)
(require 'cl-lib)

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; Customization
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(defgroup niri-frame nil
  "Map niri windows to Emacs frames."
  :group 'niri-rpc)

(defcustom niri-frame-tag-prefix "[niri-frame-"
  "Prefix string for injecting into frame titles.
The full tag is this prefix followed by a monotonically
increasing counter and a closing bracket."
  :type 'string
  :group 'niri-frame)

(defcustom niri-frame-tag-suffix "]"
  "Suffix string closing a frame tag."
  :type 'string
  :group 'niri-frame)

(defcustom niri-frame-tag-regexp-pattern "\\[niri-frame-\\([0-9]+\\)\\]"
  "Regexp pattern matching a frame tag in a window title.
Group 1 must capture the counter value."
  :type 'regexp
  :group 'niri-frame)

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; Internal state
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(defvar niri-frame--enabled nil
  "Non-nil when frame tracking is active.")

(defvar niri-frame--counter 0
  "Monotonically increasing counter for frame tag generation.")

(defvar niri-frame--tag-to-frame (make-hash-table :test 'equal)
  "Hash table mapping tag string -> Emacs frame.
Used during the brief window between injecting a tag into a
frame's title and the corresponding niri event arriving.")

(defvar niri-frame--frame-to-niri-id (make-hash-table :test 'eq)
  "Hash table mapping Emacs frame -> niri window id.
This is the primary mapping used by `niri-frame-niri-id'.")

(defvar niri-frame--niri-id-to-frame (make-hash-table :test 'eql)
  "Hash table mapping niri window id -> Emacs frame.
This is the reverse mapping used by `niri-frame-get-frame'.")

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; Tag management
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(defun niri-frame--next-counter ()
  "Return the next counter value for a frame tag."
  (cl-incf niri-frame--counter))

(defun niri-frame--make-tag (counter)
  "Create a tag string for COUNTER."
  (concat niri-frame-tag-prefix
          (number-to-string counter)
          niri-frame-tag-suffix))

(defun niri-frame--title-has-tag-p (title)
  "Return non-nil if TITLE contains a niri-frame tag."
  (when title
    (string-match-p niri-frame-tag-regexp-pattern title)))

(defun niri-frame--extract-tag (title)
  "Extract the full tag substring from TITLE, or nil if none."
  (when title
    (when (string-match niri-frame-tag-regexp-pattern title)
      (match-string 0 title))))

(defun niri-frame--extract-counter (title)
  "Extract the counter number from a tagged TITLE, or nil if none."
  (when title
    (when (string-match niri-frame-tag-regexp-pattern title)
      (string-to-number (match-string 1 title)))))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; Frame title injection / removal
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(defun niri-frame--inject-tag (frame tag)
  "Inject TAG into FRAME's window title.

Sets the frame's `name' parameter to include TAG.  The tag is also
stored in the frame parameter `niri-frame-tag' for lookup.

FRAME must be a live frame."
  ;; Store the tag on the frame itself
  (set-frame-parameter frame 'niri-frame-tag tag)
  ;; Save the current effective title so we can restore it after mapping.
  ;; On PGTK, (frame-parameter frame 'name) always returns the effective
  ;; Wayland window title — whether it was explicitly set or computed from
  ;; frame-title-format.  Saving and restoring this value means custom
  ;; names survive intact, and computed titles are restored as-is.
  (set-frame-parameter frame 'niri-frame-orig-name
                       (frame-parameter frame 'name))
  ;; Save whether the name was explicitly set by the user, so we can
  ;; restore dynamic title computation for non-explicit names.
  (set-frame-parameter frame 'niri-frame-explicit-name-p
                       (frame-parameter frame 'explicit-name))
  ;; Compute a base title by reading the current computed title
  (let* ((base-title (or (frame-parameter frame 'title)
                         (with-selected-frame frame
                           (format-mode-line frame-title-format))))
         (tagged-title (concat (string-trim-right base-title)
                               " " tag)))
    (modify-frame-parameters frame `((name . ,tagged-title))))
  ;; Store in the lookup table
  (puthash tag frame niri-frame--tag-to-frame))

(defun niri-frame--remove-tag (frame)
  "Remove the injected tag from FRAME's window title.

Restores the frame's original effective `name' (saved before
tag injection).  Also cleans up internal state."
  (let ((tag (frame-parameter frame 'niri-frame-tag)))
    (when tag
      (remhash tag niri-frame--tag-to-frame)
      (set-frame-parameter frame 'niri-frame-tag nil)))
  ;; Restore the original effective title.
  ;; If the name was explicitly set before tag injection, restore it.
  ;; If it was dynamically computed (from frame-title-format), reset
  ;; it so it recomputes — otherwise the title freezes at whatever
  ;; was showing at tag injection time.
  (let ((orig-name (frame-parameter frame 'niri-frame-orig-name))
        (was-explicit (frame-parameter frame 'niri-frame-explicit-name-p)))
    (if was-explicit
        (set-frame-parameter frame 'name orig-name)
      (set-frame-parameter frame 'name nil))
    (set-frame-parameter frame 'niri-frame-orig-name nil)
    (set-frame-parameter frame 'niri-frame-explicit-name-p nil)))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; Frame creation / deletion hooks
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(defun niri-frame--connection-alive-p ()
  "Return non-nil if the niri event stream connection is alive."
  (and niri-rpc--async-process
       (eq (process-status niri-rpc--async-process) 'open)))

(defun niri-frame--on-frame-created (frame)
  "Called when a new FRAME is created.
Injects a unique tag into the frame's title.

If the niri event stream has died, disables frame tracking silently
(rather than leaving stale tags in frame titles)."
  (when niri-frame--enabled
    (if (niri-frame--connection-alive-p)
        (let* ((counter (niri-frame--next-counter))
               (tag (niri-frame--make-tag counter)))
          (niri-frame--inject-tag frame tag))
      ;; Connection lost — disable tracking so we don't leave
      ;; tags stuck in frame titles.  niri-frame-disable cleans
      ;; up all state (hooks, hash tables, existing frame titles).
      (lwarn 'niri-frame :warning
             "niri event stream lost; disabling frame tracking")
      (niri-frame-disable))))

(defun niri-frame--on-frame-deleted (frame)
  "Called when FRAME is deleted.
Cleans up any mappings involving this frame.

Because the frame itself is going away, we don't need to restore
the original name — we just clear our internal bookkeeping."
  (when niri-frame--enabled
    (let ((tag (frame-parameter frame 'niri-frame-tag)))
      (when tag
        (remhash tag niri-frame--tag-to-frame)))
    (let ((niri-id (gethash frame niri-frame--frame-to-niri-id)))
      (when niri-id
        (remhash niri-id niri-frame--niri-id-to-frame)
        (remhash frame niri-frame--frame-to-niri-id)))))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; Event stream processing
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(defun niri-frame--match-window-to-frame (window)
  "Try to match WINDOW (a niri-rpc-window struct) to an Emacs frame.

If the window's PID matches our Emacs PID and its title contains
a known tag, establish the bidirectional mapping, remove the tag
from the frame's title, and return the frame.

Returns the matched frame, or nil if no match."
  (let ((pid (niri-rpc-window-pid window))
        (title (niri-rpc-window-title window))
        (niri-id (niri-rpc-window-id window)))
    (when (and pid
               (= pid (emacs-pid))
               title
               (niri-frame--title-has-tag-p title))
      (let* ((tag (niri-frame--extract-tag title))
             (frame (gethash tag niri-frame--tag-to-frame)))
        (when (and frame (frame-live-p frame))
          ;; Establish bidirectional mapping
          (puthash frame niri-id niri-frame--frame-to-niri-id)
          (puthash niri-id frame niri-frame--niri-id-to-frame)
          ;; Remove the tag from the frame title
          (niri-frame--remove-tag frame)
          frame)))))

(defun niri-frame--on-niri-event (event)
  "Process a niri event to detect and map Emacs frames.

Handles:
  `windows-changed'     — scan all windows for tagged Emacs frames.
  `window-opened-or-changed' — check if the window matches a tagged frame.
  `window-closed'       — clean up mapping if a tracked window is closed.

Guard: if frame tracking has been disabled (e.g. due to connection
loss), silently ignores the event."
  (when niri-frame--enabled
    (pcase (niri-rpc-event-type event)
      ('windows-changed
       ;; Scan all current windows for tagged ones
       (dolist (win (niri-rpc-event-windows event))
         (niri-frame--match-window-to-frame win)))

      ('window-opened-or-changed
       (let ((win (niri-rpc-event-window event)))
         (niri-frame--match-window-to-frame win)))

      ('window-closed
       (let ((niri-id (niri-rpc-event-window-id event)))
         (when-let* ((frame (gethash niri-id niri-frame--niri-id-to-frame)))
           (remhash niri-id niri-frame--niri-id-to-frame)
           (remhash frame niri-frame--frame-to-niri-id)))))))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; Tagging existing frames
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(defun niri-frame--tag-existing-frames ()
  "Inject tags into all existing Emacs frames that don't have one.

Changing frame titles will cause niri to emit WindowOpenedOrChanged
events, which our event hook will catch asynchronously to establish
the window↔frame mappings."
  (dolist (frame (frame-list))
    (unless (or (frame-parameter frame 'niri-frame-tag)
                (gethash frame niri-frame--frame-to-niri-id))
      (let* ((counter (niri-frame--next-counter))
             (tag (niri-frame--make-tag counter)))
        (niri-frame--inject-tag frame tag)))))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; Public API
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

;;;###autoload
(defun niri-frame-enable ()
  "Enable frame-to-niri-window tracking.

Adds hooks for frame creation/deletion and niri events.
Tags all existing frames with unique identifiers and watches for
the corresponding WindowOpenedOrChanged events from niri.

After the events arrive, bidirectional mappings are established
and the frame titles are restored to normal.

Requires that `niri-rpc-connect' has been called first."
  (interactive)
  (unless (and niri-rpc--async-process
               (eq (process-status niri-rpc--async-process) 'open))
    (error "niri-frame: niri-rpc not connected.  Call (niri-rpc-connect) first"))
  (when niri-frame--enabled
    (niri-frame-disable))

  (setq niri-frame--enabled t)

  ;; Reset internal state
  (setq niri-frame--counter 0)
  (clrhash niri-frame--tag-to-frame)
  (clrhash niri-frame--frame-to-niri-id)
  (clrhash niri-frame--niri-id-to-frame)

  ;; Register hooks
  (add-hook 'after-make-frame-functions #'niri-frame--on-frame-created)
  (add-hook 'delete-frame-functions #'niri-frame--on-frame-deleted)
  (add-hook 'niri-rpc-event-hook #'niri-frame--on-niri-event)

  ;; Tag existing frames and try to match them
  (niri-frame--tag-existing-frames)

  (message "niri-frame: enabled (%d frame(s) tagged)"
           (hash-table-count niri-frame--tag-to-frame)))

;;;###autoload
(defun niri-frame-disable ()
  "Disable frame-to-niri-window tracking.

Removes hooks and restores frame titles to normal."
  (interactive)
  (setq niri-frame--enabled nil)

  ;; Remove hooks
  (remove-hook 'after-make-frame-functions #'niri-frame--on-frame-created)
  (remove-hook 'delete-frame-functions #'niri-frame--on-frame-deleted)
  (remove-hook 'niri-rpc-event-hook #'niri-frame--on-niri-event)

  ;; Restore all tagged frame titles
  (dolist (frame (frame-list))
    (when (frame-parameter frame 'niri-frame-tag)
      (niri-frame--remove-tag frame)))

  ;; Clear state
  (clrhash niri-frame--tag-to-frame)
  (clrhash niri-frame--frame-to-niri-id)
  (clrhash niri-frame--niri-id-to-frame)

  (message "niri-frame: disabled"))

;;;###autoload
(defun niri-frame-niri-id (frame)
  "Return the niri window id for Emacs FRAME, or nil if not yet mapped.

FRAME defaults to the selected frame."
  (interactive)
  (gethash (or frame (selected-frame)) niri-frame--frame-to-niri-id))

;;;###autoload
(defun niri-frame-get-frame (niri-window-id)
  "Return the Emacs frame for NIRI-WINDOW-ID, or nil if not mapped."
  (gethash niri-window-id niri-frame--niri-id-to-frame))

;;;###autoload
(defun niri-frame-frames ()
  "Return an alist of (frame . niri-window-id) for all mapped frames."
  (let ((result nil))
    (maphash
     (lambda (frame niri-id)
       (push (cons frame niri-id) result))
     niri-frame--frame-to-niri-id)
    (nreverse result)))

;;;###autoload
(defun niri-frame-pending-frames ()
  "Return a list of frames waiting for niri event matching.
These frames have been tagged but their corresponding niri window
has not yet been detected."
  (let ((result nil))
    (maphash
     (lambda (_tag frame)
       (push frame result))
     niri-frame--tag-to-frame)
    (nreverse result)))

(provide 'niri-frame)
;;; niri-frame.el ends here
