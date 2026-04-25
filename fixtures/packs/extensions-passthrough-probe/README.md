# extensions-passthrough-probe

Probe pack used by `scripts/regression/2026_04_25_extensions_passthrough.sh`.

The pack must contain a flow whose first node is a WASM component which echoes
its received input as JSON in the `text` field of an outgoing
`emit.response`. The regression script asserts that the bot reply contains
the canonical JSON Pointer `/input/extensions/channel_data/r1_principals` with
the original payload preserved.

## Status

This is a stub directory. The actual probe pack (WASM source under
`components/extensions-probe/`, flow, `pack.yaml`) needs to be authored
before the gated end-to-end regression script can run. The
`webchat-passthrough-probe` sibling pack is the pattern to follow:

1. Copy `../webchat-passthrough-probe/components/bug3-test` to
   `components/extensions-probe`.
2. Replace the body of the `probe` op so it serialises the entire received
   input as JSON and sets it as the `text` of a single outgoing
   `emit.response` message (no attachments needed for this test).
3. Author `pack.yaml` mirroring `../webchat-passthrough-probe/pack.yaml`,
   adjusting `pack_id` (e.g. `ai.greentic.extensions-passthrough.test`).
4. Author `flows/on_message.ygtc` and resolve sidecars (run
   `greentic-pack resolve`).
5. Add `fixtures/wizard-answers/extensions-passthrough-bundle.json` patterned
   on `webchat-passthrough-bundle.json`.

## Why a stub

The fix that this test pins shipped on 2026-04-25 across two repos
(`greentic-runner` and `greentic-start`). The unit-test surface inside each
repo already pins the boundary they own. This e2e test gives one
cross-binary regression at the canonical JSON Pointer that flow nodes / WASM
components actually read.

When the probe component is authored, remove this README and the gate-by-
RUN_E2E in the regression script's documentation will continue to apply
until the test is run end-to-end on CI.
