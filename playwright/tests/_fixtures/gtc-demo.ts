import { test as base, expect, type TestInfo } from "@playwright/test";
import { spawn, type ChildProcess } from "node:child_process";
import { mkdir, writeFile, readFile } from "node:fs/promises";
import {
  createWriteStream,
  existsSync,
  readFileSync,
  mkdtempSync,
  rmSync,
} from "node:fs";
import { createServer } from "node:net";
import { join, dirname } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import {
  ensureAsset,
  demoAssetNames,
} from "../../scripts/download-demo-assets";

export interface GtcDemo {
  name: string;
  team: string;
  tenant: string;
  port: number;
  demoUrl: string;
  bundleDir: string;
  logFile: string;
}

/**
 * Top-level `llm:` block injected into the built bundle.yaml. fast2flow's LLM
 * routing tier (greentic-start `bundle_config::peek_bundle_llm`) reads this
 * block; `gtc wizard` doesn't emit one, so a demo that wants to exercise the
 * LLM tier sets this and the fixture writes it onto bundle.yaml.
 */
export interface BundleLlm {
  provider: string;
  model?: string;
  /** Secret ref or env-var NAME greentic-start resolves the key from. */
  api_key_secret?: string;
  base_url?: string;
  fast2flow_llm_min_confidence?: number;
}

export interface DemoOptions {
  name: string;
  team?: string;
  tenant?: string;
  setupAnswers?: Record<string, unknown>;
  envOverrides?: Record<string, string>;
  skipIfMissingSecrets?: string[];
  releaseTag?: string;
  /** When set, inject this `llm:` block; when null/omitted, strip any present. */
  bundleLlm?: BundleLlm | null;
}

interface RunningDemo extends GtcDemo {
  proc: ChildProcess;
  testHome: string;
}

const GTC_BIN = process.env.GTC_BIN ?? "gtc";
const REPO_TMP_BASE = join(process.cwd(), "tmp");
// Some demos (e.g. pet-daycare-demo, the fast2flow showcase) ship their
// create/setup answers in the greentic-demo repo but are NOT published as
// `releases/latest/download/*` assets, so a release download 404s. For those
// we vendor the answer JSON here and prefer it over the release download. The
// referenced OCI packs ARE published, so `gtc wizard` still builds the bundle.
const VENDORED_ANSWERS_DIR = join(
  process.cwd(),
  "tests",
  "_fixtures",
  "demo-answers",
);

/** Path to a vendored answers JSON if present, else null. */
function vendoredAnswersPath(filename: string): string | null {
  const p = join(VENDORED_ANSWERS_DIR, filename);
  return existsSync(p) ? p : null;
}

/**
 * Resolve a demo answers asset: prefer the vendored copy (for demos not
 * published to greentic-demo releases), else download from the release.
 */
async function resolveAnswersAsset(
  filename: string,
  releaseTag: string,
): Promise<string> {
  return (
    vendoredAnswersPath(filename) ??
    (await ensureAsset(filename, {
      tag: releaseTag,
      cacheDir: join(REPO_TMP_BASE, "demo-assets", releaseTag),
    }))
  );
}

function maskSecret(s: string): string {
  if (s.length <= 8) return "****";
  return `${s.slice(0, 4)}…${s.slice(-4)} (len=${s.length})`;
}

// Defaults for ${VAR} placeholders in answer files when the env var is unset.
// (LLM demos now hardcode DeepSeek model/url, so no OpenAI defaults remain.)
const ENV_PLACEHOLDER_DEFAULTS: Record<string, string> = {};

function substituteEnvPlaceholders<T>(value: T): T {
  if (typeof value === "string") {
    return value.replace(/\$\{([A-Z0-9_]+)\}/g, (_, name: string) => {
      const fromEnv = process.env[name]?.trim();
      if (fromEnv) return fromEnv;
      return ENV_PLACEHOLDER_DEFAULTS[name] ?? "";
    }) as T;
  }
  if (Array.isArray(value)) {
    return value.map((entry) => substituteEnvPlaceholders(entry)) as T;
  }
  if (typeof value === "object" && value !== null) {
    const out: Record<string, unknown> = {};
    for (const [key, entry] of Object.entries(
      value as Record<string, unknown>,
    )) {
      out[key] = substituteEnvPlaceholders(entry);
    }
    return out as T;
  }
  return value;
}

