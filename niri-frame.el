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
;; The solution: each Emacs frame's Wayland window title permanently
;; ends with an invisible binary encoding of its `frame-id', using
;; zero-width characters:
;;
;;   ZWNJ (U+200C) = binary 0
;;   ZWJ  (U+200D) = binary 1
;;
;; These characters are invisible in all rendering contexts, so the
;; title looks normal to users.  Niri receives the full title and
;; reports it in window events; we decode the frame-id to reliably
;; identify which niri window belongs to which Emacs frame.
;;
;; Two cases for title management:
;;
;; 1. Frames WITHOUT an explicit name: the encoding is appended via
;;    `(:eval (niri-frame--id-suffix))' in `frame-title-format'.
;;
;; 2. Frames WITH an explicit name (set via `modify-frame-parameters'):
;;    advice intercepts the name change and also sets the `title'
;;    parameter with the encoding appended.  When the name is cleared,
;;    `title' is cleared so `frame-title-format' takes over again.
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

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; Zero-width encoding
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(defconst niri-frame--zw-0 (string #x200C)
  "Zero Width Non-Joiner, represents binary 0 in frame-id encoding.")

(defconst niri-frame--zw-1 (string #x200D)
  "Zero Width Joiner, represents binary 1 in frame-id encoding.")

(defun niri-frame--frame-id-encode (frame-id)
  "Encode FRAME-ID as a string of zero-width characters.
Binary digits: 0 -> ZWNJ, 1 -> ZWJ, most significant bit first."
  (let ((num frame-id)
        (bits nil))
    (if (zerop num)
        (setq bits (list ?0))
      (while (> num 0)
        (push (if (zerop (logand num 1)) ?0 ?1) bits)
        (setq num (ash num -1))))
    (apply #'concat
           (mapcar (lambda (c)
                     (if (eq c ?1) niri-frame--zw-1 niri-frame--zw-0))
                   bits))))

(defun niri-frame--frame-id-decode (title)
  "Extract frame-id from TITLE encoded with zero-width characters.
Scans backwards from the end of TITLE, collecting ZWJ/ZWNJ chars
until a non-zero-width character is hit.  Returns the decoded
integer, or nil if no encoding found."
  (when title
    (let ((bits nil)
          (chars (append title nil)))
      (catch 'done
        (dolist (c (reverse chars))
          (cond ((eq c #x200C) (push ?0 bits))
                ((eq c #x200D) (push ?1 bits))
                (t (throw 'done t)))))
      (when bits
        (string-to-number (concat bits) 2)))))

(defun niri-frame--id-suffix ()
  "Return the zero-width encoded frame-id suffix for the selected frame.
Intended for use with (:eval ...) in `frame-title-format'.
During redisplay, `gui_consider_frame_title' selects the target frame
before evaluating the format, so `frame-id' returns the correct value."
  (niri-frame--frame-id-encode (frame-id)))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; Internal state
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(defvar niri-frame--enabled nil
  "Non-nil when frame tracking is active.")

(defvar niri-frame--frame-to-niri-id (make-hash-table :test #'eq)
  "Hash table mapping Emacs frame -> niri window id.
This is the primary mapping used by `niri-frame-niri-id'.")

(defvar niri-frame--niri-id-to-frame (make-hash-table :test #'eql)
  "Hash table mapping niri window id -> Emacs frame.
This is the reverse mapping used by `niri-frame-get-frame'.")

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; frame-title-format management
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(defun niri-frame--strip-encoding (title)
  "Remove any zero-width encoding suffix from TITLE.
Scans backwards and strips all ZWJ/ZWNJ characters from the end."
  (if title
      (let* ((chars (append title nil))
             (len (length chars)))
        (while (and (> len 0)
                    (or (eq (nth (1- len) chars) #x200C)
                        (eq (nth (1- len) chars) #x200D)))
          (setq len (1- len)))
        (substring title 0 len))
    title))

(defun niri-frame--title-format-has-suffix-p ()
  "Return non-nil if `frame-title-format' already includes the
frame-id encoding suffix."
  (cl-some (lambda (elt)
             (equal elt '(:eval (niri-frame--id-suffix))))
           (if (listp frame-title-format)
               frame-title-format
             (list frame-title-format))))

(defun niri-frame--enable-title-suffix ()
  "Ensure the zero-width frame-id suffix is in `frame-title-format'.
Idempotent: does nothing if the suffix is already present."
  (unless (niri-frame--title-format-has-suffix-p)
    (setq frame-title-format
          `(,frame-title-format
            (:eval (niri-frame--id-suffix))))))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; modify-frame-parameters advice (explicit frame names)
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(defun niri-frame--after-modify-frame-params (frame alist)
  "After `modify-frame-parameters', ensure title includes frame-id.

When `name' is set (non-nil) and `title' is not also being set,
update `title' to include the zero-width encoded frame-id so that
frames with explicit names also carry the encoding in their Wayland
window title.

When `name' is cleared (nil), clear `title' so that
`frame-title-format' takes over again (it already includes the
encoding suffix)."
  (let ((name-entry (assq 'name alist))
        (title-entry (assq 'title alist)))
    (when name-entry
      (if (cdr name-entry)
          ;; Explicit name set: inject encoding via 'title if not
          ;; also being set explicitly.
          (unless title-entry
            (set-frame-parameter
             frame 'title
             (concat (niri-frame--strip-encoding (cdr name-entry))
                     (niri-frame--frame-id-encode (frame-id frame)))))
        ;; Name cleared: clear 'title so frame-title-format takes over,
        ;; unless 'title is also explicitly set in the same call.
        (unless title-entry
          (set-frame-parameter frame 'title nil))))))

(defun niri-frame--inject-title-suffix-on-frame (frame)
  "Ensure FRAME's Wayland title includes the frame-id encoding.
For frames with an explicit name: sets the `title' parameter to
name + zero-width encoded frame-id.
For frames without an explicit name: does nothing (the encoding
comes from `frame-title-format')."
  (when (frame-parameter frame 'explicit-name)
    (let* ((name (or (frame-parameter frame 'name) ""))
           (clean-name (niri-frame--strip-encoding name)))
      (set-frame-parameter
       frame 'title
       (concat clean-name
               (niri-frame--frame-id-encode (frame-id frame)))))))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; Frame creation / deletion hooks
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(defun niri-frame--connection-alive-p ()
  "Return non-nil if the niri event stream connection is alive."
  (and niri-rpc--async-process
       (eq (process-status niri-rpc--async-process) 'open)))

(defun niri-frame--on-frame-created (frame)
  "Called when a new FRAME is created.
Ensures the Wayland window title includes the frame-id encoding.

Even though `modify-frame-parameters' advice fires during
`make-frame', the GTK widget may not exist yet at that point,
making `x_set_title' a no-op.  By the time
`after-make-frame-functions' runs, the widget exists, so we
can reliably set the Wayland title.

If niri connection has died, disable tracking silently."
  (when niri-frame--enabled
    (if (niri-frame--connection-alive-p)
        (let* ((raw-name (or (frame-parameter frame 'name) ""))
               (clean-name (niri-frame--strip-encoding raw-name))
               (encoded (concat clean-name
                                (niri-frame--frame-id-encode (frame-id frame)))))
          ;; Set title to trigger x_set_title on the now-existing
          ;; GTK widget.  This sends the encoding to niri via Wayland.
          (set-frame-parameter frame 'title encoded)
          ;; Flush pending GDK events so niri sees the title
          (sit-for 0))
      ;; Connection lost — disable tracking.
      (lwarn 'niri-frame :warning
             "niri event stream lost; disabling frame tracking")
      (niri-frame-disable))))

(defun niri-frame--on-frame-deleted (frame)
  "Called when FRAME is deleted.
Cleans up any mappings involving this frame."
  (when niri-frame--enabled
    (let ((niri-id (gethash frame niri-frame--frame-to-niri-id)))
      (when niri-id
        (remhash niri-id niri-frame--niri-id-to-frame)
        (remhash frame niri-frame--frame-to-niri-id)))))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; Event stream processing: matching niri windows to Emacs frames
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(defun niri-frame--find-frame-by-title (title)
  "Find the Emacs frame whose frame-id matches the zero-width encoding in TITLE.
Returns the frame, or nil if no matching frame is found."
  (let ((id (niri-frame--frame-id-decode title)))
    (when id
      (cl-find-if (lambda (f) (and (frame-live-p f)
                                   (= (frame-id f) id)))
                  (frame-list)))))

(defun niri-frame--match-window (window)
  "Try to match a niri WINDOW to an Emacs frame.

If the window's PID matches our Emacs PID and its title contains
a zero-width encoded frame-id, establish the bidirectional mapping.
Returns the matched frame, or nil if no match."
  (let ((pid (niri-rpc-window-pid window))
        (title (niri-rpc-window-title window))
        (niri-id (niri-rpc-window-id window)))
    (when (and pid
               (= pid (emacs-pid))
               title)
      (let ((frame (niri-frame--find-frame-by-title title)))
        (when frame
          ;; Avoid duplicate mapping work
          (unless (eq (gethash frame niri-frame--frame-to-niri-id) niri-id)
            ;; Clean up any previous mapping for this frame
            (let ((old-id (gethash frame niri-frame--frame-to-niri-id)))
              (when old-id
                (remhash old-id niri-frame--niri-id-to-frame)))
            ;; Clean up any previous mapping for this niri id
            (let ((old-frame (gethash niri-id niri-frame--niri-id-to-frame)))
              (when (and old-frame (not (eq old-frame frame)))
                (remhash old-frame niri-frame--frame-to-niri-id)))
            ;; Establish bidirectional mapping
            (puthash frame niri-id niri-frame--frame-to-niri-id)
            (puthash niri-id frame niri-frame--niri-id-to-frame))
          frame)))))

(defun niri-frame--on-niri-event (event)
  "Process a niri event to detect and map Emacs frames.

Handles:
  `windows-changed'     — scan all windows for Emacs frames.
  `window-opened-or-changed' — check if the window matches an Emacs frame.
  `window-closed'       — clean up mapping if a tracked window is closed.

Guard: if frame tracking has been disabled (e.g. due to connection
loss), silently ignores the event."
  (when niri-frame--enabled
    (pcase (niri-rpc-event-type event)
      ('windows-changed
       (dolist (win (niri-rpc-event-windows event))
         (niri-frame--match-window win)))

      ('window-opened-or-changed
       (niri-frame--match-window (niri-rpc-event-window event)))

      ('window-closed
       (let ((niri-id (niri-rpc-event-window-id event)))
         (when-let* ((frame (gethash niri-id niri-frame--niri-id-to-frame)))
           (remhash niri-id niri-frame--niri-id-to-frame)
           (remhash frame niri-frame--frame-to-niri-id)))))))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; Public API
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

;;;###autoload
(defun niri-frame-enable ()
  "Enable frame-to-niri-window tracking.

Modifies `frame-title-format' to append an invisible zero-width
encoding of each frame's `frame-id' to its Wayland window title.
Registers niri event hooks that decode the frame-id from window
titles reported by niri, establishing a bidirectional mapping.

Also installs advice on `modify-frame-parameters' so that frames
with explicit names (which bypass `frame-title-format') also get
the encoding in their titles.

Requires that `niri-rpc-connect' has been called first."
  (interactive)
  (unless (and niri-rpc--async-process
               (eq (process-status niri-rpc--async-process) 'open))
    (error "niri-frame: niri-rpc not connected.  Call (niri-rpc-connect) first"))
  (when niri-frame--enabled
    (niri-frame-disable))

  (setq niri-frame--enabled t)

  ;; Reset internal state
  (clrhash niri-frame--frame-to-niri-id)
  (clrhash niri-frame--niri-id-to-frame)

  ;; 1. Add invisible frame-id suffix to frame-title-format
  (niri-frame--enable-title-suffix)

  ;; 2. Install advice for explicit frame names
  (unless (advice-member-p #'niri-frame--after-modify-frame-params
                           'modify-frame-parameters)
    (advice-add 'modify-frame-parameters :after
                #'niri-frame--after-modify-frame-params))

  ;; 3. Register hooks
  (add-hook 'after-make-frame-functions #'niri-frame--on-frame-created)
  (add-hook 'delete-frame-functions #'niri-frame--on-frame-deleted)
  (add-hook 'niri-rpc-event-hook #'niri-frame--on-niri-event)

  ;; 4. Force Wayland title update on ALL existing frames.
  ;;    Set title = effective-name + encoding for every frame.
  ;;    This triggers x_set_title on PGTK which pushes the encoded
  ;;    title to niri immediately.  Future name changes (buffer
  ;;    switches, etc.) update the Wayland title via x_set_name
  ;;    with frame-title-format which already includes the suffix.
  (dolist (frame (frame-list))
    (let* ((raw-name (or (frame-parameter frame 'name) ""))
           (clean-name (niri-frame--strip-encoding raw-name))
           (encoded (concat clean-name
                            (niri-frame--frame-id-encode (frame-id frame)))))
      (set-frame-parameter frame 'title encoded)))
  ;; Flush pending GDK/Wayland events so niri sees our title updates
  (sit-for 0)

  ;; 5. Scan existing niri windows for any that already match
  ;;    (covers the case where titles already had encoding, e.g. on re-enable)
  (dolist (win (niri-rpc-windows))
    (niri-frame--match-window win))

  (let ((mapped (hash-table-count niri-frame--frame-to-niri-id))
        (total (length (frame-list))))
    (message "niri-frame: enabled (%d/%d frame(s) mapped so far)"
             mapped total)))

;;;###autoload
(defun niri-frame-disable ()
  "Disable frame-to-niri-window tracking.

Removes the advice on `modify-frame-parameters' and clears the
`title' parameter on frames with explicit names so they return
to using `frame-title-format' (which still includes the encoding
suffix, but that's invisible and harmless)."
  (interactive)
  (setq niri-frame--enabled nil)

  ;; Remove hooks
  (remove-hook 'after-make-frame-functions #'niri-frame--on-frame-created)
  (remove-hook 'delete-frame-functions #'niri-frame--on-frame-deleted)
  (remove-hook 'niri-rpc-event-hook #'niri-frame--on-niri-event)

  ;; Remove advice
  (advice-remove 'modify-frame-parameters
                 #'niri-frame--after-modify-frame-params)

  ;; Clear title overrides on frames with explicit names
  ;; so frame-title-format takes over again.
  (dolist (frame (frame-list))
    (when (frame-parameter frame 'explicit-name)
      (set-frame-parameter frame 'title nil)))

  ;; Clear mappings
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
  "Return a list of live frames that have not yet been mapped to a niri window."
  (let ((result nil))
    (dolist (frame (frame-list))
      (unless (gethash frame niri-frame--frame-to-niri-id)
        (push frame result)))
    (nreverse result)))

(provide 'niri-frame)
;;; niri-frame.el ends here
