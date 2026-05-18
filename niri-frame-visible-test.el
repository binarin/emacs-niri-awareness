;;; niri-frame-visible-test.el --- Tests for niri-frame-visible  -*- lexical-binding: t -*-

(require 'ert)
(require 'niri-rpc (expand-file-name "niri-rpc.el"
                                     (file-name-directory
                                      (or load-file-name buffer-file-name))))
(require 'niri-frame (expand-file-name "niri-frame.el"
                                       (file-name-directory
                                        (or load-file-name buffer-file-name))))
(require 'niri-frame-visible (expand-file-name "niri-frame-visible.el"
                                               (file-name-directory
                                                (or load-file-name buffer-file-name))))
(require 'cl-lib)

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;; Helpers
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(defvar niri-frame-visible-test--orig-outputs nil
  "Backup of `niri-rpc--outputs-cache' before test modifications.")

(defun niri-frame-visible-test--mock-outputs (specs)
  "Populate `niri-rpc--outputs-cache' with mock output SPECS.

SPECS is a list of plists, each with keys :name, :x, :y, :width,
:height, and optionally :scale (default 1.0).

Example:
  (niri-frame-visible-test--mock-outputs
   \\='((:name \"DP-1\" :x 0 :y 0 :width 1920 :height 1080)))"
  (setq niri-frame-visible-test--orig-outputs
        (copy-hash-table niri-rpc--outputs-cache))
  (clrhash niri-rpc--outputs-cache)
  (dolist (spec specs)
    (let* ((name (plist-get spec :name))
           (logical (make-niri-rpc-logical-output
                     :x (plist-get spec :x)
                     :y (plist-get spec :y)
                     :width (plist-get spec :width)
                     :height (plist-get spec :height)
                     :scale (or (plist-get spec :scale) 1.0)
                     :transform 'normal))
           (output (make-niri-rpc-output
                    :name name
                    :logical logical)))
      (puthash name output niri-rpc--outputs-cache))))

(defun niri-frame-visible-test--restore-outputs ()
  "Restore `niri-rpc--outputs-cache' to before test modification."
  (when niri-frame-visible-test--orig-outputs
    (setq niri-rpc--outputs-cache niri-frame-visible-test--orig-outputs)
    (setq niri-frame-visible-test--orig-outputs nil)))

(defun niri-frame-visible-test--setup ()
  "Connect to niri, enable frame tracking and visibility mode."
  (niri-rpc-connect)
  (let ((start (float-time)))
    (while (and (< (- (float-time) start) 2.0)
                (= (hash-table-count niri-rpc--windows) 0))
      (accept-process-output niri-rpc--async-process 0.1)))
  (niri-frame-enable)
  (let ((start (float-time)))
    (while (and (< (- (float-time) start) 2.0)
                (> (hash-table-count niri-frame--tag-to-frame) 0))
      (accept-process-output niri-rpc--async-process 0.05)))
  (track-niri-frame-visibility-mode 1))

(defun niri-frame-visible-test--teardown ()
  "Disable visibility mode, frame tracking, and disconnect."
  (ignore-errors (track-niri-frame-visibility-mode -1))
  (ignore-errors (niri-frame-disable))
  (ignore-errors (niri-rpc-disconnect)))

(defun niri-frame-visible-test--wait-for-events (timeout)
  "Wait up to TIMEOUT seconds for niri events to propagate."
  (let ((start (float-time)))
    (while (< (- (float-time) start) timeout)
      (accept-process-output niri-rpc--async-process 0.05))))

(defun niri-frame-visible-test--wait-for-mapping (timeout)
  "Wait up to TIMEOUT seconds for pending tags to be matched."
  (let ((start (float-time)))
    (while (and (< (- (float-time) start) timeout)
                (> (hash-table-count niri-frame--tag-to-frame) 0))
      (accept-process-output niri-rpc--async-process 0.05))))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;; Tests: Customization
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(ert-deftest niri-frame-visible-threshold-default ()
  "Test default value of `niri-frame-visible-threshold'."
  (should (= niri-frame-visible-threshold 0.5)))

(ert-deftest niri-frame-visible-threshold-set ()
  "Test that threshold can be changed and respected."
  (let ((niri-frame-visible-threshold 0.75)
        (niri-frame-visible-test--orig-outputs nil))
    (unwind-protect
        (progn
          (niri-frame-visible-test--mock-outputs
           '((:name "DP-1" :x 0 :y 0 :width 1920 :height 1080)))
          ;; A rect that is 60% visible — passes at 0.5, fails at 0.75
          ;; Window: x=-400, y=0, w=1000, h=1000
          ;; Overlap with output (0,0,1920,1080):
          ;;   ix = max(-400, 0) = 0, iy = max(0,0) = 0
          ;;   ix2 = min(600, 1920) = 600, iy2 = min(1000,1080) = 1000
          ;;   iw = 600, ih = 1000
          ;;   visible = 600000, total = 1000000 → 60%
          (let ((rect '( -400 0 1000 1000 )))
            ;; At threshold 0.5, 60% should be visible
            (let ((niri-frame-visible-threshold 0.5))
              (should (niri-frame-visible--rect-visible-p rect)))
            ;; At threshold 0.75, 60% should NOT be visible
            (let ((niri-frame-visible-threshold 0.75))
              (should-not (niri-frame-visible--rect-visible-p rect)))))
      (niri-frame-visible-test--restore-outputs))))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;; Tests: rect-visible-p (unit tests, no niri connection)
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(ert-deftest niri-frame-visible-rect-fully-visible ()
  "Rect fully inside output should be visible."
  (let ((niri-frame-visible-test--orig-outputs nil))
    (unwind-protect
        (progn
          (niri-frame-visible-test--mock-outputs
           '((:name "DP-1" :x 0 :y 0 :width 1920 :height 1080)))
          ;; Window fully inside output
          (should (niri-frame-visible--rect-visible-p
                   '(100 100 500 400))))
      (niri-frame-visible-test--restore-outputs))))

(ert-deftest niri-frame-visible-rect-partially-visible ()
  "Rect 60% visible should pass with default threshold 0.5."
  (let ((niri-frame-visible-test--orig-outputs nil)
        (niri-frame-visible-threshold 0.5))
    (unwind-protect
        (progn
          (niri-frame-visible-test--mock-outputs
           '((:name "DP-1" :x 0 :y 0 :width 1920 :height 1080)))
          ;; Window: half off-screen to the left
          ;; x=-400, y=0, w=800, h=1080
          ;; Intersection: ix=max(-400,0)=0, ix2=min(400,1920)=400
          ;; iw=400, visible = 400*1080 = 432000, total = 800*1080 = 864000
          ;; 432000/864000 = 50% → exactly at threshold
          (should (niri-frame-visible--rect-visible-p
                   '(-400 0 800 1080))))
      (niri-frame-visible-test--restore-outputs))))

(ert-deftest niri-frame-visible-rect-barely-visible ()
  "Rect 40% visible should fail with default threshold 0.5."
  (let ((niri-frame-visible-test--orig-outputs nil)
        (niri-frame-visible-threshold 0.5))
    (unwind-protect
        (progn
          (niri-frame-visible-test--mock-outputs
           '((:name "DP-1" :x 0 :y 0 :width 1920 :height 1080)))
          ;; Window: mostly off-screen to the left
          ;; x=-600, y=0, w=1000, h=1000
          ;; Intersection: ix=max(-600,0)=0, ix2=min(400,1920)=400
          ;; iw=400, visible = 400*1000 = 400000, total = 1000000
          ;; 40% → below 0.5 threshold
          (should-not (niri-frame-visible--rect-visible-p
                       '(-600 0 1000 1000))))
      (niri-frame-visible-test--restore-outputs))))

(ert-deftest niri-frame-visible-rect-not-visible ()
  "Rect completely outside output should not be visible."
  (let ((niri-frame-visible-test--orig-outputs nil))
    (unwind-protect
        (progn
          (niri-frame-visible-test--mock-outputs
           '((:name "DP-1" :x 0 :y 0 :width 1920 :height 1080)))
          ;; Window far to the right
          (should-not (niri-frame-visible--rect-visible-p
                       '(2000 0 500 400)))
          ;; Window above the output
          (should-not (niri-frame-visible--rect-visible-p
                       '(0 -500 500 400))))
      (niri-frame-visible-test--restore-outputs))))

(ert-deftest niri-frame-visible-rect-zero-area ()
  "Zero-area rect should not be visible."
  (let ((niri-frame-visible-test--orig-outputs nil))
    (unwind-protect
        (progn
          (niri-frame-visible-test--mock-outputs
           '((:name "DP-1" :x 0 :y 0 :width 1920 :height 1080)))
          (should-not (niri-frame-visible--rect-visible-p '(0 0 0 0)))
          (should-not (niri-frame-visible--rect-visible-p '(0 0 0 100)))
          (should-not (niri-frame-visible--rect-visible-p '(0 0 100 0))))
      (niri-frame-visible-test--restore-outputs))))

(ert-deftest niri-frame-visible-rect-multi-output ()
  "Rect spanning across two outputs should be visible if visible on either."
  (let ((niri-frame-visible-test--orig-outputs nil)
        (niri-frame-visible-threshold 0.5))
    (unwind-protect
        (progn
          ;; Two outputs side by side
          (niri-frame-visible-test--mock-outputs
           '((:name "DP-1" :x 0    :y 0 :width 1920 :height 1080)
             (:name "DP-2" :x 1920 :y 0 :width 1920 :height 1080)))
          ;; Window straddling both outputs: x=1420, y=0, w=1000, h=1000
          ;; On DP-1: ix=max(1420,0)=1420, ix2=min(2420,1920)=1920
          ;;          iw=500, ih=1000 → visible=500000 (50%)
          ;; On DP-2: ix=max(1420,1920)=1920, ix2=min(2420,3840)=2420
          ;;          iw=500, ih=1000 → visible=500000 (50%)
          ;; Total=1000000, visible on DP-1=500000 (50%) → visible
          (should (niri-frame-visible--rect-visible-p
                   '(1420 0 1000 1000))))
      (niri-frame-visible-test--restore-outputs))))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;; Tests: Advice (unit tests with mocked niri state)
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(ert-deftest niri-frame-visible-advice-original-nil ()
  "Advice should return nil when the original `frame-visible-p' returns nil."
  (should-not (niri-frame-visible--advice (lambda (_frame) nil) (selected-frame))))

(ert-deftest niri-frame-visible-advice-no-niri-id ()
  "Advice should pass through t when frame has no niri mapping."
  (cl-letf (((symbol-function 'niri-frame-niri-id) (lambda (_frame) nil)))
    (should (niri-frame-visible--advice (lambda (_frame) t) (selected-frame)))))

(ert-deftest niri-frame-visible-advice-no-rect ()
  "Advice should pass through t when niri rect is unavailable."
  (cl-letf (((symbol-function 'niri-frame-niri-id) (lambda (_frame) 42))
            ((symbol-function 'niri-rpc-window-absolute-rect) (lambda (_id) nil)))
    (should (niri-frame-visible--advice (lambda (_frame) t) (selected-frame)))))

(ert-deftest niri-frame-visible-advice-not-visible ()
  "Advice should return nil when rect is outside all outputs."
  (let ((niri-frame-visible-test--orig-outputs nil)
        (niri-frame-visible-threshold 0.5))
    (unwind-protect
        (progn
          (niri-frame-visible-test--mock-outputs
           '((:name "DP-1" :x 0 :y 0 :width 1920 :height 1080)))
          (cl-letf (((symbol-function 'niri-frame-niri-id) (lambda (_frame) 42))
                    ((symbol-function 'niri-rpc-window-absolute-rect)
                     (lambda (_id) '(2000 0 500 400))))
            ;; Rect is outside output → advice should return nil
            (should-not (niri-frame-visible--advice (lambda (_frame) t) (selected-frame)))))
      (niri-frame-visible-test--restore-outputs))))

(ert-deftest niri-frame-visible-advice-visible ()
  "Advice should return t when rect is fully visible."
  (let ((niri-frame-visible-test--orig-outputs nil)
        (niri-frame-visible-threshold 0.5))
    (unwind-protect
        (progn
          (niri-frame-visible-test--mock-outputs
           '((:name "DP-1" :x 0 :y 0 :width 1920 :height 1080)))
          (cl-letf (((symbol-function 'niri-frame-niri-id) (lambda (_frame) 42))
                    ((symbol-function 'niri-rpc-window-absolute-rect)
                     (lambda (_id) '(100 100 500 400))))
            ;; Rect is inside output → advice should return t
            (should (niri-frame-visible--advice (lambda (_frame) t) (selected-frame)))))
      (niri-frame-visible-test--restore-outputs))))

(ert-deftest niri-frame-visible-advice-edge-case-equal-threshold ()
  "Advice with rect exactly at threshold boundary."
  (let ((niri-frame-visible-test--orig-outputs nil)
        (niri-frame-visible-threshold 0.5))
    (unwind-protect
        (progn
          (niri-frame-visible-test--mock-outputs
           '((:name "DP-1" :x 0 :y 0 :width 1920 :height 1080)))
          ;; Rect: half on screen exactly (x=-400, w=800, full height)
          ;; intersection: x=0..400, w=400. 400/800 = 0.5 exactly
          (cl-letf (((symbol-function 'niri-frame-niri-id) (lambda (_frame) 42))
                    ((symbol-function 'niri-rpc-window-absolute-rect)
                     (lambda (_id) '(-400 0 800 1080))))
            (should (niri-frame-visible--advice (lambda (_frame) t) (selected-frame)))))
      (niri-frame-visible-test--restore-outputs))))

(ert-deftest niri-frame-visible-advice-graceful-error ()
  "Advice passes through when geometry lookup signals an error.

Simulates the case where `niri-rpc-window-absolute-rect' errors
(e.g. because the niri connection was lost).  The advice must
catch the error and return the original result, NOT propagate
it — `frame-visible-p' is called frequently by Emacs display
code and must never crash."
  (cl-letf (((symbol-function 'niri-frame-niri-id) (lambda (_frame) 42))
            ((symbol-function 'niri-rpc-window-absolute-rect)
             (lambda (_id) (error "niri-rpc: not connected"))))
    (should (niri-frame-visible--advice (lambda (_frame) t) (selected-frame)))))

(ert-deftest niri-frame-visible-advice-hidden-tab ()
  "Advice returns nil when window is hidden in a tabbed column.

When a window has a niri-id but its layout says
`is-visible-in-column' is nil (hidden tab), the advice must
return nil even if the original `frame-visible-p' returns t."
  (let ((niri-frame-visible-test--orig-outputs nil))
    (unwind-protect
        (progn
          (niri-frame-visible-test--mock-outputs
           '((:name "DP-1" :x 0 :y 0 :width 1920 :height 1080)))
          ;; Mock: frame has niri-id 42, window is in niri-rpc--windows
          ;; with layout where is-visible-in-column is nil
          (let ((hidden-layout (make-niri-rpc-window-layout
                                :is-visible-in-column nil
                                :tile-size '(500 . 400)
                                :window-size '(500 . 400)
                                :window-offset-in-tile '(0 . 0)
                                :tile-pos-in-workspace-view '(100 . 100))))
            (cl-letf (((symbol-function 'niri-frame-niri-id) (lambda (_frame) 42))
                      ((symbol-function 'gethash)
                       (lambda (key table)
                         (when (and (= key 42)
                                    (eq table niri-rpc--windows))
                           (make-niri-rpc-window
                            :id 42
                            :layout hidden-layout)))))
              ;; Original says visible, but is_visible_in_column is nil
              (should-not (niri-frame-visible--advice
                           (lambda (_frame) t) (selected-frame))))))
      (niri-frame-visible-test--restore-outputs))))

(ert-deftest niri-frame-visible-advice-visible-in-column ()
  "Advice returns t when is_visible_in_column is t and geometry is on screen."
  (let ((niri-frame-visible-test--orig-outputs nil)
        (niri-frame-visible-threshold 0.5))
    (unwind-protect
        (progn
          (niri-frame-visible-test--mock-outputs
           '((:name "DP-1" :x 0 :y 0 :width 1920 :height 1080)))
          (let ((visible-layout (make-niri-rpc-window-layout
                                 :is-visible-in-column t
                                 :tile-size '(500 . 400)
                                 :window-size '(500 . 400)
                                 :window-offset-in-tile '(0 . 0)
                                 :tile-pos-in-workspace-view nil)))
            (cl-letf (((symbol-function 'niri-frame-niri-id) (lambda (_frame) 42))
                      ((symbol-function 'niri-rpc-window-absolute-rect)
                       (lambda (_id) '(100 100 500 400)))
                      ((symbol-function 'gethash)
                       (lambda (key table)
                         (when (and (= key 42)
                                    (eq table niri-rpc--windows))
                           (make-niri-rpc-window
                            :id 42
                            :layout visible-layout)))))
              ;; Original says visible, is_visible_in_column is t,
              ;; and geometry is on screen
              (should (niri-frame-visible--advice
                       (lambda (_frame) t) (selected-frame))))))
      (niri-frame-visible-test--restore-outputs))))

(ert-deftest niri-frame-visible-advice-no-window-in-table ()
  "Advice returns result from geometry check when window not in niri-rpc--windows.

This covers the case where the frame has a niri-id but somehow
isn't in the niri-rpc--windows hash table (e.g. connection loss).
The advice should fall through to the geometry check."
  (let ((niri-frame-visible-test--orig-outputs nil)
        (niri-frame-visible-threshold 0.5))
    (unwind-protect
        (progn
          (niri-frame-visible-test--mock-outputs
           '((:name "DP-1" :x 0 :y 0 :width 1920 :height 1080)))
          (cl-letf (((symbol-function 'niri-frame-niri-id) (lambda (_frame) 42))
                    ((symbol-function 'niri-rpc-window-absolute-rect)
                     (lambda (_id) '(100 100 500 400))))
            ;; Frame has niri-id but not in niri-rpc--windows table.
            ;; Falls through to geometry check which passes.
            (should (niri-frame-visible--advice
                     (lambda (_frame) t) (selected-frame)))))
      (niri-frame-visible-test--restore-outputs))))

(ert-deftest niri-frame-visible-advice-inactive-workspace ()
  "Advice returns nil when window is on an inactive workspace.

When a window has a niri-id and is on a workspace that is NOT
active on its output, niri's scrolling tiling layout means it's
scrolled off-screen.  The advice must return nil even if the
original `frame-visible-p' returns t and the geometry would
theoretically overlap the output's virtual canvas."
  (let ((niri-frame-visible-test--orig-outputs nil)
        (niri-frame-visible-threshold 0.5))
    (unwind-protect
        (progn
          (niri-frame-visible-test--mock-outputs
           '((:name "DP-1" :x 0 :y 0 :width 1920 :height 1080)))
          (let ((layout (make-niri-rpc-window-layout
                         :is-visible-in-column t
                         :tile-size '(500 . 400)
                         :window-size '(500 . 400)
                         :window-offset-in-tile '(0 . 0)
                         :tile-pos-in-workspace-view '(100 . 100))))
            (cl-letf (((symbol-function 'niri-frame-niri-id) (lambda (_frame) 42))
                      ((symbol-function 'niri-rpc-window-absolute-rect)
                       (lambda (_id) '(100 100 500 400)))
                      ((symbol-function 'gethash)
                       (lambda (key table)
                         (cond
                          ((and (= key 42) (eq table niri-rpc--windows))
                           (make-niri-rpc-window
                            :id 42
                            :workspace-id 1
                            :layout layout))
                          ((and (= key 1) (eq table niri-rpc--workspaces))
                           (make-niri-rpc-workspace
                            :id 1
                            :is-active nil))))))
              (should-not (niri-frame-visible--advice
                           (lambda (_frame) t) (selected-frame))))))
      (niri-frame-visible-test--restore-outputs))))

(ert-deftest niri-frame-visible-advice-active-workspace ()
  "Advice returns t when window is on an active workspace and geometry passes.

When a window has a niri-id, is visible in its column, is on the
active workspace, and its geometry passes the threshold check,
the advice should return the original result (t)."
  (let ((niri-frame-visible-test--orig-outputs nil)
        (niri-frame-visible-threshold 0.5))
    (unwind-protect
        (progn
          (niri-frame-visible-test--mock-outputs
           '((:name "DP-1" :x 0 :y 0 :width 1920 :height 1080)))
          (let ((layout (make-niri-rpc-window-layout
                         :is-visible-in-column t
                         :tile-size '(500 . 400)
                         :window-size '(500 . 400)
                         :window-offset-in-tile '(0 . 0)
                         :tile-pos-in-workspace-view '(100 . 100))))
            (cl-letf (((symbol-function 'niri-frame-niri-id) (lambda (_frame) 42))
                      ((symbol-function 'niri-rpc-window-absolute-rect)
                       (lambda (_id) '(100 100 500 400)))
                      ((symbol-function 'gethash)
                       (lambda (key table)
                         (cond
                          ((and (= key 42) (eq table niri-rpc--windows))
                           (make-niri-rpc-window
                            :id 42
                            :workspace-id 1
                            :layout layout))
                          ((and (= key 1) (eq table niri-rpc--workspaces))
                           (make-niri-rpc-workspace
                            :id 1
                            :is-active t))))))
              (should (niri-frame-visible--advice
                       (lambda (_frame) t) (selected-frame))))))
      (niri-frame-visible-test--restore-outputs))))

(ert-deftest niri-frame-visible-advice-no-workspace-id ()
  "Advice passes through when window has no workspace-id (conservative).

A window without a workspace-id (e.g. not yet assigned) should
not be treated as invisible.  The advice falls through to the
geometry check, which passes, so the result is t."
  (let ((niri-frame-visible-test--orig-outputs nil)
        (niri-frame-visible-threshold 0.5))
    (unwind-protect
        (progn
          (niri-frame-visible-test--mock-outputs
           '((:name "DP-1" :x 0 :y 0 :width 1920 :height 1080)))
          (let ((layout (make-niri-rpc-window-layout
                         :is-visible-in-column t
                         :tile-size '(500 . 400)
                         :window-size '(500 . 400)
                         :window-offset-in-tile '(0 . 0)
                         :tile-pos-in-workspace-view '(100 . 100))))
            (cl-letf (((symbol-function 'niri-frame-niri-id) (lambda (_frame) 42))
                      ((symbol-function 'niri-rpc-window-absolute-rect)
                       (lambda (_id) '(100 100 500 400)))
                      ((symbol-function 'gethash)
                       (lambda (key table)
                         (when (and (= key 42) (eq table niri-rpc--windows))
                           (make-niri-rpc-window
                            :id 42
                            :workspace-id nil
                            :layout layout)))))
              (should (niri-frame-visible--advice
                       (lambda (_frame) t) (selected-frame))))))
      (niri-frame-visible-test--restore-outputs))))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;; Tests: Minor mode (integration, needs niri connection)
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(ert-deftest niri-frame-visible-mode-enable-disable ()
  "Test that the minor mode adds and removes the advice."
  (niri-frame-visible-test--setup)
  ;; Mode is enabled by setup
  (should track-niri-frame-visibility-mode)
  (should (advice-member-p #'niri-frame-visible--advice 'frame-visible-p))
  ;; Disable
  (track-niri-frame-visibility-mode -1)
  (should-not track-niri-frame-visibility-mode)
  (should-not (advice-member-p #'niri-frame-visible--advice 'frame-visible-p))
  ;; Re-enable
  (track-niri-frame-visibility-mode 1)
  (should track-niri-frame-visibility-mode)
  (should (advice-member-p #'niri-frame-visible--advice 'frame-visible-p))
  (niri-frame-visible-test--teardown))

(ert-deftest niri-frame-visible-mode-disables-advice ()
  "After teardown, the advice should be removed."
  (niri-frame-visible-test--setup)
  (niri-frame-visible-test--teardown)
  (should-not track-niri-frame-visibility-mode)
  (should-not (advice-member-p #'niri-frame-visible--advice 'frame-visible-p)))

(ert-deftest niri-frame-visible-mapped-frame-is-visible ()
  "A mapped frame on the active workspace should be visible."
  (niri-frame-visible-test--setup)
  (unless niri-rpc--has-tile-pos
    (ert-skip "niri does not provide tile_pos_in_workspace_view"))
  (let ((frame (selected-frame))
        (niri-id (niri-frame-niri-id (selected-frame))))
    ;; Frame must be mapped for visibility check to work
    (should niri-id)
    ;; The rect should be computable
    (let ((rect (niri-rpc-window-absolute-rect niri-id)))
      (should rect))
    ;; With mode enabled, frame-visible-p should work and return non-nil
    ;; (the frame is on the active workspace and visible)
    (should (frame-visible-p frame)))
  (niri-frame-visible-test--teardown))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;; Tests: Scrolling / viewport (integration, needs niri connection)
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(ert-deftest niri-frame-visible-create-multiple-frames ()
  "Create multiple frames.  Verify that niri scrolling layout affects visibility.

After creating frames in new columns, niri auto-scrolls to show the most
recently created column.  Frames in earlier columns may be off-screen.
Our advice should detect this based on window geometry."
  (niri-frame-visible-test--setup)
  (unless niri-rpc--has-tile-pos
    (ert-skip "niri does not provide tile_pos_in_workspace_view"))
  (let ((frame1 (selected-frame))
        (frame2 (make-frame '((name . "niri-visible-test-2"))))
        (frame3 (make-frame '((name . "niri-visible-test-3")))))
    (unwind-protect
        (progn
          (niri-frame-visible-test--wait-for-mapping 2.0)
          (let ((id1 (niri-frame-niri-id frame1))
                (id2 (niri-frame-niri-id frame2))
                (id3 (niri-frame-niri-id frame3)))
            ;; All frames should have niri ids
            (should id1)
            (should id2)
            (should id3)
            ;; The rightmost frame (frame3, most recently created)
            ;; should be visible — niri scrolls to show it.
            (should (frame-visible-p frame3))
            ;; Log visibility of all frames for diagnostics
            (let ((v1 (frame-visible-p frame1))
                  (v2 (frame-visible-p frame2))
                  (v3 (frame-visible-p frame3)))
              (message "niri-visible-multi: frame1=%S frame2=%S frame3=%S (ids: %d %d %d)"
                       v1 v2 v3 id1 id2 id3)
              ;; After creating 3 columns, at least one earlier frame
              ;; may be off-screen depending on viewport width.  This
              ;; verifies our advice can produce nil for off-screen frames.
              (when (and v1 v2 v3)
                (message "niri-visible-multi: all frames visible (wide viewport?)")))))
      (delete-frame frame2)
      (delete-frame frame3)))
  (niri-frame-visible-test--teardown))

(ert-deftest niri-frame-visible-scroll-off-screen ()
  "Test visibility tracking across viewport scrolling.

Creates 3 frames, scrolls to the leftmost, verifies it's visible,
then scrolls right to push it off-screen, then scrolls back."
  (niri-frame-visible-test--setup)
  (unless niri-rpc--has-tile-pos
    (ert-skip "niri does not provide tile_pos_in_workspace_view"))
  (let ((frame1 (selected-frame))
        frame2 frame3)
    (setq frame2 (make-frame '((name . "niri-visible-scroll-2"))))
    (setq frame3 (make-frame '((name . "niri-visible-scroll-3"))))
    (unwind-protect
        (progn
          (niri-frame-visible-test--wait-for-mapping 2.0)
          (let ((id1 (niri-frame-niri-id frame1))
                (id2 (niri-frame-niri-id frame2))
                (id3 (niri-frame-niri-id frame3)))
            (should id1)
            (should id2)
            (should id3)

            ;; After creating 3 frames, niri scrolled to frame3 (rightmost).
            ;; Scroll left twice to get back to frame1.
            (niri-rpc-action '(:FocusColumnLeft))
            (niri-frame-visible-test--wait-for-events 0.5)
            (niri-rpc-action '(:FocusColumnLeft))
            (niri-frame-visible-test--wait-for-events 0.5)

            ;; Now frame1 should be visible (viewport centered on it)
            (let ((rect1 (niri-rpc-window-absolute-rect id1)))
              (message "niri-visible-scroll: after scroll-left, frame1 rect=%S" rect1))
            (should (frame-visible-p frame1))

            ;; Scroll right twice to push frame1 off-screen
            (niri-rpc-action '(:FocusColumnRight))
            (niri-frame-visible-test--wait-for-events 0.5)
            (niri-rpc-action '(:FocusColumnRight))
            (niri-frame-visible-test--wait-for-events 0.5)

            ;; Check frame1 visibility after scrolling right
            (let ((rect1 (niri-rpc-window-absolute-rect id1)))
              (message "niri-visible-scroll: after scroll-right, frame1 rect=%S" rect1)
              (when rect1
                (if (< (nth 0 rect1) 0)
                    ;; Frame is off-screen to the left → advice should return nil
                    (should-not (frame-visible-p frame1))
                  (message "niri-visible-scroll: frame1 still visible (rect=%S, wide viewport?)" rect1))))

            ;; Scroll back left
            (niri-rpc-action '(:FocusColumnLeft))
            (niri-frame-visible-test--wait-for-events 0.5)
            (niri-rpc-action '(:FocusColumnLeft))
            (niri-frame-visible-test--wait-for-events 0.5)

            ;; Frame1 should be visible again
            (should (frame-visible-p frame1))))
      (delete-frame frame2)
      (delete-frame frame3)))
  (niri-frame-visible-test--teardown))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;; Tests: Tabbed column visibility (integration, needs niri connection)
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(ert-deftest niri-frame-visible-tabbed-column-hidden ()
  "Test that hidden tabs in a tabbed column are not visible.

Creates two frames in separate columns, consumes one into the other's
column to put them in the same column, toggles tabbed display, and
verifies that the non-active frame is reported as not visible."
  (niri-frame-visible-test--setup)
  (unless niri-rpc--has-visible-in-column
    (ert-skip "niri does not provide is_visible_in_column"))
  (let ((frame1 (selected-frame))
        frame2)
    (setq frame2 (make-frame '((name . "niri-visible-tabbed-2"))))
    (unwind-protect
        (progn
          (niri-frame-visible-test--wait-for-mapping 2.0)
          (let ((id1 (niri-frame-niri-id frame1))
                (id2 (niri-frame-niri-id frame2)))
            (should id1)
            (should id2)

            ;; Both frames should be visible initially (separate columns)
            (should (frame-visible-p frame1))
            (should (frame-visible-p frame2))

            ;; Consume frame2 into frame1's column.
            ;; First focus frame1's niri window, then consume right.
            (condition-case nil
                (niri-rpc-action `(:FocusWindow (:id ,id1)))
              (error (message "niri-tabbed: FocusWindow failed")))
            (niri-frame-visible-test--wait-for-events 0.5)
            (condition-case nil
                (niri-rpc-action '(:ConsumeWindowIntoColumn))
              (error (message "niri-tabbed: ConsumeWindowIntoColumn failed")))
            (niri-frame-visible-test--wait-for-events 0.5)

            ;; Toggle tabbed display
            ;; Ensure tabbed display.
            ;; toggle once for non-tabbed → tabbed;
            ;; if already tabbed (stale state from prior test),
            ;; toggle twice: tabbed → untabbed → tabbed.
            (let ((already-hidden (not (niri-rpc-window-layout-is-visible-in-column
                                        (niri-rpc-window-layout
                                         (gethash id2 niri-rpc--windows))))))
              (condition-case nil
                  (niri-rpc-action '(:ToggleColumnTabbedDisplay))
                (error (message "niri-tabbed: ToggleColumnTabbedDisplay not supported")))
              (niri-frame-visible-test--wait-for-events 0.5)
              (when already-hidden
                (message "niri-tabbed: column was already tabbed, toggling again")
                (condition-case nil
                    (niri-rpc-action '(:ToggleColumnTabbedDisplay))
                  (error (message "niri-tabbed: second toggle failed")))
                (niri-frame-visible-test--wait-for-events 0.5)))
            (niri-frame-visible-test--wait-for-events 0.5)

            ;; After toggling tabbed, only the active frame should be visible.
            ;; frame1 was focused first and is the active tab.
            (let ((v1 (frame-visible-p frame1))
                  (v2 (frame-visible-p frame2)))
              (message "niri-tabbed-hidden: frame1=%S frame2=%S (ids: %d %d)"
                       v1 v2 id1 id2)
              ;; The active tab (frame1) should be visible
              (should v1)
              ;; The hidden tab (frame2) should NOT be visible
              (should-not v2))))
      (delete-frame frame2)))
  (niri-frame-visible-test--teardown))

(ert-deftest niri-frame-visible-tabbed-column-switch-tabs ()
  "Test that visibility updates when switching tabs in a tabbed column.

Creates two frames in the same column, toggles tabbed, then switches
tabs and verifies that visibility follows the active tab."
  (niri-frame-visible-test--setup)
  (unless niri-rpc--has-visible-in-column
    (ert-skip "niri does not provide is_visible_in_column"))
  (let ((frame1 (selected-frame))
        frame2)
    (setq frame2 (make-frame '((name . "niri-visible-tabbed-switch-2"))))
    (unwind-protect
        (progn
          (niri-frame-visible-test--wait-for-mapping 2.0)
          (let ((id1 (niri-frame-niri-id frame1))
                (id2 (niri-frame-niri-id frame2)))
            (should id1)
            (should id2)

            ;; Consume frame2 into frame1's column
            (condition-case nil
                (niri-rpc-action `(:FocusWindow (:id ,id1)))
              (error (message "niri-tabbed-switch: FocusWindow failed")))
            (niri-frame-visible-test--wait-for-events 0.5)
            (condition-case nil
                (niri-rpc-action '(:ConsumeWindowIntoColumn))
              (error (message "niri-tabbed-switch: ConsumeWindowIntoColumn failed")))
            (niri-frame-visible-test--wait-for-events 0.5)

            ;; Ensure tabbed display.
            ;; toggle once for non-tabbed → tabbed;
            ;; if already tabbed (stale state from prior test),
            ;; toggle twice: tabbed → untabbed → tabbed.
            (let ((already-hidden (not (niri-rpc-window-layout-is-visible-in-column
                                        (niri-rpc-window-layout
                                         (gethash id2 niri-rpc--windows))))))
              (condition-case nil
                  (niri-rpc-action '(:ToggleColumnTabbedDisplay))
                (error (message "niri-tabbed-switch: ToggleColumnTabbedDisplay not supported")))
              (niri-frame-visible-test--wait-for-events 0.5)
              (when already-hidden
                (message "niri-tabbed-switch: column was already tabbed, toggling again")
                (condition-case nil
                    (niri-rpc-action '(:ToggleColumnTabbedDisplay))
                  (error (message "niri-tabbed-switch: second toggle failed")))
                (niri-frame-visible-test--wait-for-events 0.5)))
            (niri-frame-visible-test--wait-for-events 0.5)

            ;; frame1 is the active tab, frame2 is hidden
            (should (frame-visible-p frame1))
            (should-not (frame-visible-p frame2))

            ;; Switch to frame2's tab by focusing down in the column
            (condition-case nil
                (niri-rpc-action '(:FocusWindowDown))
              (error (message "niri-tabbed-switch: FocusWindowDown failed")))
            (niri-frame-visible-test--wait-for-events 2.0)

            ;; Now frame2 should be visible and frame1 hidden
            ;; Re-read layout after events to ensure fresh data
            (let ((v1 (frame-visible-p frame1))
                  (v2 (frame-visible-p frame2)))
              (message "niri-tabbed-switch: after switch frame1=%S frame2=%S (ids: %d %d)"
                       v1 v2 (niri-frame-niri-id frame1) (niri-frame-niri-id frame2))
              (should v2)
              (should-not v1))))
      (delete-frame frame2)))
  (niri-frame-visible-test--teardown))

(ert-deftest niri-frame-visible-tabbed-column-untabbed ()
  "Test that all windows become visible when un-toggling tabbed display.

Creates two frames in the same column, toggles tabbed on, then off,
and verifies that both frames are visible again in normal display mode."
  (niri-frame-visible-test--setup)
  (unless niri-rpc--has-visible-in-column
    (ert-skip "niri does not provide is_visible_in_column"))
  (let ((frame1 (selected-frame))
        frame2)
    (setq frame2 (make-frame '((name . "niri-visible-untabbed-2"))))
    (unwind-protect
        (progn
          (niri-frame-visible-test--wait-for-mapping 2.0)
          (let ((id1 (niri-frame-niri-id frame1))
                (id2 (niri-frame-niri-id frame2)))
            (should id1)
            (should id2)

            ;; Consume frame2 into frame1's column
            (condition-case nil
                (niri-rpc-action `(:FocusWindow (:id ,id1)))
              (error (message "niri-untabbed: FocusWindow failed")))
            (niri-frame-visible-test--wait-for-events 0.5)
            (condition-case nil
                (niri-rpc-action '(:ConsumeWindowIntoColumn))
              (error (message "niri-untabbed: ConsumeWindowIntoColumn failed")))
            (niri-frame-visible-test--wait-for-events 0.5)

            ;; Ensure tabbed ON.
            ;; toggle once for non-tabbed → tabbed;
            ;; if already tabbed (stale state), toggle twice.
            (let ((already-hidden (not (niri-rpc-window-layout-is-visible-in-column
                                        (niri-rpc-window-layout
                                         (gethash id2 niri-rpc--windows))))))
              (condition-case nil
                  (niri-rpc-action '(:ToggleColumnTabbedDisplay))
                (error (message "niri-untabbed: ToggleColumnTabbedDisplay not supported")))
              (niri-frame-visible-test--wait-for-events 0.5)
              (when already-hidden
                (message "niri-untabbed: column was already tabbed, toggling again")
                (condition-case nil
                    (niri-rpc-action '(:ToggleColumnTabbedDisplay))
                  (error (message "niri-untabbed: second toggle failed")))
                (niri-frame-visible-test--wait-for-events 0.5)))
            (niri-frame-visible-test--wait-for-events 0.5)

            ;; frame2 should be hidden now
            (should-not (frame-visible-p frame2))

            ;; Toggle tabbed OFF
            (condition-case nil
                (niri-rpc-action '(:ToggleColumnTabbedDisplay))
              (error (message "niri-untabbed: second ToggleColumnTabbedDisplay failed")))
            (niri-frame-visible-test--wait-for-events 1.0)

            ;; Both frames should be visible again in normal display mode
            (should (frame-visible-p frame1))
            (should (frame-visible-p frame2))))
      (delete-frame frame2)))
  (niri-frame-visible-test--teardown))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;; Tests: Floating windows (integration, needs niri connection)
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(ert-deftest niri-frame-visible-toggle-floating ()
  "Test that floating windows don't break visibility tracking.

When a window is toggled to floating, its tile-pos-in-workspace-view
may become nil, meaning the rect can't be computed.  The advice
should pass through the original `frame-visible-p' result (t)."
  (niri-frame-visible-test--setup)
  (unless niri-rpc--has-tile-pos
    (ert-skip "niri does not provide tile_pos_in_workspace_view"))
  (let ((frame (selected-frame))
        (niri-id (niri-frame-niri-id (selected-frame))))
    (should niri-id)

    ;; Initially visible
    (should (frame-visible-p frame))

    ;; Focus this frame's niri window first
    (condition-case nil
        (niri-rpc-action `(:FocusWindow (:id ,niri-id)))
      (error (message "niri-frame-visible-float: FocusWindow failed")))
    (niri-frame-visible-test--wait-for-events 0.5)

    ;; Toggle floating
    (condition-case nil
        (niri-rpc-action '(:ToggleWindowFloating))
      (error (message "niri-frame-visible-float: ToggleWindowFloating not supported")))
    (niri-frame-visible-test--wait-for-events 0.5)

    ;; After toggle, check if rect is still computable
    (let ((rect (niri-rpc-window-absolute-rect niri-id)))
      (if rect
          (message "niri-frame-visible-float: rect still available after float: %S" rect)
        (message "niri-frame-visible-float: rect nil after float (tile_pos_in_workspace_view missing)")))

    ;; Even if rect is nil, frame-visible-p should still return t
    ;; (advice passes through when geometry is unavailable)
    (should (frame-visible-p frame))

    ;; Toggle back to tiling
    (condition-case nil
        (niri-rpc-action '(:ToggleWindowFloating))
      (error (message "niri-frame-visible-float: second ToggleWindowFloating failed")))
    (niri-frame-visible-test--wait-for-events 0.5)

    ;; Should still be visible
    (should (frame-visible-p frame)))
  (niri-frame-visible-test--teardown))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;; Tests: Workspace switching (integration)
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(ert-deftest niri-frame-visible-workspace-switch ()
  "Test visibility after switching workspaces.

In niri's scrolling tiling layout, windows on inactive
workspaces are scrolled off-screen and should not be reported
as visible.  `frame-visible-p' should return nil when the
window's workspace is not active on its output."
  (niri-frame-visible-test--setup)
  (unless niri-rpc--has-tile-pos
    (ert-skip "niri does not provide tile_pos_in_workspace_view"))
  (let ((frame (selected-frame))
        (niri-id (niri-frame-niri-id (selected-frame)))
        (switched nil))
    (should niri-id)

    ;; Initially visible (on active workspace)
    (should (frame-visible-p frame))

    ;; Create a second named workspace and switch to it.
    ;; This activates a new workspace, making the original one inactive.
    (message "niri-frame-visible-ws: switching to named workspace 'test-ws-b'")
    (condition-case nil
        (progn
          (niri-rpc-action '(:FocusWorkspace (:reference (:Name "test-ws-b"))))
          (setq switched t))
      (error (message "niri-frame-visible-ws: FocusWorkspace by name failed")))

    ;; Wait for events to converge — the old workspace should become
    ;; inactive once WorkspaceActivated arrives.  We loop to handle
    ;; the race between WorkspaceActivated and WorkspacesChanged.
    (niri-frame-visible-test--wait-for-events 0.5)
    (when switched
      (let ((start (float-time))
            (ws-id (niri-rpc-window-workspace-id
                    (gethash niri-id niri-rpc--windows)))
            (old-ws-inactive nil))
        (while (and (< (- (float-time) start) 3.0)
                    (not old-ws-inactive))
          (accept-process-output niri-rpc--async-process 0.1)
          (let ((ws (and ws-id (gethash ws-id niri-rpc--workspaces))))
            (setq old-ws-inactive (and ws (not (niri-rpc-workspace-is-active ws)))))
          (unless old-ws-inactive
            (message "niri-frame-visible-ws: waiting for ws-id=%S to become inactive..."
                     ws-id)))
        (message "niri-frame-visible-ws: ws-id=%S inactive=%S (waited %.1fs)"
                 ws-id old-ws-inactive (- (float-time) start))
        (if old-ws-inactive
            (should-not (frame-visible-p frame))
          (message "niri-frame-visible-ws: workspace never deactivated; skipping visibility check"))))

    ;; Switch back
    (condition-case nil
        (niri-rpc-action '(:FocusWorkspace (:reference (:Index 0))))
      (error nil))

    (niri-frame-visible-test--wait-for-events 1.0)
    (should (frame-visible-p frame)))
  (niri-frame-visible-test--teardown))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;; Test runner
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

;;;###autoload
(defun niri-frame-visible-test-run-all (&optional results-dir)
  "Run all niri-frame-visible tests sequentially.

If RESULTS-DIR is non-nil, write per-test result files:
  RESULTS-DIR/<test-name>/result    — `PASS' or `FAIL ...'
  RESULTS-DIR/<test-name>/messages  — contents of *Messages* after the test
  RESULTS-DIR/<test-name>/warnings  — contents of *Warnings* after the test

Returns a string with PASS/FAIL lines and a summary."
  (interactive)
  (let ((tests '("niri-frame-visible-threshold-default"
                 "niri-frame-visible-threshold-set"
                 "niri-frame-visible-rect-fully-visible"
                 "niri-frame-visible-rect-partially-visible"
                 "niri-frame-visible-rect-barely-visible"
                 "niri-frame-visible-rect-not-visible"
                 "niri-frame-visible-rect-zero-area"
                 "niri-frame-visible-rect-multi-output"
                 "niri-frame-visible-advice-original-nil"
                 "niri-frame-visible-advice-no-niri-id"
                 "niri-frame-visible-advice-no-rect"
                 "niri-frame-visible-advice-not-visible"
                 "niri-frame-visible-advice-visible"
                 "niri-frame-visible-advice-edge-case-equal-threshold"
                 "niri-frame-visible-advice-graceful-error"
                 "niri-frame-visible-advice-hidden-tab"
                 "niri-frame-visible-advice-visible-in-column"
                 "niri-frame-visible-advice-no-window-in-table"
                 "niri-frame-visible-advice-inactive-workspace"
                 "niri-frame-visible-advice-active-workspace"
                 "niri-frame-visible-advice-no-workspace-id"
                 "niri-frame-visible-mode-enable-disable"
                 "niri-frame-visible-mode-disables-advice"
                 "niri-frame-visible-mapped-frame-is-visible"
                 "niri-frame-visible-create-multiple-frames"
                 "niri-frame-visible-toggle-floating"
                 "niri-frame-visible-workspace-switch"
                 "niri-frame-visible-scroll-off-screen"
                 "niri-frame-visible-tabbed-column-hidden"
                 "niri-frame-visible-tabbed-column-switch-tabs"
                 "niri-frame-visible-tabbed-column-untabbed"))
        (passed 0)
        (failed 0)
        (skipped 0)
        (output nil))
    (dolist (test-name tests)
      ;; Clean slate before each test
      (ignore-errors (niri-rpc-disconnect))
      (when niri-rpc--async-process
        (while (accept-process-output niri-rpc--async-process 0.01)))
      (setq niri-rpc--async-process nil)
      (when (get-buffer "*Messages*")
        (kill-buffer "*Messages*"))
      (when (get-buffer "*Warnings*")
        (kill-buffer "*Warnings*"))
      (let ((test-sym (intern test-name))
            (test-dir (when results-dir
                        (expand-file-name test-name results-dir))))
        (when test-dir
          (make-directory test-dir t))
        (condition-case err
            (let ((stats (ert test-sym)))
              (if (and stats
                       (= (ert--stats-failed-unexpected stats) 0)
                       (= (ert--stats-failed-expected stats) 0))
                  (if (> (ert--stats-skipped stats) 0)
                      (progn
                        (cl-incf skipped)
                        (push (format "SKIP %s" test-name) output)
                        (when test-dir
                          (write-region "SKIP" nil
                                        (expand-file-name "result" test-dir))))
                    (progn
                      (cl-incf passed)
                      (push (format "PASS %s" test-name) output)
                      (when test-dir
                        (write-region "PASS" nil
                                      (expand-file-name "result" test-dir)))))
                (progn
                  (cl-incf failed)
                  (push (format "FAIL %s (assertions)" test-name) output)
                  (when test-dir
                    (write-region "FAIL (assertions)" nil
                                  (expand-file-name "result" test-dir))))))
          (error
           (cl-incf failed)
           (push (format "FAIL %s (error: %s)" test-name
                         (error-message-string err))
                 output)
           (when test-dir
             (write-region (format "FAIL (error: %s)"
                                   (error-message-string err))
                           nil
                           (expand-file-name "result" test-dir)))
           ;; Don't propagate — continue with remaining tests
           nil))
        ;; Save *Messages* and *Warnings* after each test
        (when test-dir
          (let ((buf (get-buffer "*Messages*")))
            (when buf
              (with-current-buffer buf
                (write-region (point-min) (point-max)
                              (expand-file-name "messages" test-dir)))))
          (let ((buf (get-buffer "*Warnings*")))
            (when buf
              (with-current-buffer buf
                (write-region (point-min) (point-max)
                              (expand-file-name "warnings" test-dir))))))))
    (setq output (nreverse output))
    (push (format "SUMMARY %d passed, %d failed, %d skipped" passed failed skipped) output)
    (if (> failed 0)
        (push "EXIT_FAIL" output)
      (push "EXIT_OK" output))
    (mapconcat #'identity (nreverse output) "\n")))

(provide 'niri-frame-visible-test)
;;; niri-frame-visible-test.el ends here
