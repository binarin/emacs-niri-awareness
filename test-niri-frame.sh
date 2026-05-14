#!/usr/bin/env bash
set -euo pipefail

# Run niri-frame test suite against a running Emacs instance.
#
# Usage:
#   ./test-niri-frame.sh               # default socket: pi
#   ./test-niri-frame.sh my-socket      # custom emacsclient socket name

SOCKET="${1:-pi}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! emacsclient -s "$SOCKET" -e t &>/dev/null; then
    echo "ERROR: cannot reach Emacs daemon on socket '$SOCKET'" >&2
    exit 1
fi

# ── Unit tests (no niri connection needed, runs in batch) ────────────────

echo "=== Unit tests: tag parsing ==="
emacs --batch -L "$SCRIPT_DIR" -l ert -l niri-rpc -l niri-frame -l niri-frame-test \
      --eval '(ert-run-tests-batch-and-exit "niri-frame-tag-")'

# ── Integration tests (single emacsclient call) ──────────────────────────

echo ""
echo "=== Integration tests ==="

# emacsclient returns the value as a Lisp string with literal \n escapes.
# Strip the surrounding quotes, then convert \\n to real newlines.
raw="$(emacsclient -s "$SOCKET" --eval "
(progn
  (ignore-errors (niri-rpc-disconnect))
  (while (and niri-rpc--async-process
              (accept-process-output niri-rpc--async-process 0.01)))
  (setq niri-rpc--async-process nil)
  (mapc (function load-file)
        (list \"$SCRIPT_DIR/niri-rpc.el\"
              \"$SCRIPT_DIR/niri-frame.el\"
              \"$SCRIPT_DIR/niri-frame-test.el\"))
  (niri-frame-test-run-all))" 2>&1)"

# Strip opening and closing quotes
raw="${raw#\"}"
raw="${raw%\"}"
# Convert literal \n to real newlines
output="${raw//\\n/$'\n'}"

exit_code=0
while IFS= read -r line; do
    case "$line" in
        PASS\ *)   echo "  ${line}" ;;
        FAIL\ *)   echo "  ${line}" ;;
        SUMMARY\ *) echo ""; echo "$line" ;;
        EXIT_FAIL) exit_code=1 ;;
        EXIT_OK)   ;;
        *process-filter*) echo "  ${line}" ;;
        "") ;;
        *)         echo "  $line" ;;
    esac
done <<< "$output"

exit $exit_code
