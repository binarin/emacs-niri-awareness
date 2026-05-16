;;; niri-rpc-test.el --- Integration tests for niri-rpc  -*- lexical-binding: t -*-

(require 'ert)
(require 'niri-rpc (expand-file-name "niri-rpc.el"
                                     (file-name-directory
                                      (or load-file-name buffer-file-name))))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;; Helpers
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(defvar niri-rpc-test--events nil
  "Collected events during tests.")

(defun niri-rpc-test--event-collector (event)
  "Collect EVENT into `niri-rpc-test--events' for test inspection."
  (push event niri-rpc-test--events))

(defun niri-rpc-test--setup ()
  "Connect to niri and set up event collection."
  (niri-rpc-connect)
  (setq niri-rpc-test--events nil)
  (add-hook 'niri-rpc-event-hook #'niri-rpc-test--event-collector)
  ;; Wait for initial state to populate
  (let ((start (float-time)))
    (while (and (< (- (float-time) start) 2.0)
                (= (hash-table-count niri-rpc--windows) 0))
      (accept-process-output niri-rpc--async-process 0.1))))

(defun niri-rpc-test--teardown ()
  "Remove event collector."
  (remove-hook 'niri-rpc-event-hook #'niri-rpc-test--event-collector)
  (setq niri-rpc-test--events nil))

(defun niri-rpc-test--wait-for-events (timeout)
  "Wait up to TIMEOUT seconds for events to arrive."
  (let ((start (float-time)))
    (while (< (- (float-time) start) timeout)
      (accept-process-output niri-rpc--async-process 0.05))))

