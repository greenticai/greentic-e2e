# store-dual-publish fixtures

## `manifest.cbor`

A pre-built, static CBOR `PackManifest` carrying exactly one agent (`triage`)
with a minimal LLM config:

```json
{"agent_id":"triage","system_prompt":"be helpful","tools":[],
 "llm":{"provider":"openai","model":"gpt-4o-mini"}}
```

The store's **run** endpoint decodes this with
`greentic_types::decode_pack_manifest`, which uses a symbol-table encoding
(`EncodedPackManifest`) — not a naive serde dump — so it cannot be hand-rolled
reliably from bash/python. The fixture is therefore generated **once** on a dev
machine with cargo and committed as static bytes; CI consumes it verbatim and
needs no cargo/network.

Regenerate (only when the `PackManifest` CBOR shape changes upstream):

```rust
// throwaway cargo bin depending on a local greentic-types checkout
let mut m = greentic_types::PackManifest { /* min fields */, agents: BTreeMap::new(), .. };
m.agents.insert("triage".into(), serde_json::json!({
    "agent_id":"triage","system_prompt":"be helpful","tools":[],
    "llm":{"provider":"openai","model":"gpt-4o-mini"}
}));
let cbor = greentic_types::encode_pack_manifest(&m).unwrap();
std::fs::write("manifest.cbor", &cbor).unwrap();
```

This mirrors `min_manifest()` in
`greentic-store-server/crates/greentic-store-api/src/handlers/agentic_workers/run.rs`
and `build_run_gtpack()` in that crate's `tests/agentic_workers_flow.rs`. The
e2e itself is the verifier: a malformed manifest surfaces as a `422 decode
manifest.cbor` on the run step.
