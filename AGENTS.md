# niri-frame Test Instructions

## Quick start

```bash
# Unit tests (33 tests, no niri required, fast)
./run-unit-tests.sh

# Full integration tests (46 tests, requires Wayland + niri)
./integration-tests.sh                    # default socket: niri-frame-test
./integration-tests.sh -t single-test     # run a single integration test
./integration-tests.sh --test single-test
./integration-tests.sh my-socket          # custom emacsclient socket
./integration-tests.sh --keep-running     # keep niri+emacs alive after tests
NIRI_BIN=/path/to/niri ./integration-tests.sh  # custom niri binary
NIRI_CMD_PREFIX="nix run ... --" ./integration-tests.sh  # nix prefix
TIMEOUT=20 ./integration-tests.sh         # custom startup timeout
```

The script:
1. Starts niri in embedded (nested) mode with a generated config
2. Niri auto-starts an Emacs daemon
3. Waits for Emacs to be ready (default 15s timeout)
4. Runs all 46 tests (18 frame + 28 visible) via emacsclient
   (or a single test when `--test NAME` is given)
5. Writes per-test result files to `test-results/<test-name>/`
6. Cleans up the niri process and temp directory

Exit code 0 = all tests passed.

Results directory per test:
- `result` — "PASS" or "FAIL ..."
- `messages` — content of `*Messages*` buffer after the test
- `warnings` — content of `*Warnings*` buffer after the test

## Requirements

- Running inside a Wayland session (WAYLAND_DISPLAY must be set)
- niri binary (auto-detected at `../niri-wts/niri-26.04/target/release/niri`)
- Emacs with server support compiled in

## Generated niri config

A minimal config is generated in a temp directory:

```kdl
input { keyboard { xkb { layout "us" } } }
binds { Mod Alt; }
animations { off; }
hotkey-overlay { skip-at-startup; }
spawn-at-startup "emacs" "-q" "-l" "/tmp/.../startup.el"
```

The startup.el sets `server-name` and calls `server-start`.

## Running individual tests

Use the `--test` / `-t` flag to run a single integration test:

```bash
# One test with the normal test environment
./integration-tests.sh --test niri-frame-visible-tabbed-column-hidden

# With custom socket
./integration-tests.sh my-socket -t niri-frame-new-frame-pending-then-mapped

# Keep niri+emacs alive after so you can inspect state
./integration-tests.sh --keep-running -t niri-frame-visible-toggle-floating
```

The script auto-detects the correct setup/teardown from the test name prefix
(`niri-frame-visible-*`, `niri-frame-*`, or `niri-rpc-*`).

