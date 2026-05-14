;;; niri-rpc.el --- Emacs IPC client for the niri Wayland compositor -*- lexical-binding: t -*-

;; Copyright (C) 2025

;; Author: Emacs niri awareness
;; Keywords: niri, wayland, ipc
;; Package-Requires: ((emacs "28.1"))

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; This package provides an IPC client for the niri Wayland compositor.
;;
;; It connects to the niri socket (from $NIRI_SOCKET) and opens two
;; connections:
;;
;; 1. An event-stream socket (async) that continuously receives compositor
;;    events and maintains an aggregated client-side state (workspaces,
;;    windows, keyboard layouts, etc.).
;;
;; 2. A command socket (sync) for sending individual requests and receiving
;;    replies.
;;
;; Usage:
;;
;;   (niri-rpc-connect)
;;   (niri-rpc-workspaces)      ; => list of niri-rpc-workspace structs
;;   (niri-rpc-window-by-id 42) ; => niri-rpc-window struct or nil
;;   (niri-rpc-focused-window)  ; => niri-rpc-window struct or nil
;;
;;   (add-hook 'niri-rpc-event-hook
;;     (lambda (event)
;;       (pcase (niri-rpc-event-type event)
;;         ('workspace-activated
;;          (message "Activated workspace %d" (niri-rpc-event-workspace-id event))))))
;;
;;   (niri-rpc-command '(:Action (:FocusColumnLeft)))

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)  ;; for string-trim

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; Customization
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(defgroup niri-rpc nil
  "IPC client for the niri Wayland compositor."
  :group 'comm)

(defcustom niri-rpc-timeout 5.0
  "Timeout in seconds for sync IPC commands."
  :type 'float
  :group 'niri-rpc)

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; Data structures
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(cl-defstruct niri-rpc-timestamp
  "A moment in time."
  secs nanos)

(cl-defstruct niri-rpc-window-layout
  "Position- and size-related properties of a window.

All sizes and positions are in logical pixels.

TILE-SIZE is a cons (width . height).  WINDOW-SIZE is a cons
(width . height).  POS-IN-SCROLLING-LAYOUT is a cons
(column-index . tile-index) or nil.  TILE-POS-IN-WORKSPACE-VIEW
is a cons (x . y) or nil.  WINDOW-OFFSET-IN-TILE is a cons
(x . y)."
  pos-in-scrolling-layout
  tile-size
  window-size
  tile-pos-in-workspace-view
  window-offset-in-tile)

(cl-defstruct niri-rpc-window
  "A toplevel window managed by niri."
  id title app-id pid workspace-id is-focused is-floating is-urgent
  layout focus-timestamp)

(cl-defstruct niri-rpc-workspace
  "A workspace in niri."
  id idx name output is-urgent is-active is-focused active-window-id)

(cl-defstruct niri-rpc-keyboard-layouts
  "Configured keyboard layouts."
  names current-idx)

(cl-defstruct niri-rpc-mode
  "An output display mode."
  width height refresh-rate is-preferred)

(cl-defstruct niri-rpc-logical-output
  "Logical output in the compositor's coordinate space."
  x y width height scale transform)

(cl-defstruct niri-rpc-output
  "A connected output."
  name make model serial physical-size modes current-mode-index
  is-custom-mode vrr-supported vrr-enabled logical)

(cl-defstruct niri-rpc-layer-surface
  "A layer-shell surface."
  namespace output layer keyboard-interactivity)

(cl-defstruct niri-rpc-cast
  "A screencast."
  stream-id session-id kind target is-dynamic-target is-active pid pw-node-id)

(cl-defstruct niri-rpc-event
  "An event from the niri compositor event stream.

TYPE is a symbol identifying the event kind.  Depending on the
type, specific fields will be populated.

Type symbols and their relevant fields:
  `workspaces-changed'             -> workspaces
  `workspace-urgency-changed'      -> workspace-id, urgent-p
  `workspace-activated'            -> workspace-id, focused-p
  `workspace-active-window-changed'-> workspace-id, active-window-id
  `windows-changed'                -> windows
  `window-opened-or-changed'       -> window
  `window-closed'                  -> window-id
  `window-focus-changed'           -> window-id
  `window-focus-timestamp-changed' -> window-id, focus-timestamp
  `window-urgency-changed'         -> window-id, urgent-p
  `window-layouts-changed'         -> layout-changes
  `keyboard-layouts-changed'       -> keyboard-layouts
  `keyboard-layout-switched'       -> layout-idx
  `overview-opened-or-closed'      -> is-open
  `config-loaded'                  -> config-failed-p
  `screenshot-captured'            -> screenshot-path
  `casts-changed'                  -> casts
  `cast-started-or-changed'        -> cast
  `cast-stopped'                   -> stream-id"
  type
  ;; fields for specific event types
  workspaces          ; list of niri-rpc-workspace
  workspace-id        ; u64
  urgent-p            ; boolean
  focused-p           ; boolean
  active-window-id    ; u64 or nil
  windows             ; list of niri-rpc-window
  window-id           ; u64
  window              ; niri-rpc-window
  focus-timestamp     ; niri-rpc-timestamp
  layout-changes      ; alist of (id . niri-rpc-window-layout)
  keyboard-layouts    ; niri-rpc-keyboard-layouts
  layout-idx          ; u8
  is-open             ; boolean
  config-failed-p     ; boolean
  screenshot-path     ; string or nil
  casts               ; list of niri-rpc-cast
  cast                ; niri-rpc-cast
  stream-id           ; u64
  )

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; Internal state
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(defvar niri-rpc--socket-path nil
  "Path to the niri IPC socket.")

(defvar niri-rpc--async-process nil
  "Network process for the niri event stream (async mode).")

(defvar niri-rpc--async-line-buffer ""
  "Accumulator for incomplete lines from the event stream.")

(defvar niri-rpc--workspaces (make-hash-table :test 'eql)
  "Hash table mapping workspace id -> niri-rpc-workspace struct.")

(defvar niri-rpc--windows (make-hash-table :test 'eql)
  "Hash table mapping window id -> niri-rpc-window struct.")

(defvar niri-rpc--keyboard-layouts nil
  "Current niri-rpc-keyboard-layouts or nil if not yet received.")

(defvar niri-rpc--overview-is-open nil
  "Boolean: whether the niri overview is open.")

(defvar niri-rpc--config-failed nil
  "Boolean: whether the last config load attempt failed.")

(defvar niri-rpc--casts (make-hash-table :test 'eql)
  "Hash table mapping stream-id -> niri-rpc-cast struct.")

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; JSON parsing helpers
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(defun niri-rpc--json-read (string)
  "Parse STRING as JSON, returning an alist with symbol keys.
JSON null becomes `:json-null', JSON false becomes `:json-false'."
  (json-parse-string string
                     :object-type 'alist
                     :null-object :json-null
                     :false-object :json-false))

(defun niri-rpc--json-false-p (val)
  "Return non-nil if VAL is JSON false."
  (eq val :json-false))

(defun niri-rpc--json-null-p (val)
  "Return non-nil if VAL is JSON null."
  (eq val :json-null))

(defsubst niri-rpc--maybe-opt (val)
  "Convert JSON false/null to nil, otherwise return VAL."
  (if (or (eq val :json-false) (eq val :json-null))
      nil
    val))

(defun niri-rpc--alist-to-plist (alist)
  "Convert ALIST to a plist with keyword keys."
  (let (plist)
    (dolist (pair alist)
      (push (cons (intern (concat ":" (symbol-name (car pair)))) (cdr pair)) plist))
    (nreverse plist)))

(defun niri-rpc--parse-timestamp (alist)
  "Parse a timestamp alist into a niri-rpc-timestamp struct."
  (when (and alist (not (eq alist :json-null)))
    (make-niri-rpc-timestamp
     :secs (alist-get 'secs alist)
     :nanos (alist-get 'nanos alist))))

(defun niri-rpc--parse-window-layout (alist)
  "Parse a window layout alist into a niri-rpc-window-layout struct."
  (when (and alist (not (eq alist :json-null)))
    (make-niri-rpc-window-layout
     :pos-in-scrolling-layout
     (let ((pos (alist-get 'pos_in_scrolling_layout alist)))
       (when (and pos (not (eq pos :json-null)))
         (cons (elt pos 0) (elt pos 1))))
     :tile-size
     (let ((v (alist-get 'tile_size alist)))
       (cons (elt v 0) (elt v 1)))
     :window-size
     (let ((v (alist-get 'window_size alist)))
       (cons (elt v 0) (elt v 1)))
     :tile-pos-in-workspace-view
     (let ((pos (alist-get 'tile_pos_in_workspace_view alist)))
       (when (and pos (not (eq pos :json-null)))
         (cons (elt pos 0) (elt pos 1))))
     :window-offset-in-tile
     (let ((v (alist-get 'window_offset_in_tile alist)))
       (cons (elt v 0) (elt v 1))))))

(defun niri-rpc--parse-window (alist)
  "Parse a window alist into a niri-rpc-window struct."
  (when (and alist (not (eq alist :json-null)))
    (make-niri-rpc-window
     :id (alist-get 'id alist)
     :title (niri-rpc--maybe-opt (alist-get 'title alist))
     :app-id (niri-rpc--maybe-opt (alist-get 'app_id alist))
     :pid (niri-rpc--maybe-opt (alist-get 'pid alist))
     :workspace-id (niri-rpc--maybe-opt (alist-get 'workspace_id alist))
     :is-focused (not (niri-rpc--json-false-p (alist-get 'is_focused alist)))
     :is-floating (not (niri-rpc--json-false-p (alist-get 'is_floating alist)))
     :is-urgent (not (niri-rpc--json-false-p (alist-get 'is_urgent alist)))
     :layout (niri-rpc--parse-window-layout (alist-get 'layout alist))
     :focus-timestamp (niri-rpc--parse-timestamp (alist-get 'focus_timestamp alist)))))

(defun niri-rpc--parse-workspace (alist)
  "Parse a workspace alist into a niri-rpc-workspace struct."
  (when (and alist (not (eq alist :json-null)))
    (make-niri-rpc-workspace
     :id (alist-get 'id alist)
     :idx (alist-get 'idx alist)
     :name (niri-rpc--maybe-opt (alist-get 'name alist))
     :output (niri-rpc--maybe-opt (alist-get 'output alist))
     :is-urgent (not (niri-rpc--json-false-p (alist-get 'is_urgent alist)))
     :is-active (not (niri-rpc--json-false-p (alist-get 'is_active alist)))
     :is-focused (not (niri-rpc--json-false-p (alist-get 'is_focused alist)))
     :active-window-id (niri-rpc--maybe-opt (alist-get 'active_window_id alist)))))

(defun niri-rpc--parse-keyboard-layouts (alist)
  "Parse keyboard layouts alist into a niri-rpc-keyboard-layouts struct."
  (when (and alist (not (eq alist :json-null)))
    (make-niri-rpc-keyboard-layouts
     :names (mapcar #'identity (alist-get 'names alist))
     :current-idx (alist-get 'current_idx alist))))

(defun niri-rpc--parse-mode (alist)
  "Parse a mode alist into a niri-rpc-mode struct."
  (when (and alist (not (eq alist :json-null)))
    (make-niri-rpc-mode
     :width (alist-get 'width alist)
     :height (alist-get 'height alist)
     :refresh-rate (alist-get 'refresh_rate alist)
     :is-preferred (not (niri-rpc--json-false-p (alist-get 'is_preferred alist))))))

(defun niri-rpc--parse-logical-output (alist)
  "Parse logical output alist into a niri-rpc-logical-output struct."
  (when (and alist (not (eq alist :json-null)))
    (make-niri-rpc-logical-output
     :x (alist-get 'x alist)
     :y (alist-get 'y alist)
     :width (alist-get 'width alist)
     :height (alist-get 'height alist)
     :scale (alist-get 'scale alist)
     :transform (alist-get 'transform alist))))

(defun niri-rpc--parse-output (alist)
  "Parse an output alist into a niri-rpc-output struct."
  (when (and alist (not (eq alist :json-null)))
    (make-niri-rpc-output
     :name (alist-get 'name alist)
     :make (alist-get 'make alist)
     :model (alist-get 'model alist)
     :serial (niri-rpc--maybe-opt (alist-get 'serial alist))
     :physical-size
     (let ((ps (alist-get 'physical_size alist)))
       (when (and ps (not (eq ps :json-null)))
         (cons (elt ps 0) (elt ps 1))))
     :modes (mapcar #'niri-rpc--parse-mode
                    (append (alist-get 'modes alist) nil))
     :current-mode-index (niri-rpc--maybe-opt (alist-get 'current_mode alist))
     :is-custom-mode (not (niri-rpc--json-false-p (alist-get 'is_custom_mode alist)))
     :vrr-supported (not (niri-rpc--json-false-p (alist-get 'vrr_supported alist)))
     :vrr-enabled (not (niri-rpc--json-false-p (alist-get 'vrr_enabled alist)))
     :logical (niri-rpc--parse-logical-output (alist-get 'logical alist)))))

(defun niri-rpc--parse-layer-surface (alist)
  "Parse a layer-surface alist into a niri-rpc-layer-surface struct."
  (when (and alist (not (eq alist :json-null)))
    (make-niri-rpc-layer-surface
     :namespace (alist-get 'namespace alist)
     :output (alist-get 'output alist)
     :layer (alist-get 'layer alist)
     :keyboard-interactivity (alist-get 'keyboard_interactivity alist))))

(defun niri-rpc--parse-cast (alist)
  "Parse a cast alist into a niri-rpc-cast struct."
  (when (and alist (not (eq alist :json-null)))
    (make-niri-rpc-cast
     :stream-id (alist-get 'stream_id alist)
     :session-id (alist-get 'session_id alist)
     :kind (alist-get 'kind alist)
     :target (alist-get 'target alist)
     :is-dynamic-target (not (niri-rpc--json-false-p (alist-get 'is_dynamic_target alist)))
     :is-active (not (niri-rpc--json-false-p (alist-get 'is_active alist)))
     :pid (niri-rpc--maybe-opt (alist-get 'pid alist))
     :pw-node-id (niri-rpc--maybe-opt (alist-get 'pw_node_id alist)))))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; Event stream: process filter
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(defun niri-rpc--handle-event-line (line)
  "Parse a single JSON event LINE and update internal state.
Runs `niri-rpc-event-hook' after state is updated."
  (let* ((alist (niri-rpc--json-read line))
         (event (niri-rpc--apply-event alist)))
    (when event
      (run-hook-with-args 'niri-rpc-event-hook event))))

(defun niri-rpc--async-filter (proc string)
  "Process filter for the event stream socket.
Accumulates incomplete data in `niri-rpc--async-line-buffer' and
processes each complete newline-delimited JSON line."
  (setq niri-rpc--async-line-buffer
        (concat niri-rpc--async-line-buffer string))
  (while (string-match "\n" niri-rpc--async-line-buffer)
    (let* ((pos (match-beginning 0))
           (line (substring niri-rpc--async-line-buffer 0 pos)))
      (setq niri-rpc--async-line-buffer
            (substring niri-rpc--async-line-buffer (1+ pos)))
      (when (> (length line) 0)
        (niri-rpc--handle-event-line line)))))

(defun niri-rpc--async-sentinel (proc event)
  "Sentinel for the event stream process."
  (when (memq (process-status proc) '(exit closed failed))
    (setq niri-rpc--async-process nil)))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; State update (mirrors the Rust EventStreamState::apply)
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(defun niri-rpc--apply-event (alist)
  "Apply a parsed event ALIST to the internal state and return an event struct.
State is updated BEFORE the event struct is returned, so hooks
running on the event will see current state via accessors.

Returns nil if the event was not recognized."
  (let* ((first (car alist))
         (type (car first))
         (data (cdr first)))
    (pcase type
      ('WorkspacesChanged
       (niri-rpc--apply-workspaces-changed (alist-get 'workspaces data))
       (make-niri-rpc-event
        :type 'workspaces-changed
        :workspaces (niri-rpc--hash-values niri-rpc--workspaces)))

      ('WorkspaceUrgencyChanged
       (niri-rpc--apply-workspace-urgency-changed
        (alist-get 'id data)
        (not (niri-rpc--json-false-p (alist-get 'urgent data))))
       (make-niri-rpc-event
        :type 'workspace-urgency-changed
        :workspace-id (alist-get 'id data)
        :urgent-p (not (niri-rpc--json-false-p (alist-get 'urgent data)))))

      ('WorkspaceActivated
       (niri-rpc--apply-workspace-activated
        (alist-get 'id data)
        (not (niri-rpc--json-false-p (alist-get 'focused data))))
       (make-niri-rpc-event
        :type 'workspace-activated
        :workspace-id (alist-get 'id data)
        :focused-p (not (niri-rpc--json-false-p (alist-get 'focused data)))))

      ('WorkspaceActiveWindowChanged
       (niri-rpc--apply-workspace-active-window-changed
        (alist-get 'workspace_id data)
        (niri-rpc--maybe-opt (alist-get 'active_window_id data)))
       (make-niri-rpc-event
        :type 'workspace-active-window-changed
        :workspace-id (alist-get 'workspace_id data)
        :active-window-id (niri-rpc--maybe-opt (alist-get 'active_window_id data))))

      ('WindowsChanged
       (niri-rpc--apply-windows-changed (alist-get 'windows data))
       (make-niri-rpc-event
        :type 'windows-changed
        :windows (niri-rpc--hash-values niri-rpc--windows)))

      ('WindowOpenedOrChanged
       (let ((win (niri-rpc--parse-window (alist-get 'window data))))
         (niri-rpc--apply-window-opened-or-changed win)
         (make-niri-rpc-event
          :type 'window-opened-or-changed
          :window win)))

      ('WindowClosed
       (niri-rpc--apply-window-closed (alist-get 'id data))
       (make-niri-rpc-event
        :type 'window-closed
        :window-id (alist-get 'id data)))

      ('WindowFocusChanged
       (niri-rpc--apply-window-focus-changed
        (niri-rpc--maybe-opt (alist-get 'id data)))
       (make-niri-rpc-event
        :type 'window-focus-changed
        :window-id (niri-rpc--maybe-opt (alist-get 'id data))))

      ('WindowFocusTimestampChanged
       (let ((ts (niri-rpc--parse-timestamp (alist-get 'focus_timestamp data))))
         (niri-rpc--apply-window-focus-timestamp-changed
          (alist-get 'id data) ts)
         (make-niri-rpc-event
          :type 'window-focus-timestamp-changed
          :window-id (alist-get 'id data)
          :focus-timestamp ts)))

      ('WindowUrgencyChanged
       (niri-rpc--apply-window-urgency-changed
        (alist-get 'id data)
        (not (niri-rpc--json-false-p (alist-get 'urgent data))))
       (make-niri-rpc-event
        :type 'window-urgency-changed
        :window-id (alist-get 'id data)
        :urgent-p (not (niri-rpc--json-false-p (alist-get 'urgent data)))))

      ('WindowLayoutsChanged
       (let ((changes (niri-rpc--parse-layout-changes (alist-get 'changes data))))
         (niri-rpc--apply-window-layouts-changed changes)
         (make-niri-rpc-event
          :type 'window-layouts-changed
          :layout-changes changes)))

      ('KeyboardLayoutsChanged
       (let ((kb (niri-rpc--parse-keyboard-layouts (alist-get 'keyboard_layouts data))))
         (niri-rpc--apply-keyboard-layouts-changed kb)
         (make-niri-rpc-event
          :type 'keyboard-layouts-changed
          :keyboard-layouts kb)))

      ('KeyboardLayoutSwitched
       (niri-rpc--apply-keyboard-layout-switched (alist-get 'idx data))
       (make-niri-rpc-event
        :type 'keyboard-layout-switched
        :layout-idx (alist-get 'idx data)))

      ('OverviewOpenedOrClosed
       (niri-rpc--apply-overview-opened-or-closed
        (not (niri-rpc--json-false-p (alist-get 'is_open data))))
       (make-niri-rpc-event
        :type 'overview-opened-or-closed
        :is-open (not (niri-rpc--json-false-p (alist-get 'is_open data)))))

      ('ConfigLoaded
       (niri-rpc--apply-config-loaded
        (not (niri-rpc--json-false-p (alist-get 'failed data))))
       (make-niri-rpc-event
        :type 'config-loaded
        :config-failed-p (not (niri-rpc--json-false-p (alist-get 'failed data)))))

      ('ScreenshotCaptured
       (make-niri-rpc-event
        :type 'screenshot-captured
        :screenshot-path (niri-rpc--maybe-opt (alist-get 'path data))))

      ('CastsChanged
       (niri-rpc--apply-casts-changed (alist-get 'casts data))
       (make-niri-rpc-event
        :type 'casts-changed
        :casts (niri-rpc--hash-values niri-rpc--casts)))

      ('CastStartedOrChanged
       (let ((cast (niri-rpc--parse-cast (alist-get 'cast data))))
         (niri-rpc--apply-cast-started-or-changed cast)
         (make-niri-rpc-event
          :type 'cast-started-or-changed
          :cast cast)))

      ('CastStopped
       (niri-rpc--apply-cast-stopped (alist-get 'stream_id data))
       (make-niri-rpc-event
        :type 'cast-stopped
        :stream-id (alist-get 'stream_id data)))

      (_ nil))))

;; ── Workspace state updates ─────────────────────────────────────────────

(defun niri-rpc--apply-workspaces-changed (workspaces)
  "Replace all workspaces with WORKSPACES (list of alists)."
  (clrhash niri-rpc--workspaces)
  (dolist (ws-alist (append workspaces nil))
    (let ((ws (niri-rpc--parse-workspace ws-alist)))
      (puthash (niri-rpc-workspace-id ws) ws niri-rpc--workspaces))))

(defun niri-rpc--apply-workspace-urgency-changed (id urgent)
  "Update urgency for workspace ID to URGENT."
  (let ((ws (gethash id niri-rpc--workspaces)))
    (when ws
      (setf (niri-rpc-workspace-is-urgent ws) urgent))))

(defun niri-rpc--apply-workspace-activated (id focused)
  "Mark workspace ID as active.  If FOCUSED, mark it as focused too."
  (let ((ws (gethash id niri-rpc--workspaces)))
    (unless ws
      (error "niri-rpc: activated workspace %d missing from map" id))
    (let ((output (niri-rpc-workspace-output ws)))
      (maphash
       (lambda (_wid w)
         (let ((got-activated (= (niri-rpc-workspace-id w) id)))
           (when (equal (niri-rpc-workspace-output w) output)
             (setf (niri-rpc-workspace-is-active w) got-activated))
           (when focused
             (setf (niri-rpc-workspace-is-focused w) got-activated))))
       niri-rpc--workspaces))))

(defun niri-rpc--apply-workspace-active-window-changed (workspace-id active-window-id)
  "Update active window for WORKSPACE-ID to ACTIVE-WINDOW-ID."
  (let ((ws (gethash workspace-id niri-rpc--workspaces)))
    (unless ws
      (error "niri-rpc: changed workspace %d missing from map" workspace-id))
    (setf (niri-rpc-workspace-active-window-id ws) active-window-id)))

;; ── Window state updates ────────────────────────────────────────────────

(defun niri-rpc--apply-windows-changed (windows)
  "Replace all windows with WINDOWS (list of alists)."
  (clrhash niri-rpc--windows)
  (dolist (win-alist (append windows nil))
    (let ((win (niri-rpc--parse-window win-alist)))
      (puthash (niri-rpc-window-id win) win niri-rpc--windows))))

(defun niri-rpc--apply-window-opened-or-changed (win)
  "Insert or update WIN in the windows map.
If this window is focused, clear `is-focused' on all other windows."
  (let ((id (niri-rpc-window-id win))
        (is-focused (niri-rpc-window-is-focused win)))
    (puthash id win niri-rpc--windows)
    (when is-focused
      (maphash
       (lambda (wid w)
         (unless (= wid id)
           (setf (niri-rpc-window-is-focused w) nil)))
       niri-rpc--windows))))

(defun niri-rpc--apply-window-closed (id)
  "Remove window ID from the windows map."
  (remhash id niri-rpc--windows))

(defun niri-rpc--apply-window-focus-changed (id)
  "Update which window is focused.
ID can be nil, meaning no window is focused."
  (maphash
   (lambda (wid w)
     (setf (niri-rpc-window-is-focused w) (equal wid id)))
   niri-rpc--windows))

(defun niri-rpc--apply-window-focus-timestamp-changed (id ts)
  "Update focus timestamp for window ID to TS."
  (let ((win (gethash id niri-rpc--windows)))
    (when win
      (setf (niri-rpc-window-focus-timestamp win) ts))))

(defun niri-rpc--apply-window-urgency-changed (id urgent)
  "Update urgency for window ID to URGENT."
  (let ((win (gethash id niri-rpc--windows)))
    (when win
      (setf (niri-rpc-window-is-urgent win) urgent))))

(defun niri-rpc--parse-layout-changes (changes)
  "Parse layout CHANGES (JSON array of [id, layout-alist] pairs) into an alist."
  (let ((result nil))
    (dolist (pair (append changes nil))
      (let ((id (elt pair 0))
            (layout (niri-rpc--parse-window-layout (elt pair 1))))
        (push (cons id layout) result)))
    (nreverse result)))

(defun niri-rpc--apply-window-layouts-changed (changes)
  "Apply layout CHANGES (alist of id . niri-rpc-window-layout)."
  (dolist (pair changes)
    (let ((id (car pair))
          (layout (cdr pair)))
      (let ((win (gethash id niri-rpc--windows)))
        (when win
          (setf (niri-rpc-window-layout win) layout))))))

;; ── Keyboard layout state updates ───────────────────────────────────────

(defun niri-rpc--apply-keyboard-layouts-changed (kb)
  "Set the keyboard layouts to KB."
  (setq niri-rpc--keyboard-layouts kb))

(defun niri-rpc--apply-keyboard-layout-switched (idx)
  "Switch the current keyboard layout index to IDX."
  (when niri-rpc--keyboard-layouts
    (setf (niri-rpc-keyboard-layouts-current-idx niri-rpc--keyboard-layouts) idx)))

;; ── Overview state updates ──────────────────────────────────────────────

(defun niri-rpc--apply-overview-opened-or-closed (is-open)
  "Set the overview state to IS-OPEN."
  (setq niri-rpc--overview-is-open is-open))

;; ── Config state updates ────────────────────────────────────────────────

(defun niri-rpc--apply-config-loaded (failed)
  "Set the config failed state to FAILED."
  (setq niri-rpc--config-failed failed))

;; ── Casts state updates ─────────────────────────────────────────────────

(defun niri-rpc--apply-casts-changed (casts)
  "Replace all casts with CASTS (list of alists)."
  (clrhash niri-rpc--casts)
  (dolist (cast-alist (append casts nil))
    (let ((cast (niri-rpc--parse-cast cast-alist)))
      (puthash (niri-rpc-cast-stream-id cast) cast niri-rpc--casts))))

(defun niri-rpc--apply-cast-started-or-changed (cast)
  "Insert or update CAST in the casts map."
  (puthash (niri-rpc-cast-stream-id cast) cast niri-rpc--casts))

(defun niri-rpc--apply-cast-stopped (stream-id)
  "Remove cast with STREAM-ID from the casts map."
  (remhash stream-id niri-rpc--casts))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; Utility
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(defun niri-rpc--hash-values (hash)
  "Return a list of all values in HASH."
  (let ((values nil))
    (maphash (lambda (_k v) (push v values)) hash)
    (nreverse values)))

(defun niri-rpc--socket-env ()
  "Get the niri socket path from the NIRI_SOCKET environment variable."
  (or (getenv "NIRI_SOCKET")
      (error "NIRI_SOCKET is not set; are you running within niri?")))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; Connection management
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(defun niri-rpc--ensure-connected ()
  "Ensure we're connected to the niri socket."
  (unless (and niri-rpc--async-process
               (eq (process-status niri-rpc--async-process) 'open))
    (error "niri-rpc: not connected.  Call (niri-rpc-connect) first")))

;;;###autoload
(defun niri-rpc-connect ()
  "Connect to the niri IPC socket.

Opens an async event-stream connection that continuously receives
compositor events and updates client-side state.  The socket path
is read from the $NIRI_SOCKET environment variable."
  (interactive)
  (when (and niri-rpc--async-process
             (eq (process-status niri-rpc--async-process) 'open))
    (niri-rpc-disconnect))

  (setq niri-rpc--socket-path (niri-rpc--socket-env))

  ;; ── Reset state ──────────────────────────────────────────────────────
  (clrhash niri-rpc--workspaces)
  (clrhash niri-rpc--windows)
  (setq niri-rpc--keyboard-layouts nil)
  (setq niri-rpc--overview-is-open nil)
  (setq niri-rpc--config-failed nil)
  (clrhash niri-rpc--casts)
  (setq niri-rpc--async-line-buffer "")

  ;; ── Open async event-stream socket ───────────────────────────────────
  (let ((proc (make-network-process
               :name "niri-rpc-event"
               :family 'local
               :service niri-rpc--socket-path
               :coding 'utf-8-unix
               :noquery t
               :filter #'niri-rpc--async-filter
               :sentinel #'niri-rpc--async-sentinel)))
    ;; Request the event stream
    (process-send-string proc "\"EventStream\"\n")
    (setq niri-rpc--async-process proc))
  ;; Wait for the initial Handled reply
  (let ((start-time (float-time)))
    (while (and (< (- (float-time) start-time) 2.0)
                (= (hash-table-count niri-rpc--workspaces) 0))
      (accept-process-output niri-rpc--async-process 0.1)))

  ;; Discard the initial Handled reply from the line buffer
  ;; (it's already been consumed by the filter, so nothing to do)
  (message "niri-rpc: connected"))

;;;###autoload
(defun niri-rpc-disconnect ()
  "Disconnect from the niri IPC socket."
  (interactive)
  (when niri-rpc--async-process
    (delete-process niri-rpc--async-process)
    (setq niri-rpc--async-process nil))
  (setq niri-rpc--async-line-buffer "")
  (clrhash niri-rpc--workspaces)
  (clrhash niri-rpc--windows)
  (setq niri-rpc--keyboard-layouts nil)
  (setq niri-rpc--overview-is-open nil)
  (setq niri-rpc--config-failed nil)
  (clrhash niri-rpc--casts)
  (message "niri-rpc: disconnected"))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; Sync command
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(defun niri-rpc--parse-reply (reply-alist)
  "Parse a reply alist and return the value or signal an error.
REPLY-ALIST is the parsed JSON response from niri as an alist."
  (let* ((first (car reply-alist))
         (status (car first))
         (value (cdr first)))
    (pcase status
      ('Ok
       (cond
        ((stringp value)
         ;; Response::Handled is just the string "Handled"
         t)
        (t
         ;; Other responses are {ResponseVariant: data}
         (let ((resp-type (caar value))
               (resp-data (cdar value)))
           (pcase resp-type
             ('Version resp-data)
             ('Outputs (niri-rpc--parse-reply-outputs resp-data))
             ('Workspaces (mapcar #'niri-rpc--parse-workspace
                                  (append resp-data nil)))
             ('Windows (mapcar #'niri-rpc--parse-window
                               (append resp-data nil)))
             ('Layers (mapcar #'niri-rpc--parse-layer-surface
                              (append resp-data nil)))
             ('KeyboardLayouts (niri-rpc--parse-keyboard-layouts resp-data))
             ('FocusedOutput (niri-rpc--parse-output resp-data))
             ('FocusedWindow (niri-rpc--parse-window resp-data))
             ('PickedWindow (niri-rpc--parse-window resp-data))
             ('PickedColor resp-data)
             ('OutputConfigChanged resp-data)
             ('OverviewState resp-data)
             ('Casts (mapcar #'niri-rpc--parse-cast
                             (append resp-data nil)))
             (_ resp-data))))))
      ('Err (error "niri-rpc: %s" value))
      (_ (error "niri-rpc: unexpected reply format: %S" reply-alist)))))

(defun niri-rpc--parse-reply-outputs (hash-alist)
  "Parse an outputs hash map from REPLY into an alist of (name . niri-rpc-output)."
  (let ((result nil))
    (dolist (entry hash-alist)
      (push (cons (car entry) (niri-rpc--parse-output (cdr entry))) result))
    (nreverse result)))

;;;###autoload
(defun niri-rpc-command (request)
  "Send a synchronous REQUEST to niri and return the reply.

REQUEST is a value suitable for `json-serialize': typically a plist
or alist representing the JSON structure.

For unit variants (no fields), you can use a single-element plist:
  (niri-rpc-command '(:FocusedWindow))
  (niri-rpc-command '(:Version))

For struct variants with fields, use a nested plist:
  (niri-rpc-command '(:Action (:FocusColumnLeft)))
  (niri-rpc-command '(:Action (:FocusWindow (:id 42))))

Signals an error on timeout or niri error response."
  (niri-rpc--ensure-connected)
  ;; Normalize unit variants: single-keyword plists get :null value
  (when (and (listp request) (= (length request) 1) (keywordp (car request)))
    (setq request (list (car request) :null)))
  (let* ((json-str (concat (json-serialize request) "\n"))
         (reply-buf nil)
         (done nil)
         (start-time (float-time))
         (proc (make-network-process
                :name "niri-rpc-tmp"
                :family 'local
                :service niri-rpc--socket-path
                :coding 'utf-8-unix
                :noquery t
                :filter (lambda (_p str)
                          (push str reply-buf)
                          (when (string-match-p "\n" str)
                            (setq done t))))))
    (unwind-protect
        (progn
          (process-send-string proc json-str)
          (while (and (not done)
                      (< (- (float-time) start-time) niri-rpc-timeout))
            (accept-process-output proc 0.1))
          (unless done
            (error "niri-rpc: timeout waiting for reply (%.1f seconds)"
                   niri-rpc-timeout))
          (let* ((reply-str (string-trim
                             (apply #'concat (nreverse reply-buf))))
                 (parsed (niri-rpc--json-read reply-str)))
            (niri-rpc--parse-reply parsed)))
      (delete-process proc))))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; Public accessors (query the event-stream state)
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

;;;###autoload
(defun niri-rpc-workspaces ()
  "Return a list of all workspaces as `niri-rpc-workspace' structs."
  (niri-rpc--ensure-connected)
  (niri-rpc--hash-values niri-rpc--workspaces))

;;;###autoload
(defun niri-rpc-workspace-by-id (id)
  "Return the `niri-rpc-workspace' struct for workspace ID, or nil if not found."
  (niri-rpc--ensure-connected)
  (gethash id niri-rpc--workspaces))

;;;###autoload
(defun niri-rpc-focused-workspace ()
  "Return the currently focused `niri-rpc-workspace' struct, or nil."
  (niri-rpc--ensure-connected)
  (catch 'found
    (maphash
     (lambda (_id ws)
       (when (niri-rpc-workspace-is-focused ws)
         (throw 'found ws)))
     niri-rpc--workspaces)
    nil))

;;;###autoload
(defun niri-rpc-active-workspace-for-output (output-name)
  "Return the active `niri-rpc-workspace' on OUTPUT-NAME, or nil."
  (niri-rpc--ensure-connected)
  (catch 'found
    (maphash
     (lambda (_id ws)
       (when (and (equal (niri-rpc-workspace-output ws) output-name)
                  (niri-rpc-workspace-is-active ws))
         (throw 'found ws)))
     niri-rpc--workspaces)
    nil))

;;;###autoload
(defun niri-rpc-windows ()
  "Return a list of all windows as `niri-rpc-window' structs."
  (niri-rpc--ensure-connected)
  (niri-rpc--hash-values niri-rpc--windows))

;;;###autoload
(defun niri-rpc-window-by-id (id)
  "Return the `niri-rpc-window' struct for window ID, or nil if not found."
  (niri-rpc--ensure-connected)
  (gethash id niri-rpc--windows))

;;;###autoload
(defun niri-rpc-focused-window ()
  "Return the currently focused `niri-rpc-window' struct, or nil."
  (niri-rpc--ensure-connected)
  (catch 'found
    (maphash
     (lambda (_id win)
       (when (niri-rpc-window-is-focused win)
         (throw 'found win)))
     niri-rpc--windows)
    nil))

;;;###autoload
(defun niri-rpc-windows-for-workspace (workspace-id)
  "Return a list of `niri-rpc-window' structs on WORKSPACE-ID."
  (niri-rpc--ensure-connected)
  (let ((windows nil))
    (maphash
     (lambda (_id win)
       (when (equal (niri-rpc-window-workspace-id win) workspace-id)
         (push win windows)))
     niri-rpc--windows)
    (nreverse windows)))

;;;###autoload
(defun niri-rpc-keyboard-layouts ()
  "Return the current `niri-rpc-keyboard-layouts' struct, or nil."
  (niri-rpc--ensure-connected)
  niri-rpc--keyboard-layouts)

;;;###autoload
(defun niri-rpc-overview-is-open ()
  "Return non-nil if the niri overview is currently open."
  (niri-rpc--ensure-connected)
  niri-rpc--overview-is-open)

;;;###autoload
(defun niri-rpc-config-failed-p ()
  "Return non-nil if the last config load attempt failed."
  (niri-rpc--ensure-connected)
  niri-rpc--config-failed)

;;;###autoload
(defun niri-rpc-casts ()
  "Return a list of all screencasts as `niri-rpc-cast' structs."
  (niri-rpc--ensure-connected)
  (niri-rpc--hash-values niri-rpc--casts))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; Hook
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

;;;###autoload
(defvar niri-rpc-event-hook nil
  "Hook run after each event from the niri event stream.
Each function receives one argument: a `niri-rpc-event' struct.

The internal state has already been updated when this hook runs,
so accessor functions like `niri-rpc-focused-window' will return
current values.

Example:
  (add-hook \\='niri-rpc-event-hook
    (lambda (ev)
      (pcase (niri-rpc-event-type ev)
        (\\='window-focus-changed
         (message \"Focus: %S\" (niri-rpc-focused-window))))))")

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; Convenience action wrappers
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

;;;###autoload
(defun niri-rpc-action (action)
  "Send an ACTION to niri.
ACTION is a plist representing the action, e.g. `(:FocusColumnLeft)'.

Example:
  (niri-rpc-action '(:FocusColumnLeft))
  (niri-rpc-action '(:FocusWindow (:id 42)))"
  ;; Normalize struct unit variants: single-keyword plists get nil value
  (when (and (listp action) (= (length action) 1) (keywordp (car action)))
    (setq action (list (car action) nil)))
  (niri-rpc-command `(:Action ,action)))

;;;###autoload
(defun niri-rpc-focus-window (id)
  "Focus window by ID."
  (interactive "nWindow ID: ")
  (niri-rpc-action `(:FocusWindow (:id ,id))))

;;;###autoload
(defun niri-rpc-close-window (&optional id)
  "Close a window.  If ID is nil, closes the focused window."
  (interactive)
  (niri-rpc-action `(:CloseWindow (:id ,(or id :json-null)))))

;;;###autoload
(defun niri-rpc-focus-workspace (reference)
  "Focus a workspace by REFERENCE (index or name).
Example:
  (niri-rpc-focus-workspace 1)
  (niri-rpc-focus-workspace \"emacs\")"
  (interactive "sWorkspace: ")
  (let ((ref (if (numberp reference)
                 (format "%d" reference)
               reference)))
    (niri-rpc-action `(:FocusWorkspace (:reference (:Name ,ref))))))

;;;###autoload
(defun niri-rpc-move-window-to-workspace (reference &optional window-id)
  "Move WINDOW-ID (or focused window) to workspace REFERENCE."
  (niri-rpc-action
   `(:MoveWindowToWorkspace
     (:window_id ,(or window-id :json-null)
      :reference (:Name ,(if (numberp reference)
                             (format "%d" reference)
                           reference))
      :focus t))))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(provide 'niri-rpc)
;;; niri-rpc.el ends here
