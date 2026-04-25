# extensions-passthrough-probe

Probe pack used by `scripts/regression/extensions_passthrough.sh`.

## Layout

```
components/extensions-probe/      # echo-input WASM (component@0.6.0)
flows/on_message.ygtc             # node WITHOUT explicit `extensions` mapping
flows/on_message.ygtc.resolve.json
pack.yaml
```

The probe component echoes its received input back as a JSON string in the
`text` field of the bot reply. The flow does NOT declare an explicit
`extensions` mapping, so it relies on the runner's auto-merge of
envelope-level extensions into the WASM-bound node payload.

The regression script asserts the echoed JSON contains
`/input/extensions/channel_data/r1_principals` (snake_case) with the
original payload preserved verbatim.

## End-to-end pipeline

For this test to PASS at full e2e, three layers must cooperate:

1. The inbound provider WASM (`messaging-webchat-gui`) must place
   `channelData` from the DirectLine activity into
   `envelope.extensions[channel_data]` (snake_case, top-level).
2. `greentic-start` must preserve `envelope.extensions` when building the
   flow input shape (`json!({"input": envelope, ...})`). Pinned by
   `messaging_app::tests::run_app_flow_input_preserves_envelope_extensions_channel_data`.
3. `greentic-runner` 0.5.10 must auto-merge `state.input.extensions` into
   each node's WASM-bound payload (`runner/extensions.rs`).

Layers 2 and 3 are verified by their respective unit tests. Layer 1 needs
the published `messaging-webchat-gui:latest` to ship the inbound
`collect_directline_extensions` path; if the OCI image was built before
that fix, the script will fail at the canonical JSON Pointer because
`envelope.extensions` arrives empty.

## Build

The regression script handles this:

```
cargo component build --release --target wasm32-wasip2
greentic-pack build --in . --no-update
```
