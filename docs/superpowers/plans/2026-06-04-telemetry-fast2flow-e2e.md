# Plan: e2e verification of OTLP telemetry + fast2flow routing

Date: 2026-06-04
Status: implemented — shipped as `scripts/run_telemetry_e2e.sh`,
`fixtures/telemetry/otel-collector-file-export.yaml`,
`playwright/tests/pet-daycare-demo.spec.ts`, and `.github/workflows/telemetry-e2e.yml`.
Retained for the root-cause analysis below (D1-D6), whose product fixes live in
other repos and are still open.

## Goal

Prove, in greentic-e2e, two newly-shipped product capabilities against the
released `gtc` toolchain and the `greentic-demo` bundles:

1. **Telemetry actually reaches an OTLP endpoint** — logs emitted by
   `greentic-runner`/`greentic-start` are received by an OTLP collector.
2. **fast2flow free-text routing works** — a natural-language message is
   routed (dispatched) to the right card, with a visible **confidence/score**,
   and a below-threshold message produces a no-dispatch fallback.

Scope decisions (locked):
- **OTLP sink:** minimal `otel-collector-contrib` with a `file` exporter; assert
  by reading the dumped JSON. No Prometheus/Loki/Grafana.
- **Harness:** both — a **shell harness** for headless OTLP signal verification,
  and a **Playwright spec** for the user-visible fast2flow card dispatch.
- **Verification scope:** logs reaching OTLP + fast2flow routing/confidence
  (happy path + no-dispatch fallback). Metrics/traces are out of scope for this
  PR (collector will receive them; we only assert on logs).

## Background (verified against shipped binaries + greentic-demo)

Telemetry — `greentic-runner` links `greentic-telemetry-0.5.4` + OpenTelemetry
SDK 0.31 with OTLP exporters. Enabled by env:
- `TELEMETRY_EXPORT=otlp-grpc` (→ `OTLP_ENDPOINT=http://localhost:4317`) or
  `otlp-http` (→ `:4318`).
- `service_name` from bundle `telemetry.service_name` or `OTEL_SERVICE_NAME`.
- greentic-demo ships `docker/otel-collector-config.yaml` + a `PLAYBOOK.md`; we
  reuse the receiver shape but swap exporters for `file` to keep CI deterministic.

fast2flow — BM25 free-text router in `greentic-start`. Opt-in via pack capability
`greentic.cap.fast2flow.v1`. Showcased by **pet-daycare-demo** (create/setup
answers already published under `demos/`). Relevant env:
- `FAST2FLOW_MIN_CONFIDENCE` (default `0.5`; pet-daycare needs `0.05`).
- `GREENTIC_FAST2FLOW_INDEXES_PATH`, `GREENTIC_FAST2FLOW_FORCE_ENABLE`, …
Log lines emitted by `greentic-start` (assertion targets):
- `[fast2flow:gate] enter tenant=…`
- `[fast2flow:gate] materialized index from pack -> …`
- `[fast2flow] directive=…`
- `[fast2flow] dispatch -> routeToCardId=<card>`
- `[fast2flow] no dispatch for free text …`
- fallback reply: `I'm not sure what you meant. Tap one of the menu options or rephrase your request.`
Intent index (`apps/pet-daycare-app/assets/intent-index.json`) maps e.g.
`"who is here today"` → `attendance_card`, `"check in Bella"` → `checkin_card`.

## Deliverables

### 1. Minimal OTLP collector config (file exporter)
`fixtures/telemetry/otel-collector-file-export.yaml`
- `otlp` receiver on `:4317` (grpc) + `:4318` (http).
- `batch` processor (small timeout so signals flush fast).
- `file` exporter → `/etc/otelcol/out/otlp-dump.json` (bind-mounted to host).
- pipelines: `logs` (primary, asserted), plus `metrics`+`traces` wired to the
  same file exporter so the dump is rich for debugging even though we only
  assert logs.