All tests are run via the `niri-frame-test-run-all` elisp function, which
handles per-test setup/teardown, result file writing, and *Messages*/*Warnings*
capture. Invoke via emacsclient:

```bash
# Full suite with per-test result dirs (niri-frame tests only, no visible)
emacsclient -s pi --eval "
(progn
  (mapc #'load-file '(\"niri-rpc.el\" \"niri-frame.el\" \"niri-frame-test.el\"))
  (niri-frame-test-run-all \"/path/to/results\"))"
```

## Running under ert directly

```elisp
;; Unit tests only (no niri connection needed)
(ert-run-tests-batch-and-exit "niri-frame-tag-")

;; Single integration test (needs niri connection)
(progn
  (require 'niri-rpc)
  (require 'niri-frame)
  (require 'niri-frame-test)
  (niri-rpc-connect)
  (niri-frame-enable)
  (ert "niri-frame-existing-frame-mapped"))
```

## Manual exploratory testing workflow

### Quick access: keep the test environment alive

```bash
./integration-tests.sh --keep-running
```

This leaves niri and the Emacs daemon running after tests complete. You can
then open frames interactively and run ad-hoc evaluations. The script prints
the socket name and PID — connect with:

```bash
emacsclient -s niri-frame-test
```

To kill everything when done: `kill $PID` (script prints the PID).

### How integration tests connect to niri

Each integration test runs `niri-frame-test--setup()` which:
1. Calls `(niri-rpc-connect)` — opens a Unix socket to niri (uses
   `NIRI_SOCKET` env var; niri sets this for spawned processes)
2. Waits for event stream to populate the windows hash table
3. Calls `(niri-frame-enable)` — adds hooks so new frames get tagged
4. Waits for existing frames to be matched and tags removed

`niri-frame-test--teardown()` calls `(niri-frame-disable)` then
`(niri-rpc-disconnect)`.

### Running individual ert tests via emacsclient

**Unit tests** (no niri connection needed):

```bash
# Load files and run a specific unit test
emacsclient -s niri-frame-test --eval "
(progn
  (load-file \"/path/to/niri-frame.el\")
  (load-file \"/path/to/niri-frame-test.el\")
  (ert \"niri-frame-tag-format\"))"
```

Unit tests (4 total):
- `niri-frame-tag-format` — tag generation format
- `niri-frame-tag-extraction` — extracting tags from titles
- `niri-frame-tag-no-match` — titles without tags
- `niri-frame-tag-nil-title` — nil title safety

**Integration tests** (require niri connection):

```bash
emacsclient -s nifi-frame-test --eval "
(progn
  (load-file \"/path/to/niri-rpc.el\")
  (load-file \"/path/to/niri-frame.el\")
  (load-file \"/path/to/niri-frame-test.el\")
  (niri-frame-test--setup)
  (unwind-protect
      (ert \"niri-frame-existing-frame-mapped\")
    (niri-frame-test--teardown)))"
```

Integration tests (14 total):
- `niri-frame-enable-disable` — enable/disable lifecycle
- `niri-frame-enable-requires-connection` — error when not connected
- `niri-frame-existing-frame-mapped` — existing frame gets niri window id
- `niri-frame-frames-alist` — niri-frame-frames returns valid mappings
- `niri-frame-no-pending-after-mapping` — no pending after mapping completes
- `niri-frame-title-no-tag-after-mapping` — tag removed from title after mapping
- `niri-frame-new-frame-tagged-and-mapped` — new frame tagged then mapped
- `niri-frame-new-frame-pending-then-mapped` — pending → mapped lifecycle
- `niri-frame-delete-clears-mappings` — deletion cleans up mappings
- `niri-frame-remove-tag-restores-computed-title` — tag removal restores title
- `niri-frame-remove-tag-restores-custom-name` — tag removal restores custom name
- `niri-frame-bidirectional-consistency` — forward/reverse lookup consistency
- `niri-frame-get-frame-missing` — nil on unknown window id
- `niri-frame-niri-id-missing` — nil on unmapped frame

### Running the full test suite manually

```bash
emacsclient -s niri-frame-test --eval "
(progn
  (mapc #'load-file '(\"/path/to/niri-rpc.el\"
                      \"/path/to/niri-frame.el\"
                      \"/path/to/niri-frame-test.el\"))
  (niri-frame-test-run-all \"/path/to/results\"))"
```

`niri-frame-test-run-all` runs all 18 tests sequentially. For each test it:
1. Disconnects any prior niri connection and kills `*Messages*`/`*Warnings*`
2. Runs the ert test
3. Writes per-test result files (`result`, `messages`, `warnings`)
4. Checks `*Messages*` for "error in process filter" lines

Returns a newline-separated string with PASS/FAIL lines and a SUMMARY.

### Exploratory commands after connecting

Once connected (`niri-rpc-connect` + `niri-frame-enable`), you can explore:

```elisp
;; Check connection status
niri-rpc--connected

;; View all known niri windows
(hash-table-keys niri-rpc--windows)

;; Get niri window id for the current frame
(niri-frame-niri-id (selected-frame))
;; => <integer> or nil

;; Look up Emacs frame by niri window id
(niri-frame-get-frame <id>)
;; => <frame> or nil

;; List all frame→niri-id pairs
(niri-frame-frames)
;; => ((<frame> . <id>) ...)

;; List pending (tagged but not yet matched) frames
(niri-frame-pending-frames)
;; => (<frame> ...)

;; Create a new frame and watch the lifecycle
(make-frame '((name . "test-frame")))
(niri-frame-pending-frames)   ; should show the new frame
;; Wait for niri events to propagate:
(accept-process-output niri-rpc--async-process 1.0)
(niri-frame-niri-id <new-frame>)  ; should have an id now
```

### How the test runner's cleanup works

`niri-frame-test-run-all` disconnects and kills `*Messages*`/`*Warnings*`
*before every test* to ensure isolation. This means you don't need to worry
about leftover state from previous tests.

The `integration-tests.sh` script also verifies that the Emacs it found
truly belongs to the niri it started (by checking `NIRI_SOCKET` env var).
This prevents accidentally running tests against an existing daemon.

### Using an existing Emacs daemon (not the test runner's)

If you already have an Emacs daemon running under niri, you can connect
manually:

```bash
emacsclient -s your-socket --eval "
(progn
  (load-file \"/path/to/niri-rpc.el\")
  (load-file \"/path/to/niri-frame.el\")
  (niri-rpc-connect)
  (niri-frame-enable))"
```

This won't work if the Emacs isn't a child of niri (i.e., it was started
outside niri's process tree), because `NIRI_SOCKET` won't be set. The niri
control socket path is derived from `NIRI_SOCKET`, which niri sets in the
environment of processes it spawns.

## Process filter error handling

`niri-rpc.el` now catches all errors in the event stream process filter:
- JSON parse errors are logged as warnings (e.g., non-event lines like the
  initial "Handled" reply)
- Missing workspace events (race between WorkspaceActivated and
  WorkspacesChanged arrival) are logged as warnings instead of crashing
  the filter
