# null-template-probe

Minimal Greentic `component@0.6.0` for the `2026_04_25_null_template_handling`
regression script.

When invoked it echoes its received input back as a JSON string in the
`text` field of the bot reply. The flow at `flows/on_message.ygtc` references
a deliberately missing field via `{{in.input.deliberately_missing_field}}`,
so the regression assertion validates that the runner's template renderer
maps a missing path to the empty string `""` instead of erroring or
producing JSON `null`.

## Build

```
cargo component build --release --target wasm32-wasip2
greentic-pack build --in <pack root> --no-update
```

The regression script does this for you.