### 2. Shell harness: `scripts/run_telemetry_e2e.sh`
Mirrors `run_provider_e2e.sh` / `run_cloud_demo_e2e.sh` conventions (Perl timeout,
cleanup trap, `--verbose`, `--keep-running`, `--dry-run`).

Flow:
1. Start collector: `docker run` (or `docker compose`) the contrib collector with
   the file-export config, mounting an output dir under the work dir. Wait for
   `:4317` to accept connections.
2. Fetch + build a demo bundle (default: `pet-daycare-demo`, also exercises
   fast2flow) via `gtc wizard --answers oci://…/pet-daycare-demo/create:latest`
   then `gtc setup --answers oci://…/pet-daycare-demo/setup:latest <bundle>`.
3. `gtc start <bundle>` with env:
   `TELEMETRY_EXPORT=otlp-grpc`, `OTLP_ENDPOINT=http://127.0.0.1:4317`,
   `OTEL_SERVICE_NAME=pet-daycare-demo-e2e`,
   `FAST2FLOW_MIN_CONFIDENCE=0.05`. Wait for `/readyz`.
4. Drive traffic: POST the webchat ingress / open a session and send a couple of
   messages so the runner emits flow-execution logs (reuse the ingress pattern
   already used by provider-e2e).
5. Assert telemetry: poll the `otlp-dump.json` (up to N retries) until it contains
   `resourceLogs` AND an entry whose resource attribute `service.name ==
   pet-daycare-demo-e2e`. Fail with the collector `docker logs` tail on timeout.
6. (Optional belt-and-suspenders) assert at least one log body mentions
   `flow.execute` / `fast2flow` to show real product logs, not just SDK noise.
7. Teardown: stop demo, stop collector, remove dump (unless `--keep-running`).

Acceptance: dump file contains `resourceLogs` for our `service.name` → "logs are
reaching the OTLP endpoint" is proven headlessly.

### 3. Playwright spec: `playwright/tests/pet-daycare-demo.spec.ts`
Uses the existing `gtc-demo` fixture + `WebChat` page object.

Fixture changes (`playwright/tests/_fixtures/gtc-demo.ts`):
- Extend `DemoOptions` with optional `env` / `fast2flow` knobs so a spec can set
  `FAST2FLOW_MIN_CONFIDENCE` and (optionally) `TELEMETRY_EXPORT`/`OTLP_ENDPOINT`
  on the `greentic-start` child (injection point: `gtcStart`).
- Expose the gtc log file path to the test (already written per-demo) so specs
  can read it for `[fast2flow] …` assertions.

`demo-patches/pet-daycare-demo.json`:
- Set `FAST2FLOW_MIN_CONFIDENCE=0.05` (or via spec env), tunnel `none`,
  `runtime` target — same shape as other patches.

Tests:
- **smoke**: webchat loads, welcome card renders.
- **functional — fast2flow dispatch + confidence**: send `"who is here today"`
  → assert the attendance card renders (`awaitCardWithText(/attendance/i)`), AND
  assert the gtc log contains `[fast2flow] dispatch -> routeToCardId=attendance_card`
  and a `[fast2flow] directive=` line carrying a confidence/score above 0.05.
- **functional — no-dispatch fallback**: send gibberish (`"asdf qwerty zzz"`)
  → assert the bot replies with the `I'm not sure what you meant…` fallback AND
  the log contains `[fast2flow] no dispatch for free text`.
- Soft-skip pattern (like deep-research-demo) if the published pet-daycare answers
  or fast2flow host aren't available in the toolchain channel under test.

Add `pet-daycare-demo.spec.ts` to `playwright.config.ts` `testMatch`.

### 4. CI workflow: `.github/workflows/telemetry-e2e.yml`
- Schedule (e.g. `01:00 UTC`, between provider-e2e 00:30 and cloud-demo 02:00) +
  `workflow_dispatch` with `gtc_version` / `demo_release_version` inputs.