async function ensureBundleExtracted(
  demoName: string,
  workerIndex: number,
  releaseTag: string,
): Promise<string> {
  // gtc wizard's output directory naming is not consistent across demos.
  // Common patterns observed in greentic-demo v0.1.65:
  //   helpdesk-itsm  →  helpdesk-itsm-demo-bundle
  //   deep-research-demo → deep-research-demo-bundle  (no extra '-demo-')
  //   telco-x-demo  →  telco-x-demo-bundle  (no extra '-demo-')
  // We try the canonical pattern first, then fall back to the demo-name as
  // a prefix variants observed in upstream releases.
  const cacheDir = join(REPO_TMP_BASE, `worker-${workerIndex}`, demoName);
  const candidates = [
    `${demoName}-demo-bundle`,
    `${demoName}-bundle`,
    `${demoName}-demo`,
    demoName,
  ];

  const findExisting = (): string | null => {
    for (const cand of candidates) {
      const p = join(cacheDir, cand);
      if (existsSync(join(p, "bundle.yaml"))) return p;
    }
    return null;
  };

  const cached = findExisting();
  if (cached) return cached;

  await mkdir(cacheDir, { recursive: true });

  const createAnswersPath = await resolveAnswersAsset(
    demoAssetNames(demoName).createAnswers,
    releaseTag,
  );
  await runOrThrow(
    GTC_BIN,
    ["wizard", "--answers", createAnswersPath],
    cacheDir,
  );

  const found = findExisting();
  if (!found) {
    throw new Error(
      `bundle dir not found for ${demoName} after gtc wizard; checked ${candidates
        .map((c) => `${cacheDir}/${c}`)
        .join(", ")}`,
    );
  }
  return found;
}

async function downloadSetupAnswers(
  demoName: string,
  releaseTag: string,
): Promise<string> {
  return resolveAnswersAsset(demoAssetNames(demoName).setupAnswers, releaseTag);
}

