# null-template-probe

Probe pack used by `scripts/regression/2026_04_25_null_template_handling.sh`.

The pack must contain a flow with a node whose input field uses a bare
`{{in.input.text}}` template. The regression script posts an empty
DirectLine payload (no `text` field) and asserts:

1. Runtime logs do NOT contain `invalid type: null, expected a string`.
2. The flow produces a bot reply whose rendered `content` is the empty
   string `""`, not `null`.

## Status

This is a stub directory. The probe pack still needs to be authored.

A minimal viable shape:

```
components/null-template-probe/         # WASM that echoes its `content` input
flows/on_message.ygtc                   # node with content: '{{in.input.text}}'
flows/on_message.ygtc.resolve.json
flows/on_message.ygtc.resolve.summary.json
pack.yaml
```

The simplest probe component just serialises its received input back as the
`text` of an outgoing `emit.response`. The script then asserts the
reply's `content` field equals `""`.

## Why a stub

`greentic-runner`'s template renderer has unit tests for missing/null bare
templates (see `crates/greentic-runner-host/src/runner/templating.rs ::
missing_bare_expression_renders_empty_string` and
`null_bare_expression_renders_empty_string`). This e2e test would
complement those by exercising the full ingress → flow → WASM path against
a published payload. Authoring the probe pack is left to a follow-up so
that the script's intent is preserved without blocking today's regression
sweep.
