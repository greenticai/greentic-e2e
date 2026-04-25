# null-template-probe

Probe pack used by `scripts/regression/null_template_handling.sh`.

## Layout

```
components/null-template-probe/   # echo-input WASM (component@0.6.0)
flows/on_message.ygtc             # bare `{{in.input.deliberately_missing_field}}` template
flows/on_message.ygtc.resolve.json
pack.yaml
```

The probe component echoes its received input back as a JSON string in the
`text` field of the bot reply. The flow's `content` input field uses a
deliberately missing path so the regression assertion validates the exact
contract that the runner's template-renderer fix pins:

> bare `{{expr}}` against a missing or null path renders as `""`,
> not `null` and not "expression not found"

## Why a deliberately missing field

Sending a DirectLine activity with no `text` body is normalized by the
gateway: the activity `type` field is promoted into `text`, so
`{{in.input.text}}` no longer resolves to a missing path. To exercise the
runner-level template fix end-to-end we instead point at a field the
gateway never populates.

## Build

The regression script handles this:

```
cargo component build --release --target wasm32-wasip2
greentic-pack build --in . --no-update
```