(defun niri-rpc-test--events-of-type (type-symbol)
  "Return events in `niri-rpc-test--events' matching TYPE-SYMBOL."
  (cl-remove-if-not
   (lambda (ev) (eq (niri-rpc-event-type ev) type-symbol))
   niri-rpc-test--events))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;; Tests: Connection & basic state
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(ert-deftest niri-rpc-connect-disconnect ()
  "Test that we can connect and disconnect from niri."
  (niri-rpc-test--setup)
  (should niri-rpc--async-process)
  (should (eq (process-status niri-rpc--async-process) 'open))
  (niri-rpc-test--teardown)
  (niri-rpc-disconnect)
  (should-not niri-rpc--async-process))

(ert-deftest niri-rpc-state-populated ()
  "Test that event-stream state is populated after connect."
  (niri-rpc-test--setup)
  (should (> (hash-table-count niri-rpc--workspaces) 0))
  (should (> (hash-table-count niri-rpc--windows) 0))
  (niri-rpc-test--teardown))

(ert-deftest niri-rpc-focus-workspace-id ()
  "Test that workspaces have proper id fields."
  (niri-rpc-test--setup)
  (let ((workspaces (niri-rpc-workspaces)))
    (should workspaces)
    (dolist (ws workspaces)
      (should (integerp (niri-rpc-workspace-id ws)))
      (should (integerp (niri-rpc-workspace-idx ws)))))
  (niri-rpc-test--teardown))

(ert-deftest niri-rpc-window-struct-fields ()
  "Test that window structs have all expected fields."
  (niri-rpc-test--setup)
  (let ((windows (niri-rpc-windows)))
    (should windows)
    (dolist (win windows)
      (should (integerp (niri-rpc-window-id win)))
      (should (niri-rpc-window-p win))
      (should (niri-rpc-window-layout-p (niri-rpc-window-layout win))))))

(ert-deftest niri-rpc-focus-window-by-id ()
  "Test focusing a window by id via IPC and verifying state update."
  (niri-rpc-test--setup)
  (let* ((windows (niri-rpc-windows))
         (target (car windows))
         (target-id (niri-rpc-window-id target)))
    ;; Skip if target is already focused
    (unless (niri-rpc-window-is-focused target)
      (setq niri-rpc-test--events nil)
      (niri-rpc-action `(:FocusWindow (:id ,target-id)))
      (niri-rpc-test--wait-for-events 0.5)
      ;; Should have received window-focus-changed event
      (let ((focus-events (niri-rpc-test--events-of-type
                           'window-focus-changed)))
        (should focus-events)
        (should (equal (niri-rpc-event-window-id (car focus-events))
                       target-id)))
      ;; State should be updated
      (let ((focused (niri-rpc-focused-window)))
        (should focused)
        (should (= (niri-rpc-window-id focused) target-id))
        (should (niri-rpc-window-is-focused focused)))))
  (niri-rpc-test--teardown))

(ert-deftest niri-rpc-window-by-id-missing ()
  "Test that window-by-id returns nil for nonexistent id."
  (niri-rpc-test--setup)
  (should-not (niri-rpc-window-by-id 99999999)))

(ert-deftest niri-rpc-workspace-by-id-missing ()
  "Test that workspace-by-id returns nil for nonexistent id."
  (niri-rpc-test--setup)
  (should-not (niri-rpc-workspace-by-id 99999999)))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;; Tests: Sync commands
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(ert-deftest niri-rpc-sync-version ()
  "Test Version sync request."
  (niri-rpc-test--setup)
  (let ((version (niri-rpc-command '(:Version))))
    (should (stringp version))
    (should (string-match-p "^[0-9]+\\." version))))

(ert-deftest niri-rpc-sync-workspaces ()
  "Test Workspaces sync request."
  (niri-rpc-test--setup)
  (let ((workspaces (niri-rpc-command '(:Workspaces))))
    (should workspaces)
    (should (listp workspaces))
    (dolist (ws workspaces)
      (should (niri-rpc-workspace-p ws)))))

(ert-deftest niri-rpc-sync-windows ()
  "Test Windows sync request."
  (niri-rpc-test--setup)
  (let ((windows (niri-rpc-command '(:Windows))))
    (should windows)
    (should (listp windows))
    (dolist (win windows)
      (should (niri-rpc-window-p win)))))

(ert-deftest niri-rpc-sync-focused-window ()
  "Test FocusedWindow sync request."
  (niri-rpc-test--setup)
  (let ((win (niri-rpc-command '(:FocusedWindow))))
    (should (or (niri-rpc-window-p win) (null win)))))

(ert-deftest niri-rpc-sync-outputs ()
  "Test Outputs sync request returns proper data."
  (niri-rpc-test--setup)
  (let ((outputs (niri-rpc-command '(:Outputs))))
    (should outputs)
    (should (listp outputs))
    (dolist (pair outputs)
      (should (stringp (car pair)))
      (should (niri-rpc-output-p (cdr pair))))))

(ert-deftest niri-rpc-sync-overview-state ()
  "Test OverviewState sync request."
  (niri-rpc-test--setup)
  ;; Open overview, check, close
  (niri-rpc-action '(:OpenOverview))
  (sit-for 0.3)
  (let ((state (niri-rpc-command '(:OverviewState))))
    (should state))
  ;; Close it
  (niri-rpc-action '(:CloseOverview))
  (sit-for 0.3))

(ert-deftest niri-rpc-sync-error ()
  "Test that an invalid action signals an error."
  (niri-rpc-test--setup)
  ;; Sending a string instead of an action object should error
  (should-error
   (niri-rpc-command "not a valid request")))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;; Tests: Actions (integration)
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(ert-deftest niri-rpc-action-focus-workspace ()
  "Test focusing a different workspace via action and verify events."
  (niri-rpc-test--setup)
  (let* ((workspaces (niri-rpc-workspaces))
         (focused-ws (niri-rpc-focused-workspace))
         (focused-idx (niri-rpc-workspace-idx focused-ws))
         (target-idx (if (> focused-idx 1) (1- focused-idx) (1+ focused-idx))))
    ;; Focus target workspace
    (setq niri-rpc-test--events nil)
    (niri-rpc-action `(:FocusWorkspace (:reference (:Index ,target-idx))))
    (niri-rpc-test--wait-for-events 0.5)
    ;; Should have workspace-activated events
    (let ((activated (niri-rpc-test--events-of-type
                      'workspace-activated)))
      (should activated))
    ;; State should reflect the change
    (let ((new-focused (niri-rpc-focused-workspace)))
      (should new-focused)
      (should (= (niri-rpc-workspace-idx new-focused) target-idx))))
  (niri-rpc-test--teardown))

(ert-deftest niri-rpc-action-focus-workspace-by-name ()
  "Test focusing a workspace by name via action."
  (niri-rpc-test--setup)
  (let ((workspaces (niri-rpc-workspaces)))
    ;; Find a named workspace
    (let ((named (cl-find-if #'niri-rpc-workspace-name workspaces)))
      (when named
        (let ((name (niri-rpc-workspace-name named)))
          (niri-rpc-action `(:FocusWorkspace (:reference (:Name ,name))))
          (niri-rpc-test--wait-for-events 0.5)
          (let ((focused (niri-rpc-focused-workspace)))
            (should focused)
            (should (equal (niri-rpc-workspace-name focused) name)))))))
  (niri-rpc-test--teardown))

(ert-deftest niri-rpc-action-move-column ()
  "Test MoveColumnLeft and MoveColumnRight actions."
  (niri-rpc-test--setup)
  ;; These should not error
  (niri-rpc-action '(:MoveColumnLeft))
  (niri-rpc-action '(:MoveColumnRight))
  (niri-rpc-test--wait-for-events 0.3)
  t)

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;; Tests: Data structures
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(ert-deftest niri-rpc-struct-timestamp ()
  "Test timestamp struct creation and accessors."
  (let ((ts (make-niri-rpc-timestamp :secs 123 :nanos 456789)))
    (should (niri-rpc-timestamp-p ts))
    (should (= (niri-rpc-timestamp-secs ts) 123))
    (should (= (niri-rpc-timestamp-nanos ts) 456789))))

(ert-deftest niri-rpc-struct-window-layout ()
  "Test window-layout struct creation and accessors."
  (let ((layout (make-niri-rpc-window-layout
                 :pos-in-scrolling-layout '(1 . 2)
                 :tile-size '(100.0 . 200.0)
                 :window-size '(99 . 199)
                 :tile-pos-in-workspace-view nil
                 :window-offset-in-tile '(0.5 . 0.5)
                 :is-visible-in-column t)))
    (should (niri-rpc-window-layout-p layout))
    (should (equal (niri-rpc-window-layout-pos-in-scrolling-layout layout)
                   '(1 . 2)))
    (should (equal (niri-rpc-window-layout-tile-size layout)
                   '(100.0 . 200.0)))
    (should (niri-rpc-window-layout-is-visible-in-column layout))))

(ert-deftest niri-rpc-struct-window ()
  "Test window struct creation and accessors."
  (let ((win (make-niri-rpc-window
              :id 42 :title "Test" :app-id "test.app"
              :is-focused t :is-floating nil :is-urgent nil)))
    (should (niri-rpc-window-p win))
    (should (= (niri-rpc-window-id win) 42))
    (should (equal (niri-rpc-window-title win) "Test"))
    (should (niri-rpc-window-is-focused win))
    (should-not (niri-rpc-window-is-floating win))))

(ert-deftest niri-rpc-struct-workspace ()
  "Test workspace struct creation and accessors."
  (let ((ws (make-niri-rpc-workspace
             :id 1 :idx 2 :name "test" :output "DP-1"
             :is-urgent nil :is-active t :is-focused nil
             :active-window-id 42)))
    (should (niri-rpc-workspace-p ws))
    (should (= (niri-rpc-workspace-id ws) 1))
    (should (= (niri-rpc-workspace-idx ws) 2))
    (should (equal (niri-rpc-workspace-name ws) "test"))
    (should (niri-rpc-workspace-is-active ws))
    (should-not (niri-rpc-workspace-is-focused ws))
    (should (= (niri-rpc-workspace-active-window-id ws) 42))))

(ert-deftest niri-rpc-struct-event ()
  "Test event struct creation and accessors."
  (let ((ev (make-niri-rpc-event
             :type 'workspace-activated
             :workspace-id 5
             :focused-p t)))
    (should (niri-rpc-event-p ev))
    (should (eq (niri-rpc-event-type ev) 'workspace-activated))
    (should (= (niri-rpc-event-workspace-id ev) 5))
    (should (niri-rpc-event-focused-p ev))))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;; Tests: Process filter (partial reads)
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(ert-deftest niri-rpc-filter-partial-lines ()
  "Test that the process filter handles partial reads correctly."
  (let ((niri-rpc--async-line-buffer "")
        (niri-rpc--workspaces (make-hash-table :test 'eql))
        (niri-rpc--windows (make-hash-table :test 'eql))
        (niri-rpc--keyboard-layouts nil)
        (niri-rpc--overview-is-open nil)
        (niri-rpc--config-failed nil)
        (niri-rpc--casts (make-hash-table :test 'eql))
        (event-count 0))
    ;; Temporarily override the filter to count events
    (cl-letf (((symbol-function 'niri-rpc--handle-event-line)
               (lambda (line)
                 (cl-incf event-count))))
      ;; Simulate a partial read split across multiple chunks
      (let ((full-json "{\"WorkspacesChanged\":{\"workspaces\":[]}}\n{\"WindowsChanged\":{\"windows\":[]}}\n"))
        ;; Send first half
        (niri-rpc--async-filter nil (substring full-json 0 40))
        (should (= event-count 0))  ;; No complete lines yet
        (should (> (length niri-rpc--async-line-buffer) 0))
        ;; Send second half
        (niri-rpc--async-filter nil (substring full-json 40))
        (should (= event-count 2))  ;; Two complete events
        (should (string-empty-p niri-rpc--async-line-buffer))))))

(ert-deftest niri-rpc-filter-no-trailing-newline ()
  "Test that an incomplete line at the end is preserved."
  (let ((niri-rpc--async-line-buffer "")
        (event-count 0))
    (cl-letf (((symbol-function 'niri-rpc--handle-event-line)
               (lambda (_line) (cl-incf event-count))))
      (niri-rpc--async-filter nil "{\"OverviewOpenedOrClosed\":{\"is_open\":true}}\n{\"ConfigLoaded\":")
      (should (= event-count 1))
      (should (string= niri-rpc--async-line-buffer
                       "{\"ConfigLoaded\":"))))
  ;; Send the rest
  (let ((niri-rpc--async-line-buffer "{\"ConfigLoaded\":")
        (event-count 0))
    (cl-letf (((symbol-function 'niri-rpc--handle-event-line)
               (lambda (_line) (cl-incf event-count))))
      (niri-rpc--async-filter nil "{\"failed\":false}}\n")
      (should (= event-count 1))
      (should (string-empty-p niri-rpc--async-line-buffer)))))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;; Tests: JSON round-trip
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(ert-deftest niri-rpc-json-parse-window ()
  "Test parsing a window from JSON."
  (let ((json "{\"id\":123,\"title\":\"My Window\",\"app_id\":\"my.app\",\"pid\":5555,\"workspace_id\":3,\"is_focused\":true,\"is_floating\":false,\"is_urgent\":false,\"layout\":{\"pos_in_scrolling_layout\":[1,2],\"tile_size\":[100.0,200.0],\"window_size\":[99,199],\"tile_pos_in_workspace_view\":null,\"window_offset_in_tile\":[0.5,0.5]},\"focus_timestamp\":{\"secs\":100,\"nanos\":500}}")
        (alist (niri-rpc--json-read json))
        (win (niri-rpc--parse-window alist)))
    (should (niri-rpc-window-p win))
    (should (= (niri-rpc-window-id win) 123))
    (should (equal (niri-rpc-window-title win) "My Window"))
    (should (equal (niri-rpc-window-app-id win) "my.app"))
    (should (= (niri-rpc-window-pid win) 5555))
    (should (= (niri-rpc-window-workspace-id win) 3))
    (should (niri-rpc-window-is-focused win))
    (should-not (niri-rpc-window-is-floating win))
    (let ((layout (niri-rpc-window-layout win)))
      (should layout)
      (should (equal (niri-rpc-window-layout-pos-in-scrolling-layout layout)
                     '(1 . 2)))
      (should (equal (niri-rpc-window-layout-tile-size layout)
                     '(100.0 . 200.0)))
      ;; is_visible_in_column missing from JSON → defaults to t
      (should (niri-rpc-window-layout-is-visible-in-column layout)))))

(ert-deftest niri-rpc-json-parse-window-layout-is-visible-in-column ()
  "Test parsing is_visible_in_column field from JSON."
  ;; Test with is_visible_in_column: false
  (let* ((json "{\"id\":1,\"layout\":{\"tile_size\":[100.0,200.0],\"window_size\":[99,199],\"window_offset_in_tile\":[0.5,0.5],\"is_visible_in_column\":false}}")
         (alist (niri-rpc--json-read json))
         (win (niri-rpc--parse-window alist))
         (layout (niri-rpc-window-layout win)))
    (should layout)
    (should-not (niri-rpc-window-layout-is-visible-in-column layout)))
  ;; Test with is_visible_in_column: true
  (let* ((json "{\"id\":2,\"layout\":{\"tile_size\":[100.0,200.0],\"window_size\":[99,199],\"window_offset_in_tile\":[0.5,0.5],\"is_visible_in_column\":true}}")
         (alist (niri-rpc--json-read json))
         (win (niri-rpc--parse-window alist))
         (layout (niri-rpc-window-layout win)))
    (should layout)
    (should (niri-rpc-window-layout-is-visible-in-column layout)))
  ;; Test with is_visible_in_column absent (backward compat)
  (let* ((json "{\"id\":3,\"layout\":{\"tile_size\":[100.0,200.0],\"window_size\":[99,199],\"window_offset_in_tile\":[0.5,0.5]}}")
         (alist (niri-rpc--json-read json))
         (win (niri-rpc--parse-window alist))
         (layout (niri-rpc-window-layout win)))
    (should layout)
    (should (niri-rpc-window-layout-is-visible-in-column layout))))

(ert-deftest niri-rpc-json-parse-workspace ()
  "Test parsing a workspace from JSON."
  (let ((json "{\"id\":10,\"idx\":3,\"name\":\"coding\",\"output\":\"DP-1\",\"is_urgent\":false,\"is_active\":true,\"is_focused\":true,\"active_window_id\":42}")
        (alist (niri-rpc--json-read json))
        (ws (niri-rpc--parse-workspace alist)))
    (should (niri-rpc-workspace-p ws))
    (should (= (niri-rpc-workspace-id ws) 10))
    (should (= (niri-rpc-workspace-idx ws) 3))
    (should (equal (niri-rpc-workspace-name ws) "coding"))
    (should (equal (niri-rpc-workspace-output ws) "DP-1"))
    (should (niri-rpc-workspace-is-active ws))
    (should (niri-rpc-workspace-is-focused ws))
    (should-not (niri-rpc-workspace-is-urgent ws))
    (should (= (niri-rpc-workspace-active-window-id ws) 42))))

(ert-deftest niri-rpc-json-null-names ()
  "Test that JSON null values are converted to nil."
  (let ((json "{\"id\":5,\"idx\":1,\"name\":null,\"output\":null,\"is_urgent\":true,\"is_active\":false,\"is_focused\":false,\"active_window_id\":null}")
        (alist (niri-rpc--json-read json))
        (ws (niri-rpc--parse-workspace alist)))
    (should-not (niri-rpc-workspace-name ws))
    (should-not (niri-rpc-workspace-output ws))
    (should-not (niri-rpc-workspace-active-window-id ws))
    (should (niri-rpc-workspace-is-urgent ws))))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;; Tests: Workspace filtering accessors
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(ert-deftest niri-rpc-windows-for-workspace ()
  "Test filtering windows by workspace."
  (niri-rpc-test--setup)
  (let ((workspaces (niri-rpc-workspaces)))
    (dolist (ws workspaces)
      (let ((ws-id (niri-rpc-workspace-id ws))
            (windows (niri-rpc-windows-for-workspace
                      (niri-rpc-workspace-id ws))))
        (dolist (win windows)
          (should (= (niri-rpc-window-workspace-id win) ws-id))))))
  (niri-rpc-test--teardown))

(ert-deftest niri-rpc-focused-workspace ()
  "Test that focused workspace is consistent."
  (niri-rpc-test--setup)
  (let ((focused (niri-rpc-focused-workspace)))
    (should focused)
    (should (niri-rpc-workspace-is-focused focused))
    (should (niri-rpc-workspace-is-active focused)))
  (niri-rpc-test--teardown))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;; Tests: Window absolute rect tracking
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(ert-deftest niri-rpc-window-absolute-rect ()
  "Test that window absolute rects are computed."
  (niri-rpc-test--setup)
  (let ((windows (niri-rpc-windows)))
    (should windows)
    (dolist (win windows)
      (let ((rect (niri-rpc-window-absolute-rect (niri-rpc-window-id win))))
        (should rect)
        (should (= (length rect) 4))
        ;; x, y, width, height should be numbers
        (should (numberp (nth 0 rect)))
        (should (numberp (nth 1 rect)))
        (should (numberp (nth 2 rect)))
        (should (numberp (nth 3 rect)))
        ;; width and height should be positive
        (should (> (nth 2 rect) 0))
        (should (> (nth 3 rect) 0)))))
  (niri-rpc-test--teardown))

(ert-deftest niri-rpc-window-absolute-rect-missing ()
  "Test that absolute rect returns nil for nonexistent windows."
  (niri-rpc-test--setup)
  (should-not (niri-rpc-window-absolute-rect 99999999))
  (niri-rpc-test--teardown))

(ert-deftest niri-rpc-refresh-outputs ()
  "Test that refresh-outputs works."
  (niri-rpc-test--setup)
  ;; Should not error
  (niri-rpc-refresh-outputs)
  ;; After refresh, rects should still be computable
  (let ((windows (niri-rpc-windows)))
    (when windows
      (let ((rect (niri-rpc-window-absolute-rect
                   (niri-rpc-window-id (car windows)))))
        (should rect))))
  (niri-rpc-test--teardown))

(ert-deftest niri-rpc-absolute-rect-layout-update ()
  "Test that absolute rects update when window layouts change."
  (niri-rpc-test--setup)
  (let* ((windows (niri-rpc-windows))
         (target (car windows))
         (target-id (niri-rpc-window-id target))
         (rect-before (niri-rpc-window-absolute-rect target-id)))
    (should rect-before)
    (setq niri-rpc-test--events nil)
    ;; Trigger a layout change by switching preset column width
    (niri-rpc-action '(:SwitchPresetColumnWidth))
    (niri-rpc-test--wait-for-events 0.5)
    ;; Check that we got a layout change event
    (let ((layout-events (niri-rpc-test--events-of-type
                          'window-layouts-changed)))
      (when layout-events
        (let ((rect-after (niri-rpc-window-absolute-rect target-id)))
          ;; Rect should still be computable after layout change
          (should rect-after)))))
  (niri-rpc-test--teardown))

(provide 'niri-rpc-test)
;;; niri-rpc-test.el ends here