async function runOrThrow(
  cmd: string,
  args: string[],
  cwd: string,
  env?: Record<string, string>,
  timeoutMs = 90_000,
): Promise<void> {
  // gtc subcommands require a TTY to avoid "IO error: not a terminal"
  const wrapped = wrapWithPty(cmd, args);
  return new Promise((resolve, reject) => {
    const p = spawn(wrapped.cmd, wrapped.args, {
      cwd,
      env: { ...process.env, ...env },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    p.stdout?.on("data", (d) => (stdout += d.toString()));
    p.stderr?.on("data", (d) => (stderr += d.toString()));
    const timer = setTimeout(() => {
      // Kill the PTY wrapper AND its grandchild — `script -q /dev/null cmd`
      // on macOS won't always exit when its child does, leaving zombie
      // gtc setups that block subsequent runs.
      try {
        p.kill("SIGKILL");
      } catch {}
      reject(
        new Error(
          `${cmd} ${args.join(" ")} timed out after ${timeoutMs}ms\nstdout:\n${stdout}\nstderr:\n${stderr}`,
        ),
      );
    }, timeoutMs);
    p.on("exit", (code) => {
      clearTimeout(timer);
      if (code === 0) resolve();
      else
        reject(
          new Error(
            `${cmd} ${args.join(" ")} exited ${code}\nstdout:\n${stdout}\nstderr:\n${stderr}`,
          ),
        );
    });
    p.on("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
  });
}

function wrapWithPty(
  cmd: string,
  args: string[],
): { cmd: string; args: string[] } {
  if (process.platform === "darwin") {
    return { cmd: "script", args: ["-q", "/dev/null", cmd, ...args] };
  }
  if (process.platform === "linux") {
    const shellCmd = [cmd, ...args].map(shellQuote).join(" ");
    return { cmd: "script", args: ["-qec", shellCmd, "/dev/null"] };
  }
  return { cmd, args };
}

function shellQuote(s: string): string {
  if (/^[A-Za-z0-9_./:=+-]+$/.test(s)) return s;
  return `'${s.replace(/'/g, "'\\''")}'`;
}

async function gtcSetup(
  bundleDir: string,
  setupAnswersPath: string,
  envOverrides?: Record<string, string>,
): Promise<void> {
  // --non-interactive: fail fast on missing answers instead of prompting on
  // stdin (which never gets read because Node sets stdio.stdin = "ignore").
  // --no-ui:          skip the web UI launch.
  await runOrThrow(
    GTC_BIN,
    [
      "setup",
      "--non-interactive",
      "--no-ui",
      bundleDir,
      "--answers",
      setupAnswersPath,
    ],
    bundleDir,
    envOverrides,
  );
}

/**
 * Seed the dev-store secrets backend the runner reads at startup, mirroring
 * scripts/run_webchat_passthrough_e2e.sh. Without it the WebChat UI gets HTTP
 * 500 on the DirectLine token request. Values come from the patched
 * setup-answers JSON, so overrides via DemoOptions.setupAnswers or a demo's
 * patch file are honoured.
 *
 * SCOPE MATTERS, and getting it wrong fails silently. The runner resolves a
 * component secret from `secrets://local/<team>/_/<pack>/<name>`, so we must
 * seed with `--env local --tenant <team>`. This seeded `--env dev` for months,
 * which writes somewhere nothing reads — the secret simply is not found, the
 * component proceeds without it, and the only trace is one WARN in the runner
 * log while the failure surfaces much later as a rejected upstream API call.
 * That is exactly how weather-mcp broke: WeatherAPI was called with no key.
 *
 * Note `gtc setup` DOES persist these secrets as well (an earlier version of
 * this comment claimed it does not — it does), but it seals them under the
 * tenant from the answers file (`demo`), while the runner looks them up under
 * the team (`default`). Until those agree upstream, this seeding is what makes
 * the secret resolvable.
 */
async function seedSetupAnswerSecrets(
  bundleDir: string,
  setupAnswersPath: string,
  team: string,
): Promise<void> {
  const answers = JSON.parse(await readFile(setupAnswersPath, "utf8"));
  const setupAnswers = answers?.setup_answers;
  if (!setupAnswers || typeof setupAnswers !== "object") return;

  const storePath = join(bundleDir, ".greentic", "dev", ".dev.secrets.env");
  await mkdir(dirname(storePath), { recursive: true });

  for (const [category, secrets] of Object.entries(setupAnswers)) {
    if (!secrets || typeof secrets !== "object") continue;
    for (const [name, value] of Object.entries(secrets)) {
      if (typeof value !== "string") continue;
      await runOrThrow(
        "greentic-secrets",
        [
          "admin",
          "set",
          // env MUST be `local`, not `dev`. The runtime resolves component
          // secrets from `secrets://local/<team>/_/<pack>/<name>` — seeding
          // under `dev` writes them where nothing ever reads, which is why the
          // weather component called WeatherAPI with no key and every request
          // came back rejected:
          //   secret lookup failed secret=auth.param.get_weather.key
          //   error=not found: secrets://local/default/_/weatherapi-pack/auth_param_get_weather_key
          "--env",
          "local",
          "--tenant",
          team,
          "--store-path",
          storePath,
          "--visibility",
          "team",
          "--category",
          category,
          "--name",
          name,
          "--value",
          value,
        ],
        bundleDir,
      );
    }
  }
}

async function applyAnswersPatch(
  demoName: string,
  workerIndex: number,
  upstreamAnswersPath: string,
  port: number,
): Promise<string> {
  const upstream = JSON.parse(await readFile(upstreamAnswersPath, "utf8"));
  const patchPath = join(
    process.cwd(),
    "tests",
    "_fixtures",
    "demo-patches",
    `${demoName}.json`,
  );
  const patch = existsSync(patchPath)
    ? JSON.parse(await readFile(patchPath, "utf8"))
    : {};
  // The deep-research-demo patch declares a cloud-LLM override gated on
  // DEEPSEEK_KEY (see demo-patches/deep-research-demo.json — DeepSeek via its
  // OpenAI-compatible endpoint). When the key is missing, drop the override
  // entirely so the upstream local-LLM (Ollama) defaults survive for the
  // LOCAL_LLM=1 path.
  if (demoName === "deep-research-demo" && !process.env.DEEPSEEK_KEY?.trim()) {
    const patchSetupAnswers = (
      patch as { setup_answers?: Record<string, unknown> }
    ).setup_answers;
    if (patchSetupAnswers && "deep-research-demo" in patchSetupAnswers) {
      delete patchSetupAnswers["deep-research-demo"];
    }
  }
  const merged = rewriteLocalhostPort(
    substituteEnvPlaceholders(deepMerge(upstream, patch)),
    port,
  );
  // Upstream setup-answers omit platform_setup.tunnel, so `gtc setup` falls
  // back to a stdin selector ("Cloudflare / ngrok / No tunnel") that never
  // gets a keystroke under Playwright. Force "no tunnel" for all demos.
  // Keep an existing answer if the demo overlay sets one explicitly.
  const platformSetup = ((
    merged as { platform_setup?: Record<string, unknown> }
  ).platform_setup ??= {});
  if (platformSetup.tunnel == null) {
    platformSetup.tunnel = { kind: "none" };
  }
  // gtc 1.0.20+ rejects setup with `bundle contains deployer packs ... but
  // answers did not define platform_setup.deployment_targets` when the
  // bundle ships any deployer pack (e.g. deep-research-demo's create-answers
  // pulls in `greentic.deploy.aws:stable`) and the upstream non-cloud
  // setup-answers ship `deployment_targets: []`. Inject a "runtime" target
  // so setup proceeds with local-only deployment. Mirrors the AWS variant
  // answers (deep-research-demo-aws-setup-answers.json) which list
  // "runtime" as the first target.
  if (
    !Array.isArray(platformSetup.deployment_targets) ||
    (platformSetup.deployment_targets as unknown[]).length === 0
  ) {
    platformSetup.deployment_targets = [{ target: "runtime" }];
  }
  if (demoName === "weather-mcp-demo") {
    const weatherApiKey = process.env.WEATHER_API_KEY?.trim();
    const setupAnswers = ((
      merged as { setup_answers?: Record<string, unknown> }
    ).setup_answers ??= {});
    const weather = ((setupAnswers["weatherapi-pack"] as
      Record<string, unknown> | undefined) ??= {});
    if (weatherApiKey) {
      weather["auth_param_get_weather_key"] = weatherApiKey;
      weather["auth_param_get_forecast_weather_key"] = weatherApiKey;
    }
  }
  if (demoName === "deep-research-demo") {
    const setupAnswers = ((
      merged as { setup_answers?: Record<string, unknown> }
    ).setup_answers ??= {});
    const deepResearch = ((setupAnswers["deep-research-demo"] as
      Record<string, unknown> | undefined) ??= {});
    const provider = deepResearch["provider"];
    const model = deepResearch["model"];
    const url = deepResearch["url"];
    const apiKey = deepResearch["api_key_secret"];
    if (provider === "openai") {
      // Cloud branch: DeepSeek via its OpenAI-compatible endpoint (url shows it).
      console.log(
        `[deep-research-demo] llm=cloud provider=${provider} model=${model} url=${url} key=${typeof apiKey === "string" ? maskSecret(apiKey) : "<unset>"}`,
      );
    } else {
      console.log(
        `[deep-research-demo] llm=local provider=${provider ?? "<unset>"} model=${model ?? "<unset>"} url=${url ?? "<unset>"} (LOCAL_LLM=${process.env.LOCAL_LLM ?? "<unset>"})`,
      );
    }
  }
  // Worker-scoped path so parallel workers don't race on the same file.
  const dest = join(
    REPO_TMP_BASE,
    `worker-${workerIndex}`,
    "patched-answers",
    `${demoName}.json`,
  );
  await mkdir(dirname(dest), { recursive: true });
  await writeFile(dest, JSON.stringify(merged, null, 2));
  return dest;
}

function rewriteLocalhostPort<T>(value: T, port: number): T {
  if (typeof value === "string") {
    return value
      .replaceAll("http://localhost:8080", `http://localhost:${port}`)
      .replaceAll("http://127.0.0.1:8080", `http://127.0.0.1:${port}`) as T;
  }
  if (Array.isArray(value)) {
    return value.map((entry) => rewriteLocalhostPort(entry, port)) as T;
  }
  if (typeof value === "object" && value !== null) {
    const out: Record<string, unknown> = {};
    for (const [key, entry] of Object.entries(
      value as Record<string, unknown>,
    )) {
      out[key] = rewriteLocalhostPort(entry, port);
    }
    return out as T;
  }
  return value;
}

/**
 * Inject (or strip) the top-level `llm:` block on a built bundle.yaml so
 * fast2flow's LLM routing tier engages. gtc wizard never emits one. Idempotent:
 * any prior `llm:` block is removed first, so toggling between LLM and no-LLM
 * specs on the same cached bundle is order-independent. Runs after `gtc setup`
 * (which can rewrite bundle.yaml) and before `greentic-start`.
 */
async function applyBundleLlm(
  bundleDir: string,
  llm: BundleLlm | null,
): Promise<void> {
  const bundleYaml = join(bundleDir, "bundle.yaml");
  const original = await readFile(bundleYaml, "utf8");
  const stripped = stripTopLevelBlock(original, "llm");
  let next = stripped;
  if (llm) {
    const block = [`llm:`, `  provider: ${llm.provider}`];
    if (llm.model) block.push(`  model: ${llm.model}`);
    if (llm.api_key_secret)
      block.push(`  api_key_secret: ${llm.api_key_secret}`);
    if (llm.base_url) block.push(`  base_url: ${llm.base_url}`);
    if (llm.fast2flow_llm_min_confidence != null)
      block.push(
        `  fast2flow_llm_min_confidence: ${llm.fast2flow_llm_min_confidence}`,
      );
    next = `${stripped.replace(/\n*$/, "")}\n${block.join("\n")}\n`;
  }
  if (next !== original) await writeFile(bundleYaml, next);
}

/**
 * Remove a top-level YAML block (`<key>:` plus its indented body). bundle.yaml
 * is flat top-level keys, so the block runs until the next non-indented line.
 * Only used to clear an `llm:` block we ourselves write (no blank lines inside).
 */
function stripTopLevelBlock(yaml: string, key: string): string {
  const lines = yaml.split("\n");
  const out: string[] = [];
  const keyRe = new RegExp(`^${key}:(\\s|$)`);
  let i = 0;
  while (i < lines.length) {
    const line = lines[i] ?? "";
    if (keyRe.test(line)) {
      i++;
      while (i < lines.length && /^\s+\S/.test(lines[i] ?? "")) i++;
      continue;
    }
    out.push(line);
    i++;
  }
  return out.join("\n");
}

async function findFreePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        server.close(() => reject(new Error("failed to resolve free port")));
        return;
      }
      const { port } = address;
      server.close((err) => (err ? reject(err) : resolve(port)));
    });
    server.on("error", reject);
  });
}

