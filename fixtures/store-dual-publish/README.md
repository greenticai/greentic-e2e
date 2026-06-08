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

```toml
# throwaway cargo bin's Cargo.toml — pin to the dev line this fixture targets
[dependencies]
greentic-types = ">=1.1.0-dev, <1.2.0-0"
semver = "1"
serde_json = "1"
```

```rust
// src/main.rs — mirrors min_manifest() in greentic-store-server's
// crates/greentic-store-api tests (build_run_gtpack).
use std::collections::BTreeMap;

fn main() {
    let mut manifest = greentic_types::PackManifest {
        schema_version: "1".into(),
        pack_id: greentic_types::PackId::new("test.pack").unwrap(),
        name: None,
        version: semver::Version::new(0, 1, 0),
        kind: greentic_types::PackKind::Application,
        publisher: "test".into(),
        components: Vec::new(),
        flows: Vec::new(),
        dependencies: Vec::new(),
        capabilities: Vec::new(),
        secret_requirements: Vec::new(),
        signatures: greentic_types::PackSignatures::default(),
        bootstrap: None,
        extensions: None,
        agents: BTreeMap::new(),
    };
    manifest.agents.insert(
        "triage".into(),
        serde_json::json!({
            "agent_id": "triage",
            "system_prompt": "be helpful",
            "tools": [],
            "llm": { "provider": "openai", "model": "gpt-4o-mini" }
        }),
    );
    let cbor = greentic_types::encode_pack_manifest(&manifest).unwrap();
    std::fs::write("manifest.cbor", &cbor).unwrap();
}
```

The symbol-table encoder rewrites `pack_id` from the `"test.pack"` string into a
numeric symbol index (`pack_id: 0`, with the string interned under
`symbols.pack_ids`), which is why the decoded fixture shows an integer there.

This mirrors `min_manifest()` in
`greentic-store-server/crates/greentic-store-api/src/handlers/agentic_workers/run.rs`
and `build_run_gtpack()` in that crate's `tests/agentic_workers_flow.rs`. The
e2e itself is the verifier: a malformed manifest surfaces as a `422 decode
manifest.cbor` on the run step.
