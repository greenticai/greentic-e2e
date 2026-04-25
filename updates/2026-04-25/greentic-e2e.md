# greentic-e2e — 2026-04-25

Pin three 2026-04-25 regressions across `greentic-runner`, `greentic-start`,
and `greentic-pack` so they cannot silently re-break.

Branch: `test/regression-2026-04-25` (forked from `main`). Not pushed.

## Tests added

All three live under `scripts/regression/` and follow the existing shell
convention (`run_provider_e2e.sh`, `run_webchat_passthrough_e2e.sh`).

- **`extensions_passthrough.sh`** — pins `greentic-runner`
  `fix/ingress-extensions-and-template-null` (commit `a47fae2`) and
  `greentic-start` `fix/preserve-envelope-extensions-in-flow-input`
  (commit `8b0a020`). Asserts the canonical JSON Pointer
  `/input/extensions/channel_data/r1_principals` is preserved end-to-end
  with snake_case keys. **Skip-by-default**, gated behind `RUN_E2E=1`.
- **`emit_response_build.sh`** — pins `greentic-pack`
  `fix/builtin-node-resolve-skip` (commit `5fe4715`, `0.5.3`+). Positive
  fixture: flow with only `emit.response` builds exit 0, no
  `missing resolve summary entries`. Negative fixture: real component
  without resolve entry STILL errors with that string. **Runs by default.**
- **`null_template_handling.sh`** — pins `greentic-runner`
  `fix/ingress-extensions-and-template-null` (commit `22d633b`). Empty
  DirectLine payload must not produce `invalid type: null, expected a string`,
  and rendered `content` must be `""` (not JSON null). **Skip-by-default**,
  gated behind `RUN_E2E=1`.

## How to run

```bash
./scripts/regression/emit_response_build.sh

RUN_E2E=1 ./scripts/regression/extensions_passthrough.sh
RUN_E2E=1 ./scripts/regression/null_template_handling.sh
```

## Skip rationale

Tests 1 and 3 require `gtc`, `greentic-start`, `greentic-secrets`,
`cargo-component`, and patched runner/start binaries on PATH plus a probe
WASM. Without `RUN_E2E=1` they print a loud banner naming the fix they pin
and the canonical assertion — they never silently skip. The probe pack
fixtures ship as stubs with READMEs (`fixtures/packs/extensions-passthrough-probe/`,
`fixtures/packs/null-template-probe/`); the probe WASM is left to follow-up
since the runner-side unit tests already pin the underlying logic and these
scripts are the cross-binary harness for when probes land.

## Verification

- Test 2 PASSES on the patched `greentic-pack 0.5.3`. Sanity-checked
  against the pre-fix `0.5.2` via `GREENTIC_PACK_BIN`: it exits 1 with the
  expected error.
- Tests 1 and 3 exit 0 in skip mode and emit the documented banner.
- All three scripts pass `bash -n`. `shellcheck` was unavailable locally;
  recommend wiring it into CI.
