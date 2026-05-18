;;; niri-frame-test.el --- Integration tests for niri-frame  -*- lexical-binding: t -*-

(require 'ert)
(require 'niri-rpc (expand-file-name "niri-rpc.el"
                                     (file-name-directory
                                      (or load-file-name buffer-file-name))))
(require 'niri-frame (expand-file-name "niri-frame.el"
                                       (file-name-directory
                                        (or load-file-name buffer-file-name))))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;; Helpers
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(defun niri-frame-test--setup ()
  "Connect to niri, enable frame tracking, and wait for initial mapping."
  (niri-rpc-connect)
  ;; Wait for initial event-stream state to populate
  (let ((start (float-time)))
    (while (and (< (- (float-time) start) 2.0)
                (= (hash-table-count niri-rpc--windows) 0))
      (accept-process-output niri-rpc--async-process 0.1)))
  (niri-frame-enable)
  ;; Brief flush to let GDK/Wayland update propagate
  (sit-for 0.1)
  ;; Wait for pending frames to become mapped (niri emits
  ;; WindowOpenedOrChanged when it sees our title changes)
  (let ((start (float-time)))
    (while (and (< (- (float-time) start) 3.0)
                (niri-frame-pending-frames))
      (accept-process-output niri-rpc--async-process 0.1))))

(defun niri-frame-test--teardown ()
  "Disable frame tracking and disconnect from niri."
  (ignore-errors (niri-frame-disable))
  (ignore-errors (niri-rpc-disconnect)))

