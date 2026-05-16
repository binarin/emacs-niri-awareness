#!/usr/bin/env bash
# run-unit-tests.sh — Run all Elisp unit tests that don't require niri.
#
# Usage:
#   ./run-unit-tests.sh
#
# This loads niri-rpc.el, niri-frame.el, niri-frame-visible.el and all
# three test files, then runs every ert test tagged with :unit or listed
# in the hardcoded unit-test name list.
#
# Unlike integration-tests.sh, this does NOT start niri or Emacs daemon.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Unit test list ───────────────────────────────────────────────────────
# Tests from niri-rpc-test.el (no niri connection needed):
rpc_unit=(
  niri-rpc-struct-timestamp
  niri-rpc-struct-window-layout
  niri-rpc-struct-window
  niri-rpc-struct-workspace
  niri-rpc-struct-event
  niri-rpc-filter-partial-lines
  niri-rpc-filter-no-trailing-newline
  niri-rpc-json-parse-window
  niri-rpc-json-parse-window-layout-is-visible-in-column
  niri-rpc-json-parse-workspace
  niri-rpc-json-null-names
)

# Tests from niri-frame-test.el (tag extraction/formatting, no niri needed):
frame_unit=(
  niri-frame-tag-format
  niri-frame-tag-extraction
  niri-frame-tag-no-match
  niri-frame-tag-nil-title
)

# Tests from niri-frame-visible-test.el (rect math, advice unit logic):
visible_unit=(
  niri-frame-visible-threshold-default
  niri-frame-visible-threshold-set
  niri-frame-visible-rect-fully-visible
  niri-frame-visible-rect-partially-visible
  niri-frame-visible-rect-barely-visible
  niri-frame-visible-rect-not-visible
  niri-frame-visible-rect-zero-area
  niri-frame-visible-rect-multi-output
  niri-frame-visible-advice-original-nil
  niri-frame-visible-advice-no-niri-id
  niri-frame-visible-advice-no-rect
  niri-frame-visible-advice-not-visible
  niri-frame-visible-advice-visible
  niri-frame-visible-advice-edge-case-equal-threshold
  niri-frame-visible-advice-graceful-error
  niri-frame-visible-advice-hidden-tab
  niri-frame-visible-advice-visible-in-column
  niri-frame-visible-advice-no-window-in-table
)

all_tests=("${rpc_unit[@]}" "${frame_unit[@]}" "${visible_unit[@]}")
total=${#all_tests[@]}

echo "=== Running $total unit tests (no niri required) ==="

cd "$SCRIPT_DIR"

emacs --batch --eval "
(progn
  (setq debug-on-error t)

  ;; Load sources
  (load-file \"niri-rpc.el\")
  (load-file \"niri-frame.el\")
  (load-file \"niri-frame-visible.el\")

  ;; Load test files
  (load-file \"niri-rpc-test.el\")
  (load-file \"niri-frame-test.el\")
  (load-file \"niri-frame-visible-test.el\")

  ;; Run each unit test individually
  (let ((passed 0)
        (failed 0)
        (errors '()))
    (dolist (name '(${all_tests[*]}))
      (condition-case err
          (progn
            (ert name)
            (message \"  PASS %s\" name)
            (setq passed (1+ passed)))
        (error
         (message \"  FAIL %s: %s\" name (error-message-string err))
         (push (cons name err) errors)
         (setq failed (1+ failed)))))
    (message \"\n=== SUMMARY %d passed, %d failed ===\" passed failed)
    (when errors
      (message \"Failures:\")
      (dolist (e (nreverse errors))
        (message \"  %s: %s\" (car e) (error-message-string (cdr e)))))
    (when (> failed 0)
      (kill-emacs 1))))
" 2>&1