function deepMerge<T>(base: T, overlay: Partial<T>): T {
  if (typeof base !== "object" || base === null) return overlay as T;
  if (typeof overlay !== "object" || overlay === null) return base;
  const out: Record<string, unknown> = { ...(base as Record<string, unknown>) };
  for (const [k, v] of Object.entries(overlay as Record<string, unknown>)) {
    if (
      typeof v === "object" &&
      v !== null &&
      !Array.isArray(v) &&
      typeof out[k] === "object" &&
      out[k] !== null &&
      !Array.isArray(out[k])
    ) {
      out[k] = deepMerge(out[k], v as Record<string, unknown>);
    } else {
      out[k] = v;
    }
  }
  return out as T;
}

function tailLog(logFile: string, lines = 100): void {
  try {
    const content = readFileSync(logFile, "utf8");
    const tail = content.split("\n").slice(-lines).join("\n");
    console.log(
      `\n=== gtc log (last ${lines} lines): ${logFile} ===\n${tail}\n=== end gtc log ===`,
    );
  } catch {
    console.log(`[gtc-demo] log not readable: ${logFile}`);
  }
}

async function gtcStart(
  bundleDir: string,
  logFile: string,
  port: number,
  testHome: string,
  envOverrides?: Record<string, string>,
): Promise<ChildProcess> {
  await mkdir(join(bundleDir, "..", "logs"), { recursive: true }).catch(
    () => {},
  );
  const logStream = createWriteStream(logFile, { flags: "w" });
  const startEnv: Record<string, string> = {
    RUST_LOG: "info",
    ...(process.env as Record<string, string>),
    ...envOverrides,
    HOME: testHome,
    GREENTIC_GATEWAY_LISTEN_ADDR: "127.0.0.1",
    GREENTIC_GATEWAY_PORT: String(port),
  };
  const proc = spawn(
    GTC_BIN,
    ["start", bundleDir, "--cloudflared", "off", "--quiet"],
    {
      cwd: bundleDir,
      env: startEnv,
      stdio: ["ignore", "pipe", "pipe"],
      detached: true,
    },
  );
  proc.stdout?.pipe(logStream);
  proc.stderr?.pipe(logStream);
  proc.on("error", (err) => {
    logStream.write(`spawn error: ${err.stack ?? err.message}\n`);
  });
  return proc;
}

