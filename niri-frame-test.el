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
  ;; Wait for existing frames to be tagged and matched via async events
  (let ((start (float-time)))
    (while (and (< (- (float-time) start) 2.0)
                (> (hash-table-count niri-frame--tag-to-frame) 0))
      (accept-process-output niri-rpc--async-process 0.05))))

(defun niri-frame-test--teardown ()
  "Disable frame tracking and disconnect from niri."
  (ignore-errors (niri-frame-disable))
  (ignore-errors (niri-rpc-disconnect)))

(defun niri-frame-test--wait-for-mapping (timeout)
  "Wait up to TIMEOUT seconds for pending tags to be matched."
  (let ((start (float-time)))
    (while (and (< (- (float-time) start) timeout)
                (> (hash-table-count niri-frame--tag-to-frame) 0))
      (accept-process-output niri-rpc--async-process 0.05))))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;; Tests: Enable / disable
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(ert-deftest niri-frame-enable-disable ()
  "Test that frame tracking can be enabled and disabled cleanly."
  (niri-frame-test--setup)
  (should niri-frame--enabled)
  (should (= (hash-table-count niri-frame--tag-to-frame) 0))
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

(ert-deftest niri-frame-title-no-tag-after-mapping ()
  "Test that the frame title does not contain the tag after mapping."
  (niri-frame-test--setup)
  (let ((title (frame-parameter (selected-frame) 'name)))
    ;; The title should not contain our tag
    (should-not (niri-frame--title-has-tag-p (or title ""))))
  (let ((tag-param (frame-parameter (selected-frame) 'niri-frame-tag)))
    (should-not tag-param))
  (niri-frame-test--teardown))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;; Tests: Frame creation
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(ert-deftest niri-frame-new-frame-tagged-and-mapped ()
  "Test that a newly created frame is tagged and eventually mapped."
  (niri-frame-test--setup)
  (let* ((count-before (length (niri-frame-frames)))
         (new-frame (make-frame '((name . "niri-frame-test-temp")))))
    (unwind-protect
        (progn
          ;; The new frame should have a tag parameter immediately
          (should (frame-parameter new-frame 'niri-frame-tag))
          (should (string-match-p niri-frame-tag-regexp-pattern
                                  (or (frame-parameter new-frame 'niri-frame-tag) "")))
          ;; Wait for niri to emit WindowOpenedOrChanged and our hook to match
          (niri-frame-test--wait-for-mapping 2.0)
          ;; After mapping, the frame should be in the mappings
          (let ((niri-id (niri-frame-niri-id new-frame)))
            (should niri-id)
            (should (integerp niri-id))
            ;; Tag should be removed
            (should-not (frame-parameter new-frame 'niri-frame-tag))
            ;; And the reverse lookup works
            (should (eq (niri-frame-get-frame niri-id) new-frame)))
          ;; Total mapped frames should have increased
          (should (= (length (niri-frame-frames)) (1+ count-before))))
      (delete-frame new-frame)))
  (niri-frame-test--teardown))

(ert-deftest niri-frame-new-frame-pending-then-mapped ()
  "Test the pending → mapped lifecycle of a new frame."
  (niri-frame-test--setup)
  (let ((new-frame (make-frame '((name . "niri-frame-test-lifecycle")))))
    (unwind-protect
        (progn
          ;; Immediately after creation, it should be pending
          (let ((pending (niri-frame-pending-frames)))
            (should (memq new-frame pending)))
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
;; Tests: Custom name preservation
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(ert-deftest niri-frame-remove-tag-restores-computed-title ()
  "Test that remove-tag restores the saved effective title."
  (let ((frame (selected-frame))
        (title-before (frame-parameter (selected-frame) 'name)))
    ;; Clear any saved-name state from prior tests
    (set-frame-parameter frame 'niri-frame-orig-name nil)
    (set-frame-parameter frame 'niri-frame-tag nil)
    ;; Inject — saves the current effective title
    (niri-frame--inject-tag frame "[niri-frame-998]")
    ;; The saved original should be the effective title from before
    (should (equal (frame-parameter frame 'niri-frame-orig-name)
                   title-before))
    ;; Remove — restores the saved title
    (niri-frame--remove-tag frame)
    (should (equal (frame-parameter frame 'name) title-before))
    ;; Cleanup params cleared
    (should-not (frame-parameter frame 'niri-frame-orig-name))
    (should-not (frame-parameter frame 'niri-frame-tag))))

(ert-deftest niri-frame-remove-tag-restores-custom-name ()
  "Test that remove-tag restores an explicitly set custom name."
  (let ((frame (selected-frame))
        (custom "My Custom Emacs Title"))
    (set-frame-parameter frame 'niri-frame-orig-name nil)
    (set-frame-parameter frame 'niri-frame-tag nil)
    (set-frame-parameter frame 'name custom)
    (niri-frame--inject-tag frame "[niri-frame-997]")
    (should (equal (frame-parameter frame 'niri-frame-orig-name)
                   custom))
    (niri-frame--remove-tag frame)
    (should (equal (frame-parameter frame 'name) custom))
    (should-not (frame-parameter frame 'niri-frame-orig-name))
    (should-not (frame-parameter frame 'niri-frame-tag))))

;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;; Tests: Tag generation and parsing (unit tests, no connection needed)
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

(ert-deftest niri-frame-tag-format ()
  "Test that tags are generated with the expected format."
  (let ((niri-frame--counter 0)
        (tag1 (niri-frame--make-tag (niri-frame--next-counter)))
        (tag2 (niri-frame--make-tag (niri-frame--next-counter))))
    (should (string-match-p niri-frame-tag-regexp-pattern tag1))
    (should (string-match-p niri-frame-tag-regexp-pattern tag2))
    ;; Tags should be different (monotonic counter)
    (should-not (string= tag1 tag2))
    ;; Tags should start with the configured prefix
    (should (string-prefix-p niri-frame-tag-prefix tag1))
    (should (string-prefix-p niri-frame-tag-prefix tag2))))

(ert-deftest niri-frame-tag-extraction ()
  "Test extracting tags from window titles."
  (let ((tagged-title "*scratch* - GNU Emacs [niri-frame-42]"))
    (should (niri-frame--title-has-tag-p tagged-title))
    (should (equal (niri-frame--extract-tag tagged-title)
                   "[niri-frame-42]"))
    (should (= (niri-frame--extract-counter tagged-title) 42))))

(ert-deftest niri-frame-tag-no-match ()
  "Test that titles without tags are correctly identified."
  (let ((plain-title "*scratch* - GNU Emacs at furfur")
        (weird-title "[just-brackets]"))
    (should-not (niri-frame--title-has-tag-p plain-title))
    (should-not (niri-frame--extract-tag plain-title))
    (should-not (niri-frame--extract-counter plain-title))
    (should-not (niri-frame--title-has-tag-p weird-title))
    (should-not (niri-frame--extract-tag weird-title))))

(ert-deftest niri-frame-tag-nil-title ()
  "Test that nil titles are handled safely."
  (should-not (niri-frame--title-has-tag-p nil))
  (should-not (niri-frame--extract-tag nil))
  (should-not (niri-frame--extract-counter nil)))

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
  "Run all niri-frame tests sequentially.

If RESULTS-DIR is non-nil, write per-test result files:
  RESULTS-DIR/<test-name>/result    — `PASS' or `FAIL ...'
  RESULTS-DIR/<test-name>/messages  — contents of *Messages* after the test
  RESULTS-DIR/<test-name>/warnings  — contents of *Warnings* after the test

Returns a string with PASS/FAIL lines and a summary, suitable for
parsing by a shell script."
  (interactive)
  (let ((tests '("niri-frame-tag-format"
                 "niri-frame-tag-extraction"
                 "niri-frame-tag-no-match"
                 "niri-frame-tag-nil-title"
                 "niri-frame-enable-disable"
                 "niri-frame-enable-requires-connection"
                 "niri-frame-existing-frame-mapped"
                 "niri-frame-frames-alist"
                 "niri-frame-no-pending-after-mapping"
                 "niri-frame-title-no-tag-after-mapping"
                 "niri-frame-new-frame-tagged-and-mapped"
                 "niri-frame-new-frame-pending-then-mapped"
                 "niri-frame-delete-clears-mappings"
                 "niri-frame-remove-tag-restores-computed-title"
                 "niri-frame-remove-tag-restores-custom-name"
                 "niri-frame-bidirectional-consistency"
                 "niri-frame-get-frame-missing"
                 "niri-frame-niri-id-missing"))
        (passed 0)
        (failed 0)
        (skipped 0)
        (output nil))
    (dolist (test-name tests)
      ;; Clean slate before each test: disconnect, drain pending events,
      ;; and clear *Messages* so we can check for process-filter errors.
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
