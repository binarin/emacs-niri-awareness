# niri-frame Test Instructions

## Quick start

```bash
./test-niri-frame.sh              # uses pi as default emacsclient socket
./test-niri-frame.sh my-socket    # custom socket name
```

Exit code 0 means all tests passed. Requires an Emacs daemon running inside a
niri session (so `$NIRI_SOCKET` is set in the daemon's environment). Start one
with:

```bash
emacs --daemon=pi
```

## What it runs

### Unit tests (4 tests, no niri connection needed)
Tag format, extraction, nil handling, and no-match detection. Run via
`emacs --batch`.

### Integration tests (14 tests, require live niri + Emacs daemon)
- Enable/disable lifecycle
- Existing frame auto-mapping
- Frame creation → tag → async event → mapping
- Frame deletion → mapping cleanup
- Bidirectional lookup consistency
- Title injection/removal preserves original frame name
- Process-filter error detection in `*Messages*`

All integration tests run in a single `emacsclient --eval` session. Each test
gets a fresh niri-rpc connection: disconnect, drain pending events, kill
`*Messages*`, reconnect.

## Running individual tests

```bash
# Unit test (batch)
emacs --batch -L . -l ert -l niri-rpc -l niri-frame -l niri-frame-test \
      --eval '(ert-run-tests-batch-and-exit "niri-frame-tag-format")'

# Integration test (via emacsclient)
emacsclient -s pi --eval "
(progn
  (ignore-errors (niri-rpc-disconnect))
  (while (and niri-rpc--async-process
              (accept-process-output niri-rpc--async-process 0.01)))
  (setq niri-rpc--async-process nil)
  (mapc #'load-file '(\"niri-rpc.el\" \"niri-frame.el\" \"niri-frame-test.el\"))
  (ert \"niri-frame-existing-frame-mapped\"))"
```

## Running under ert directly

```elisp
;; Unit tests only
(ert-run-tests-batch-and-exit "niri-frame-tag-")

;; All niri-frame tests (unit + integration, needs niri connection)
(niri-frame-test-run-all)
```