- ubuntu-24.04; install `gtc` via the existing bootstrap; Docker is available on
  GH runners for the collector.
- Step A: run `scripts/run_telemetry_e2e.sh --verbose`.
- Step B (optional, same job or matrix): run the pet-daycare Playwright spec via
  the existing `demo-playwright.yml` matrix mechanics (or just extend that
  workflow's testMatch). Decide during implementation whether to fold the
  Playwright fast2flow spec into `demo-playwright.yml` rather than a new file.
- Upload collector dump + gtc logs as artifacts on failure.

### 5. Docs
- `CLAUDE.md`: add a "Telemetry E2E" + "fast2flow routing" subsection under
  Running Tests and Architecture (env vars, the OTLP dump assertion, the
  pet-daycare fast2flow flow).
- `.secrets-provider.example`: note the (none-required) telemetry env vars and
  `FAST2FLOW_MIN_CONFIDENCE` for local runs.
- Short `fixtures/telemetry/README.md` explaining the file-export collector and
  how to eyeball `otlp-dump.json`.

## Known issue: Loki receives fewer logs than the runner file log

Observed in the demo stack: Loki shows fewer log lines than the runner's local
`GREENTIC_LOGS_DIR` file (system.log equivalent). By design they should match —
both come from the same `tracing` subscriber in `greentic-telemetry-0.5.4`; OTLP
just adds an OpenTelemetry logs bridge (`BatchLogProcessor`) next to the
stdout/file layer. Divergence means filtering/dropping on one hop.

Localize with three vantage points:
`runner file log → [OTLP logs bridge] → collector (debug exporter = docker logs)
→ [otlphttp/loki] → Loki`.

1. `docker logs greentic-demo-otelcol | grep ResourceLogs` (drop the `debug`
   exporter's `sampling_initial/sampling_thereafter` block first — it thins
   collector stdout only, not Loki).
   - **Collector already missing lines → upstream/source loss.** Likely the OTLP
     logs bridge has a narrower level filter than the file layer (`RUST_LOG` /
     telemetry preset), or `telemetry.sampling`/`TELEMETRY_SAMPLING` is thinning,
     or `telemetry.enabled=true but exporter=none`.
   - **Collector has them, Loki doesn't → collector→Loki loss:**
     - **Query/label artifact (most likely "false missing"):** Loki's native OTLP
       ingest promotes only a small set of *resource* attributes to indexed
       labels (`service.name → service_name` yes; `scope_name`, `severity_text`
       **no** — those become structured metadata). The demo `PLAYBOOK.md` queries
       `{service_name="…", scope_name="…"}` / `{… severity_text="ERROR"}` return
       nothing. Correct form: `{service_name="…"} | scope_name="…"` /
       `| severity_text="ERROR"`. → fix is a PLAYBOOK correction in greentic-demo.
     - **Real drops:** compose runs `grafana/loki:3.2.0` with the baked-in default
       config (no limits mounted). Startup log bursts can exceed default
       per-stream/ingestion rate limits → 429 → collector has no retry/queue here
       → dropped. Check `docker logs greentic-demo-loki` for `429`/`rate
       limit`/`out of order`/`too old`.

Implications for this PR:
- The **file-export sink we chose isolates source-side from Loki-side loss** — the
  dump is exactly what the collector received. Add a harness assertion that
  compares OTLP-log line count in the dump against the runner's file-log line
  count (within tolerance) to *catch source-side thinning* as a regression.
- The Loki/PLAYBOOK fixes live in **greentic-demo, not this repo** — file a
  follow-up there (correct LogQL selectors; consider mounting a Loki config with
  raised limits or a collector retry/`sending_queue`). Track as a separate issue.

## Root cause: the log-propagation disconnect (from current source)

Investigated the actual product repos at current HEAD: `greentic-telemetry`,
`greentic-start`, `greentic-runner` (greentic-runner-host), `greentic-component`,
`greentic-interfaces`. There is **no single logging library** — there are two
independent telemetry stacks plus several bypass paths, and only one stack
exports logs to OTLP. That is why Loki is missing logs and why some "appear
different".

### Two separate, inconsistent telemetry init paths
- **greentic-start** uses a bespoke stack in `greentic-start/src/otlp_telemetry.rs`
  — depends directly on `opentelemetry-appender-tracing` + `opentelemetry-otlp`
  (features `trace, metrics, logs`). `install_layer()` builds tracer **and meter
  **and `SdkLoggerProvider`**, and wires `OpenTelemetryTracingBridge` so its
  `tracing` events ARE exported as OTLP **logs** (otlp_telemetry.rs:13-19, 134,
  205-207). Tracer scope `"greentic-start"`; `service.name` is **dynamic** (bundle
  `telemetry.service_name` → bundle dir name → `"greentic"`, lib.rs:501-511). It
  also downgrades noisy targets (`hyper`,`h2`,`wasmtime`,…) to `warn`
  (lib.rs:468,519-528).
- **greentic-runner** inits via the `greentic-types` `telemetry-autoinit` macro →
  the **greentic-telemetry** crate, whose `opentelemetry` dep is features
  `["trace","metrics"]` **only — no `logs`, no appender-tracing** (greentic-
  telemetry/Cargo.toml:78). Grep confirms **no `SdkLoggerProvider`/`LogExporter`/
  appender anywhere on the runner path.** `service.name` is **hardcoded
  `"greentic-runner"`** (runner-host/src/lib.rs:396); tracer scope
  `"greentic-telemetry"`.
  → **greentic-runner's `tracing` logs never become OTLP logs.** They reach the
  collector (if at all) only as span-events, not log records — so Loki, whose
  logs pipeline ingests OTLP logs, never sees them. This is the single biggest
  cause of "Loki missing logs".

### High-value greentic-start logs bypass tracing entirely
Even within greentic-start's logs-exporting stack, these never go through
`tracing`, so they never reach OTLP/Loki — only local files/stdout:
- `operator_log::*` → `operator.log` — **including every `[fast2flow] …` line**
  (fast2flow/mod.rs:44,58,69; directive log at mod.rs:140-142).
- `flow_log::*` → `flow.log` (lib.rs:247).
- numerous `println!`/`eprintln!` (start runtime, qa_persist; runner-host
  engine.rs:1282 `eprintln!`).

### fast2flow confidence is computed then discarded
`RoutingDirective` carries real `confidence` (0.8/0.9/0.95/1.0,
fast2flow/mapper.rs:134-213) but mapper.rs:2-3 has
`FIXME(observability): confidence + reason are dropped — emit a tracing span
carrying both.` So confidence is **never emitted** anywhere today — not logs, not
metrics, not spans. Any e2e assertion on a numeric confidence will fail until
this FIXME is fixed upstream.

### Guest (WASM) log bridge mangles records, and the good bridge is unused
The host actually wires `TelemetryLoggerHost::log` in
`greentic-runner-host/src/pack.rs:991-1017` → a single
`tracing::info!(… "telemetry log from pack")`: **constant message, forced INFO,
guest fields collapsed into one JSON attribute** (guest severity + real message
lost). A nicer bridge exists in `greentic-telemetry/src/wasm_host.rs`
(`target:"greentic.wasm"`, preserves level, `runtime="wasm"`) but is **not** the
one wired by the runner host. So guest logs look different again — and (per the
runner having no OTLP logs exporter) don't reach Loki as logs anyway.

### Disconnect summary
| # | Disconnect | Evidence | Effect |
|---|---|---|---|
| D1 | runner/greentic-telemetry exports traces+metrics only, **no OTLP logs** | telemetry Cargo.toml:78; no appender on path | runner logs absent from Loki |
| D2 | start vs runner use **separate init**, different `service.name` & scope | otlp_telemetry.rs vs autoinit macro; "greentic-start"/dynamic vs "greentic-telemetry"/"greentic-runner" | streams split / mismatched; non-uniform records |
| D3 | `[fast2flow]`, flow.log, many lines emitted via **operator_log/flow_log/println**, not tracing | fast2flow/mod.rs, flow_log.rs, lib.rs:247 | never reach OTLP even from start |
| D4 | fast2flow **confidence dropped** (FIXME) | mapper.rs:2-3,134-213 | nothing to assert on |
| D5 | guest bridge **constant msg/forced INFO**; good bridge unused | pack.rs:991-1017 vs wasm_host.rs | guest logs opaque + different shape |
| D6 | Loki label vs structured-metadata + PLAYBOOK query bug (prior section) | greentic-demo PLAYBOOK.md | logs look "missing" when present |

### Recommended product fixes (separate repos, not this e2e PR)
1. **Unify on one telemetry init.** Either make `greentic-telemetry` the single
   entry (add a `logs` feature + `OpenTelemetryTracingBridge`) and have BOTH
   start and runner call it, or have runner adopt start's `otlp_telemetry`. One
   `service.name` scheme, one scope convention, one filter policy.
2. **Add the OTLP logs exporter to the runner path** (D1) — the highest-impact fix
   for "Loki missing logs".
3. **Route operator_log/flow_log/fast2flow through `tracing`** (or dual-write) so
   they reach OTLP, with structured fields (tenant, flow_id, route, confidence).
4. **Resolve the fast2flow confidence FIXME** (D4): emit a span/log with
   `confidence`, `reason`, `routeToCardId`.
5. **Wire the good guest bridge** (`wasm_host.rs` semantics) and preserve guest
   severity + message + `runtime="wasm"` (D5).
6. **Fix greentic-demo PLAYBOOK LogQL** to use `|` filters for non-label fields
   (D6).

### How this e2e PR catches these
The file-export collector makes each disconnect observable as a test:
- assert OTLP **logs** received for BOTH `service.name=greentic-start*` AND the
  runner service — catches D1/D2 regressions.
- compare runner file-log vs dump log-count — catches source-side thinning.
- fast2flow routing asserted via webchat card dispatch + the **operator.log**
  `[fast2flow] dispatch -> routeToCardId=` line (NOT OTLP, per D3); add a
  confidence assertion guarded/xfail until D4 lands.

## Open questions / risks
- **gtc channel coverage:** confirm the `stable` toolchain (1.0.20) already wires
  `TELEMETRY_EXPORT`/`OTLP_ENDPOINT` end-to-end, not only `dev`. If only `dev`,
  gate the telemetry job to the dev channel and soft-skip stable.
- **Log emission via OTLP logs pipeline:** verify the runner exports *logs*
  (not just traces/metrics) over OTLP by default, or whether a
  `telemetry.exporter`/log-level knob in the bundle is required. First
  implementation step is a throwaway local run asserting `resourceLogs` appears
  in the dump; if not, add the needed bundle/env config to the harness.
- **fast2flow confidence in logs:** confirm the `[fast2flow] directive=` /
  `dispatch` line actually prints a numeric score; if the score only appears at a
  higher log verbosity, set `RUST_LOG` accordingly in the harness/fixture.
- **Webchat traffic in the shell harness:** decide between driving a real webchat
  session vs a simpler ingress POST to generate flow-execution logs; the latter
  is more robust headlessly.

## Implementation order
1. Throwaway spike: collector(file) + `gtc start pet-daycare` + drive traffic →
   confirm `resourceLogs` and the exact `[fast2flow] …` log strings/score. This
   resolves the two main risks before writing committed code.
2. `fixtures/telemetry/otel-collector-file-export.yaml` + `scripts/run_telemetry_e2e.sh`.
3. Playwright fixture knobs + `pet-daycare-demo.spec.ts` + patch + testMatch.
4. CI workflow + docs.
5. Run both locally (`run_telemetry_e2e.sh` and the new spec) and iterate.
