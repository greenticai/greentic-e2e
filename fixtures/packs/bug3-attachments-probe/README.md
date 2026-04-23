# bug3-attachments-probe

Minimal app-pack that emits exactly **1 Adaptive Card attachment** plus
`channelData` and `entities` from its flow output. Used as a regression probe
for TASK-082 Bug 3 (WebChat DirectLine envelope-passthrough stripping).

## What it tests

When routed through the WebChat provider (`messaging-webchat-gui`), the probe
output should appear on the DirectLine activity wire as:

```json
{
  "attachments": [{
    "contentType": "application/vnd.microsoft.card.adaptive",
    "content": { "type": "AdaptiveCard", ... }
  }],
  "channelData": { "bug3_probe": true, "probe_version": "1.0" },
  "entities":    [{ "type": "bug3-probe", "id": "attachment-passthrough-check" }]
}
```

**Failure modes caught**:

- `attachments: []` → upstream orchestrator (greentic-start/runner) or provider
  encode is stripping the passthrough (original Bug 3 shape).
- `attachments.length ≥ 2` with byte-identical entries → Bug 4 duplication.
- Missing `channelData` / `entities` → partial strip.

## Attribution

Original reproducer authored by **Paul Hale (3Point)** as part of the
`bug4.zip` bug report shared with the Greentic team on 2026-04-21. Included
here verbatim with the pack id `ai.greentic.bug3.test` so the probe text and
Adaptive Card content remain the canonical assertion target.

## Run via E2E suite

```bash
./scripts/run_webchat_attachments_e2e.sh
```