async function waitForReady(
  port: number,
  proc: ChildProcess,
  timeoutMs = 60_000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  let lastErr: unknown;
  while (Date.now() < deadline) {
    if (proc.exitCode !== null) {
      throw new Error(
        `gtc exited ${proc.exitCode} before /readyz; check attached log`,
      );
    }
    try {
      const res = await fetch(`http://127.0.0.1:${port}/readyz`);
      if (res.ok) return;
      lastErr = `status ${res.status}`;
    } catch (e) {
      lastErr = e;
    }
    await sleep(500);
  }
  throw new Error(
    `/readyz not ready after ${timeoutMs}ms (last: ${String(lastErr)})`,
  );
}

async function stopGtc(handle: RunningDemo): Promise<void> {
  const { proc, testHome } = handle;
  if (proc.exitCode !== null) return;

  // Ask the env-path runtime to shut down via `gtc stop` under the
  // test's isolated HOME — this reaps greentic-start cleanly.
  const stop = spawn(GTC_BIN, ["stop"], {
    env: { ...process.env, HOME: testHome },
    stdio: "ignore",
  });
  await new Promise<void>((res) => stop.once("exit", () => res()));

  // Wait up to 5 s for the parent `gtc start` process to exit.
  const exited = await Promise.race([
    new Promise<boolean>((res) => proc.once("exit", () => res(true))),
    sleep(5_000).then(() => false),
  ]);

  if (!exited && proc.exitCode === null) {
    // Process-group kill: catches gtc AND any surviving greentic-start.
    try {
      process.kill(-proc.pid!, "SIGKILL");
    } catch {}
    await new Promise<void>((res) => proc.once("exit", () => res()));
  }
}

