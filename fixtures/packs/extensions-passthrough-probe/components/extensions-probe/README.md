# extensions-probe

Minimal Greentic `component@0.6.0` for the
`2026_04_25_extensions_passthrough` regression script.

When invoked it echoes its received input back as a JSON string in the
`text` field of the bot reply. The flow at `flows/on_message.ygtc` does not
declare an explicit `extensions` mapping, so it relies on the runner's
auto-merge of envelope-level extensions (added by
`greentic-runner` 0.5.10 in `runner/extensions.rs`).

The regression script asserts the echoed JSON contains
`/input/extensions/channel_data/r1_principals` with the original payload
preserved.

## Build

```
cargo component build --release --target wasm32-wasip2
greentic-pack build --in <pack root> --no-update
```

The regression script does this for you.
