#!/usr/bin/env bash
set -euo pipefail

# Run niri-frame tests in an isolated embedded niri instance.
#
# Starts niri in embedded (nested) mode with a generated config that
# auto-starts an Emacs daemon.  Then runs the full test suite, captures
# per-test results in a directory, and cleans up.
#
# Usage:
#   ./test-niri-frame.sh                          # default socket: niri-frame-test
#   ./test-niri-frame.sh my-socket                # custom emacsclient socket
#   ./test-niri-frame.sh --keep-running           # keep niri+emacs alive after tests
#   NIRI_BIN=… ./test-niri-frame.sh               # custom niri binary
#   NIRI_CMD_PREFIX=… ./test-niri-frame.sh        # nix run prefix etc.
#
# Environment variables:
#   NIRI_BIN         Path to niri binary (default: auto-detected)
#   NIRI_CMD_PREFIX  Command prefix for niri (overrides NIRI_BIN)
#   TIMEOUT          Startup timeout in seconds (default: 15)
#   RESULTS_DIR      Where to write test results (default: ./test-results)
#   KEEP_RUNNING=1   Keep niri and emacs running after tests (for debugging)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KEEP_RUNNING="${KEEP_RUNNING:-}"
SOCKET="niri-frame-test"
TIMEOUT="${TIMEOUT:-15}"
RESULTS_DIR="${RESULTS_DIR:-$SCRIPT_DIR/test-results}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-running) KEEP_RUNNING=1; shift ;;
        -s) SOCKET="$2"; shift 2 ;;
        *) SOCKET="$1"; shift ;;
    esac
done

# ── Resolve niri command ──────────────────────────────────────────────

if [[ -n "${NIRI_CMD_PREFIX:-}" ]]; then
    NIRI_CMD="$NIRI_CMD_PREFIX"
elif [[ -n "${NIRI_BIN:-}" ]]; then
    NIRI_CMD="$NIRI_BIN"
elif [[ -x "$SCRIPT_DIR/../niri-wts/niri-26.04/target/release/niri" ]]; then
    NIRI_CMD="$SCRIPT_DIR/../niri-wts/niri-26.04/target/release/niri"
else
    echo "ERROR: cannot find niri binary. Set NIRI_BIN or NIRI_CMD_PREFIX." >&2
    exit 2
fi

# Ensure we're inside a Wayland session (niri embedded needs it)
if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
    echo "ERROR: WAYLAND_DISPLAY is not set. Are you running inside a Wayland session?" >&2
    exit 2
fi

echo "niri command:  $NIRI_CMD"
echo "wayland:       $WAYLAND_DISPLAY"
echo "socket:        $SOCKET"
echo "results:       $RESULTS_DIR"
[[ -n "${KEEP_RUNNING:-}" ]] && echo "keep-running:  yes (niri+emacs stay alive after tests)"

# ── Clean previous results ────────────────────────────────────────────

rm -rf "$RESULTS_DIR"
mkdir -p "$RESULTS_DIR"

# ── Temporary directory for niri runtime ──────────────────────────────

NIRI_TMPDIR="$(mktemp -d)"
cleanup() {
    if [[ -n "${KEEP_RUNNING:-}" ]]; then
        echo ""
        echo "--- Keeping niri and Emacs running (--keep-running) ---"
        echo "niri PID:     $NIRI_PID"
        echo "niritmpdir:  $NIRI_TMPDIR"
        echo "config:       $NIRI_TMPDIR/config.kdl"
        echo "emacs socket: $SOCKET"
        echo ""
        echo "Connect with: emacsclient -s $SOCKET"
        echo "Kill with:    kill $NIRI_PID"
        echo "Clean tmp:    rm -rf $NIRI_TMPDIR"
        return
    fi
    echo ""
    echo "Cleaning up..."
    kill "$NIRI_PID" 2>/dev/null || true
    wait "$NIRI_PID" 2>/dev/null || true
    rm -rf "$NIRI_TMPDIR"
}
trap cleanup EXIT

# ── Generate niri config ──────────────────────────────────────────────

# Write the Emacs startup script to a temp file so we don't have to
# battle with multi-level quote escaping in KDL.
cat > "$NIRI_TMPDIR/startup.el" << ENDELISP
;;; startup.el — niri-frame test helper -*- lexical-binding: t -*-
(setq server-name "$SOCKET")
(server-start)
ENDELISP

cat > "$NIRI_TMPDIR/config.kdl" << ENDCONFIG
// Minimal test config for niri-frame integration tests
input {
    keyboard {
        xkb {
            layout "us"
        }
    }
}