(defun niri-frame-test--wait-for-mapping (timeout)
  "Wait up to TIMEOUT seconds for all pending frames to be mapped."
  (let ((start (float-time)))
    ;; Give the Wayland connection a chance to flush by sitting briefly
    (sit-for 0.05)
    (while (and (< (- (float-time) start) timeout)
                (niri-frame-pending-frames))
      (accept-process-output niri-rpc--async-process 0.1))))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;; Tests: Enable / disable
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(ert-deftest niri-frame-enable-disable ()
  "Test that frame tracking can be enabled and disabled cleanly."
  (niri-frame-test--setup)
  (should niri-frame--enabled)
  (should (= (length (niri-frame-pending-frames)) 0))
  (niri-frame-test--teardown)
  (should-not niri-frame--enabled)
  (should-not (memq #'niri-frame--on-frame-created after-make-frame-functions))
  (should-not (memq #'niri-frame--on-frame-deleted delete-frame-functions))
  (should-not (memq #'niri-frame--on-niri-event niri-rpc-event-hook)))

(ert-deftest niri-frame-enable-requires-connection ()
  "Test that enable signals an error when not connected."
  (should-error (niri-frame-enable)))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;; Tests: Existing frame mapping
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(ert-deftest niri-frame-existing-frame-mapped ()
  "Test that the existing Emacs frame is mapped to a niri window."
  (niri-frame-test--setup)
  (let ((niri-id (niri-frame-niri-id (selected-frame))))
    (should niri-id)
    (should (integerp niri-id))
    (should (> niri-id 0)))
  ;; Reverse lookup should return the same frame
  (let* ((niri-id (niri-frame-niri-id (selected-frame)))
         (frame (niri-frame-get-frame niri-id)))
    (should frame)
    (should (frame-live-p frame)))
  (niri-frame-test--teardown))

(ert-deftest niri-frame-frames-alist ()
  "Test that niri-frame-frames returns valid mappings."
  (niri-frame-test--setup)
  (let ((frames (niri-frame-frames)))
    (should frames)
    (should (listp frames))
    (dolist (pair frames)
      (should (frame-live-p (car pair)))
      (should (integerp (cdr pair)))
      (should (> (cdr pair) 0))))
  (niri-frame-test--teardown))

(ert-deftest niri-frame-no-pending-after-mapping ()
  "Test that no frames remain pending after mapping completes."
  (niri-frame-test--setup)
  (let ((pending (niri-frame-pending-frames)))
    (should-not pending))
  (niri-frame-test--teardown))

(ert-deftest niri-frame-title-has-zws-encoding ()
  "Test that the frame title contains zero-width encoding after enable."
  (niri-frame-test--setup)
  (let ((title (frame-parameter (selected-frame) 'name)))
    (should title)
    ;; The title should end with zero-width characters encoding our frame-id
    (let ((id (niri-frame--frame-id-decode title)))
      (should id)
      (should (= id (frame-id (selected-frame))))))
  (niri-frame-test--teardown))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;; Tests: Frame creation
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(ert-deftest niri-frame-new-frame-mapped ()
  "Test that a newly created frame gets mapped to its niri window."
  (niri-frame-test--setup)
  (sit-for 0.1)  ; let Wayland messages from enable propagate
  (let* ((count-before (length (niri-frame-frames)))
         (new-frame (make-frame '((name . "niri-frame-test-temp")))))
    (unwind-protect
        (progn
          ;; Wait for niri to emit WindowOpenedOrChanged and our hook to match
          (niri-frame-test--wait-for-mapping 2.0)
          ;; After mapping, the frame should be in the mappings
          (let ((niri-id (niri-frame-niri-id new-frame)))
            (should niri-id)
            (should (integerp niri-id))
            ;; The reverse lookup works
            (should (eq (niri-frame-get-frame niri-id) new-frame))
            ;; Title should contain zero-width encoding
            (let ((title (frame-parameter new-frame 'name)))
              (should (niri-frame--frame-id-decode title))))
          ;; Total mapped frames should have increased
          (should (= (length (niri-frame-frames)) (1+ count-before))))
      (delete-frame new-frame)))
  (niri-frame-test--teardown))

(ert-deftest niri-frame-new-frame-pending-then-mapped ()
  "Test the pending → mapped lifecycle of a new frame."
  (niri-frame-test--setup)
  (sit-for 0.1)
  (let ((new-frame (make-frame '((name . "niri-frame-test-lifecycle")))))
    (unwind-protect
        (progn
          ;; Immediately after creation, it should be pending
          (let ((pending (niri-frame-pending-frames)))
            (should (memq new-frame pending)))
          ;; The title should already have zero-width encoding
          (let ((title (frame-parameter new-frame 'name)))
            (should (niri-frame--frame-id-decode title)))
          ;; After waiting, it should no longer be pending
          (niri-frame-test--wait-for-mapping 2.0)
          (should-not (memq new-frame (niri-frame-pending-frames)))
          ;; And it should be in the mappings
          (should (niri-frame-niri-id new-frame)))
      (delete-frame new-frame)))
  (niri-frame-test--teardown))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;; Tests: Frame deletion cleanup
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(ert-deftest niri-frame-delete-clears-mappings ()
  "Test that deleting a frame removes its niri window mappings."
  (niri-frame-test--setup)
  (sit-for 0.1)
  (let ((new-frame (make-frame '((name . "niri-frame-test-delete"))))
        niri-id)
    ;; Wait for mapping
    (niri-frame-test--wait-for-mapping 2.0)
    (setq niri-id (niri-frame-niri-id new-frame))
    (should niri-id)
    ;; Delete the frame
    (delete-frame new-frame)
    ;; The mapping should be gone
    (should-not (niri-frame-get-frame niri-id))
    ;; The frame should not appear in the mappings
    (let ((frames (niri-frame-frames)))
      (should-not (assq new-frame frames))))
  (niri-frame-test--teardown))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;; Tests: Explicit name handling
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(ert-deftest niri-frame-explicit-name-has-encoding ()
  "Test that frames with explicit names get zero-width encoding.

When a frame's name is set explicitly (bypassing frame-title-format),
the modify-frame-parameters advice appends the encoding to the
title parameter."
  (niri-frame-test--setup)
  (sit-for 0.1)
  (let* ((frame (selected-frame))
         (custom "My Custom Emacs Title"))
    (set-frame-parameter frame 'name custom)
    (let ((title (frame-parameter frame 'name)))
      (should title)
      (let ((id (niri-frame--frame-id-decode title)))
        (should id)
        (should (= id (frame-id frame))))))
  (niri-frame-test--teardown))

(ert-deftest niri-frame-explicit-name-clear-removes-encoding-via-title ()
  "Test that clearing an explicit name lets frame-title-format take over.

When name is cleared, title is also cleared so the encoding comes
from frame-title-format again."
  (niri-frame-test--setup)
  (sit-for 0.1)
  (let ((frame (selected-frame)))
    (set-frame-parameter frame 'name "temp")
    (let ((title-with-name (frame-parameter frame 'name)))
      (should (niri-frame--frame-id-decode title-with-name)))
    ;; Clear name
    (set-frame-parameter frame 'name nil)
    (let ((title-after (frame-parameter frame 'name)))
      ;; After clearing name, frame-title-format provides the title
      ;; (which includes the encoding suffix)
      (should title-after)
      (should (niri-frame--frame-id-decode title-after))))
  (niri-frame-test--teardown))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;; Tests: Zero-width encoding and decoding (unit tests, no connection needed)
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(ert-deftest niri-frame-zws-encode-format ()
  "Test that frame-id encoding produces only zero-width chars."
  (let ((encoded (niri-frame--frame-id-encode 42)))
    (should (stringp encoded))
    (should (> (length encoded) 0))
    ;; All characters should be ZWNJ or ZWJ
    (dolist (c (append encoded nil))
      (should (or (eq c #x200C) (eq c #x200D))))))

(ert-deftest niri-frame-zws-encode-decode-roundtrip ()
  "Test that encode then decode returns the original frame-id."
  (dolist (id '(0 1 2 5 42 256 1337 99999))
    (let* ((encoded (niri-frame--frame-id-encode id))
           (title (concat "Some Buffer — Emacs" encoded)))
      (should (= (niri-frame--frame-id-decode title) id)))))

(ert-deftest niri-frame-zws-encode-zero ()
  "Test encoding and decoding of frame-id 0."
  (let ((encoded (niri-frame--frame-id-encode 0)))
    (should (> (length encoded) 0))
    (should (= (niri-frame--frame-id-decode encoded) 0))))

(ert-deftest niri-frame-zws-decode-no-encoding ()
  "Test that titles without zero-width encoding return nil."
  (should-not (niri-frame--frame-id-decode "plain title"))
  (should-not (niri-frame--frame-id-decode "buffer.txt — Emacs"))
  (should-not (niri-frame--frame-id-decode "")))

(ert-deftest niri-frame-zws-decode-nil-title ()
  "Test that nil titles are handled safely."
  (should-not (niri-frame--frame-id-decode nil)))

(ert-deftest niri-frame-zws-id-suffix-uses-selected-frame ()
  "Test that niri-frame--id-suffix encodes the correct frame-id."
  (with-selected-frame (selected-frame)
    (let ((suffix (niri-frame--id-suffix))
          (expected (niri-frame--frame-id-encode (frame-id))))
      (should (string= suffix expected)))))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;; Tests: Bidirectional lookup consistency
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(ert-deftest niri-frame-bidirectional-consistency ()
  "Test that the bidirectional mapping is consistent."
  (niri-frame-test--setup)
  (let ((frames (niri-frame-frames)))
    (dolist (pair frames)
      (let ((frame (car pair))
            (niri-id (cdr pair)))
        ;; Forward lookup
        (should (= (niri-frame-niri-id frame) niri-id))
        ;; Reverse lookup
        (should (eq (niri-frame-get-frame niri-id) frame)))))
  (niri-frame-test--teardown))

(ert-deftest niri-frame-get-frame-missing ()
  "Test that niri-frame-get-frame returns nil for unknown ids."
  (niri-frame-test--setup)
  (should-not (niri-frame-get-frame 99999999))
  (niri-frame-test--teardown))

(ert-deftest niri-frame-niri-id-missing ()
  "Test that niri-frame-niri-id returns nil for unmapped frames."
  (niri-frame-test--setup)
  ;; A freshly deleted frame should have no mapping
  (let ((temp (make-frame '((name . "niri-frame-test-transient")))))
    (niri-frame-test--wait-for-mapping 2.0)
    (delete-frame temp)
    (should-not (niri-frame-niri-id temp)))
  (niri-frame-test--teardown))

;;;###autoload
(defun niri-frame-test-run-all (&optional results-dir)
  "Run all nifi-frame tests sequentially.

If RESULTS-DIR is non-nil, write per-test result files:
  RESULTS-DIR/<test-name>/result    — `PASS' or `FAIL ...'
  RESULTS-DIR/<test-name>/messages  — contents of *Messages* after the test
  RESULTS-DIR/<test-name>/warnings  — contents of *Warnings* after the test

Returns a string with PASS/FAIL lines and a summary, suitable for
parsing by a shell script."
  (interactive)
  (let ((tests '("niri-frame-zws-encode-format"
                 "niri-frame-zws-encode-decode-roundtrip"
                 "niri-frame-zws-encode-zero"
                 "niri-frame-zws-decode-no-encoding"
                 "niri-frame-zws-decode-nil-title"
                 "niri-frame-zws-id-suffix-uses-selected-frame"
                 "niri-frame-enable-disable"
                 "niri-frame-enable-requires-connection"
                 "niri-frame-existing-frame-mapped"
                 "niri-frame-frames-alist"
                 "niri-frame-no-pending-after-mapping"
                 "niri-frame-title-has-zws-encoding"
                 "niri-frame-new-frame-mapped"
                 "niri-frame-new-frame-pending-then-mapped"
                 "niri-frame-delete-clears-mappings"
                 "niri-frame-explicit-name-has-encoding"
                 "niri-frame-explicit-name-clear-removes-encoding-via-title"
                 "niri-frame-bidirectional-consistency"
                 "niri-frame-get-frame-missing"
                 "niri-frame-niri-id-missing"))
        (passed 0)
        (failed 0)
        (skipped 0)
        (output nil))
    (dolist (test-name tests)
      ;; Clean slate before each test: disable frame tracking,
      ;; delete extra frames from previous tests, disconnect niri-rpc,
      ;; drain pending events, and clear message buffers.
      (ignore-errors (niri-frame-disable))
      ;; Delete all extra frames except one (keep the initial frame)
      (let ((frames (frame-list)))
        (when (> (length frames) 1)
          (dolist (f (cdr frames))
            (ignore-errors (delete-frame f)))))
      ;; Reset the remaining frame to clean state
      (let ((f (car (frame-list))))
        (ignore-errors (set-frame-parameter f 'name nil))
        (ignore-errors (set-frame-parameter f 'title nil)))
      ;; Reset frame-title-format to remove stale encoding suffix,
      ;; so the next test's enable adds a clean suffix.
      (when (niri-frame--title-format-has-suffix-p)
        (let ((fmt frame-title-format))
          (setq frame-title-format
                (if (listp fmt)
                    (cl-remove-if (lambda (elt)
                                    (equal elt '(:eval (niri-frame--id-suffix))))
                                  fmt)
                  fmt)))
        ;; If reduced to a single-element list, unwrap it
        (when (and (listp frame-title-format)
                   (= (length frame-title-format) 1))
          (setq frame-title-format (car frame-title-format))))
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
                           (expand-file-name "result" test-dir)))))
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
                              (expand-file-name "warnings" test-dir)))))
          ;; Also check for process-filter errors in *Messages*
          (let ((buf (get-buffer "*Messages*")))
            (when buf
              (with-current-buffer buf
                (goto-char (point-min))
                (when (search-forward "error in process filter" nil t)
                  (push (format "  (process-filter errors: %s)" test-name)
                        output))))))))
    (setq output (nreverse output))
    (push (format "SUMMARY %d passed, %d failed, %d skipped" passed failed skipped) output)
    (if (> failed 0)
        (push "EXIT_FAIL" output)
      (push "EXIT_OK" output))
    (mapconcat #'identity (nreverse output) "\n")))

(provide 'niri-frame-test)
;;; niri-frame-test.el ends here
