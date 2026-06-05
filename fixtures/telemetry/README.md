# Telemetry E2E fixtures

Verifies that a running Greentic bundle actually exports telemetry to an OTLP
endpoint — the thing you otherwise can't see from `gtc start` alone.

## What's here

- **`otel-collector-file-export.yaml`** — a minimal OpenTelemetry Collector
  config. Receives OTLP on gRPC `:4317` / HTTP `:4318` and writes every signal
  (logs, metrics, traces) to a single JSON dump (`/etc/otelcol/out/otlp-dump.json`,
  bind-mounted to the host) plus stdout (`debug` exporter). No Prometheus / Loki /
  Grafana — assertions read the dump file directly, so they're deterministic.

## Running

```bash
./scripts/run_telemetry_e2e.sh            # gRPC (host :14317 -> container :4317)
./scripts/run_telemetry_e2e.sh --protocol http
./scripts/run_telemetry_e2e.sh --verbose --keep-running
```

The harness boots the collector, starts a dummy-provider bundle with
`TELEMETRY_EXPORT=otlp-grpc` + `OTLP_ENDPOINT` pointed at it, drives a little
HTTP traffic, then asserts the dump contains OTLP **logs** (`resourceLogs`) for
the configured `service.name`. Metrics/traces are reported but not asserted (the
logs path is the contract here).

The collector publishes on host ports **14317/14318** (not the OTLP-standard
4317/4318) so it won't collide with a developer's own collector or the
greentic-demo `docker/` stack. The bundle's gateway uses **:18080** for the same
reason. Override with `HOST_OTLP_PORT` / `HTTP_PORT`.

## Why logs sometimes don't reach OTLP

`greentic-start` exports OTLP logs via its own bridge today. The standalone
`greentic-runner` only does once it ships `greentic-telemetry >= 0.5.5` (which
added the OTLP logs pipeline). Until then this harness verifies the
greentic-start path; the runner path lights up with the next toolchain bump.