export const test = base.extend<{
  gtcDemo: (opts: DemoOptions) => Promise<GtcDemo>;
}>({
  gtcDemo: async ({}, use, testInfo: TestInfo) => {
    const created: RunningDemo[] = [];

    const factory = async (opts: DemoOptions): Promise<GtcDemo> => {
      for (const key of opts.skipIfMissingSecrets ?? []) {
        if (!process.env[key]) {
          testInfo.skip(true, `missing env var: ${key}`);
        }
      }

      // weather-mcp-demo requires WEATHER_API_KEY; fail on CI if missing, skip locally
      if (opts.name === "weather-mcp-demo") {
        const isCI = !!process.env.GITHUB_ACTIONS;
        if (!process.env.WEATHER_API_KEY?.trim()) {
          const message =
            "WEATHER_API_KEY env var not set (required for weather API calls)";
          if (isCI) {
            throw new Error(`[CI] ${message}`);
          } else {
            testInfo.skip(true, message);
          }
        }
      }

      const port = await findFreePort();
      const releaseTag = opts.releaseTag ?? "latest";

      const bundleDir = await ensureBundleExtracted(
        opts.name,
        testInfo.workerIndex,
        releaseTag,
      );

      let setupAnswersPath: string;
      if (opts.setupAnswers) {
        setupAnswersPath = join(
          bundleDir,
          "..",
          `setup-answers-override-${opts.name}.json`,
        );
        await writeFile(
          setupAnswersPath,
          JSON.stringify(opts.setupAnswers, null, 2),
        );
      } else {
        const upstreamPath = await downloadSetupAnswers(opts.name, releaseTag);
        setupAnswersPath = await applyAnswersPatch(
          opts.name,
          testInfo.workerIndex,
          upstreamPath,
          port,
        );
      }

      // Per-test HOME isolation: each test gets its own HOME so `gtc stop`
      // only affects this test's runtime. Avoids the "polluted HOME" failure
      // mode where gtc stop fails after multiple boot cycles under the same
      // HOME (see port-concurrency probes July 2026).
      const testHome = mkdtempSync(join(REPO_TMP_BASE, "home-"));
      const envWithHome = { ...opts.envOverrides, HOME: testHome };

      await gtcSetup(bundleDir, setupAnswersPath, envWithHome);

      const team = opts.team ?? "default";
      const tenant = opts.tenant ?? "demo";
      // Populate dev-store with setup-answer secrets before startup.
      // Weather and webchat demos both resolve auth through this store.
      await seedSetupAnswerSecrets(bundleDir, setupAnswersPath, team);

      // Toggle fast2flow's LLM routing tier on/off via the bundle's `llm:` block.
      // Always normalize (inject or strip) so a leftover block from another spec
      // never leaks into a BM25-only test on the shared cached bundle.
      await applyBundleLlm(bundleDir, opts.bundleLlm ?? null);

      const logFile = join(
        bundleDir,
        "..",
        `gtc-${opts.name}-w${testInfo.workerIndex}.log`,
      );
      console.log(`[gtc-demo] log → ${logFile}`);
      const proc = await gtcStart(
        bundleDir,
        logFile,
        port,
        testHome,
        opts.envOverrides,
      );

      try {
        await waitForReady(port, proc);
      } catch (e) {
        const earlyHandle: RunningDemo = {
          name: opts.name,
          team,
          tenant,
          port,
          demoUrl: "",
          bundleDir,
          logFile,
          proc,
          testHome,
        };
        await stopGtc(earlyHandle);
        tailLog(logFile);
        await testInfo.attach(`gtc-log-${opts.name}-startup-fail`, {
          path: logFile,
          contentType: "text/plain",
        });
        throw e;
      }

      const handle: RunningDemo = {
        name: opts.name,
        team,
        tenant,
        port,
        demoUrl: `http://127.0.0.1:${port}/v1/web/webchat/${team}/`,
        bundleDir,
        logFile,
        proc,
        testHome,
      };
      created.push(handle);
      return handle;
    };

    await use(factory);

    for (const h of created) {
      await stopGtc(h);
      if (testInfo.status === "failed" || testInfo.status === "timedOut") {
        tailLog(h.logFile);
        await testInfo.attach(`gtc-log-${h.name}`, {
          path: h.logFile,
          contentType: "text/plain",
        });
      }
      rmSync(h.testHome, { recursive: true, force: true });
    }
  },
});

export { expect };