animations { off; }

hotkey-overlay { skip-at-startup; }

spawn-at-startup "emacs" "-q" "-l" "$NIRI_TMPDIR/startup.el"
ENDCONFIG

# ── Validate config before starting niri ────────────────────────────

echo "Validating config..."
# shellcheck disable=SC2086
VALIDATE_OUTPUT=$($NIRI_CMD validate -c "$NIRI_TMPDIR/config.kdl" 2>&1) || {
    echo "ERROR: config validation failed" >&2
    echo "$VALIDATE_OUTPUT" >&2
    exit 2
}
echo "Config OK."

# ── Start niri ────────────────────────────────────────────────────────

echo "Starting niri in embedded mode..."
# Redirect output so niri logging doesn't clutter the terminal.
# shellcheck disable=SC2086
$NIRI_CMD -c "$NIRI_TMPDIR/config.kdl" \
    >"$NIRI_TMPDIR/niri-stdout.log" 2>"$NIRI_TMPDIR/niri-stderr.log" &
NIRI_PID=$!
echo "niri PID: $NIRI_PID"

# ── Wait for Emacs daemon ─────────────────────────────────────────────

echo "Waiting for Emacs daemon (socket: $SOCKET, timeout: ${TIMEOUT}s)..."
START_TIME=$(date +%s)
while ! emacsclient -s "$SOCKET" -e t &>/dev/null; do
    if ! kill -0 "$NIRI_PID" 2>/dev/null; then
        echo ""
        echo "ERROR: niri died before Emacs started." >&2
        echo "--- niri stdout ---"; cat "$NIRI_TMPDIR/niri-stdout.log"
        echo "--- niri stderr ---"; cat "$NIRI_TMPDIR/niri-stderr.log"
        exit 2
    fi
    if (( $(date +%s) - START_TIME >= TIMEOUT )); then
        echo ""
        echo "ERROR: Emacs daemon not ready within ${TIMEOUT}s." >&2
        echo "--- niri stdout ---"; cat "$NIRI_TMPDIR/niri-stdout.log"
        echo "--- niri stderr ---"; cat "$NIRI_TMPDIR/niri-stderr.log"
        exit 2
    fi
    sleep 0.3
done
echo "Emacs daemon is ready."

# Verify we're talking to the right emacs (the one spawned by niri has
# NIRI_SOCKET set in its environment, not inherited from the outer niri).
VERIFY="$(emacsclient -s "$SOCKET" --eval "(or (getenv \"NIRI_SOCKET\") \"unset\")" 2>&1)"
echo "emacs NIRI_SOCKET: $VERIFY"
if [[ "$VERIFY" == '"unset"' ]]; then
    echo "ERROR: wrong emacs — this one has no NIRI_SOCKET (probably an existing daemon)." >&2
    echo "       Stop your existing '$SOCKET' daemon or use a different socket name." >&2
    exit 2
fi

# Give Emacs and niri a moment to settle event streams
sleep 0.5

# ── Run tests via emacsclient ─────────────────────────────────────────

echo ""
echo "=== Running niri-frame test suite ==="

# emacsclient captures the return value as a Lisp string with literal \n.
raw="$(emacsclient -s "$SOCKET" --eval "
(condition-case err
    (progn
      (mapc (function load-file)
            (list \"$SCRIPT_DIR/niri-rpc.el\"
                  \"$SCRIPT_DIR/niri-frame.el\"
                  \"$SCRIPT_DIR/niri-frame-test.el\"))
      (niri-frame-test-run-all \"$RESULTS_DIR\"))
  (error
   (format \"FATAL: %s\" (error-message-string err))))" 2>&1)"

# Strip opening and closing quotes, convert \\n to real newlines.
raw="${raw#\"}"
raw="${raw%\"}"
output="${raw//\\n/$'\n'}"

# ── Report ────────────────────────────────────────────────────────────

exit_code=0
while IFS= read -r line; do
    case "$line" in
        PASS\ *)   echo "  $line" ;;
        FAIL\ *)   echo "  $line"; exit_code=1 ;;
        SUMMARY\ *) echo ""; echo "$line" ;;
        EXIT_FAIL) exit_code=1 ;;
        EXIT_OK)   ;;
        "") ;;
        *)         echo "  $line" ;;
    esac
done <<< "$output"

echo ""
echo "Per-test results and logs saved to: $RESULTS_DIR"

if (( exit_code == 0 )); then
    echo "All tests passed."
else
    echo "Some tests FAILED. Check $RESULTS_DIR for details."
fi

exit $exit_code
