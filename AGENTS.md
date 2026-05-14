# niri-frame Test Instructions

## Quick start

```bash
./test-niri-frame.sh                    # default socket: niri-frame-test
./test-niri-frame.sh my-socket          # custom emacsclient socket
./test-niri-frame.sh --keep-running     # keep niri+emacs alive after tests
NIRI_BIN=/path/to/niri ./test-niri-frame.sh  # custom niri binary
NIRI_CMD_PREFIX="nix run ... --" ./test-niri-frame.sh  # nix prefix
TIMEOUT=20 ./test-niri-frame.sh         # custom startup timeout
```

The script:
1. Starts niri in embedded (nested) mode with a generated config
2. Niri auto-starts an Emacs daemon
3. Waits for Emacs to be ready (default 15s timeout)
4. Runs all 18 tests (4 unit + 14 integration) via emacsclient
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

All tests are run via the `niri-frame-test-run-all` elisp function, which
handles per-test setup/teardown, result file writing, and *Messages*/*Warnings*
capture. Invoke via emacsclient:

```bash
# Full suite with per-test result dirs
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

## Process filter error handling

`niri-rpc.el` now catches all errors in the event stream process filter:
- JSON parse errors are logged as warnings (e.g., non-event lines like the
  initial "Handled" reply)
- Missing workspace events (race between WorkspaceActivated and
  WorkspacesChanged arrival) are logged as warnings instead of crashing
  the filter
