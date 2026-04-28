import { test as base, expect, type TestInfo } from "@playwright/test";
import { spawn, type ChildProcess } from "node:child_process";
import { mkdir, writeFile, readFile } from "node:fs/promises";
import { createWriteStream, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { allocatePort } from "./ports";
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

export interface DemoOptions {
  name: string;
  team?: string;
  tenant?: string;
  setupAnswers?: Record<string, unknown>;
  envOverrides?: Record<string, string>;
  skipIfMissingSecrets?: string[];
  releaseTag?: string;
}

interface RunningDemo extends GtcDemo {
  proc: ChildProcess;
}

const GTC_BIN = process.env.GTC_BIN ?? "gtc";
const REPO_TMP_BASE = join(process.cwd(), "tmp");

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

  const createAnswersPath = await ensureAsset(
    demoAssetNames(demoName).createAnswers,
    { tag: releaseTag, cacheDir: join(REPO_TMP_BASE, "demo-assets", releaseTag) },
  );
  await runOrThrow(GTC_BIN, ["wizard", "--answers", createAnswersPath], cacheDir);

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
  return ensureAsset(
    demoAssetNames(demoName).setupAnswers,
    { tag: releaseTag, cacheDir: join(REPO_TMP_BASE, "demo-assets", releaseTag) },
  );
}

async function runOrThrow(
  cmd: string,
  args: string[],
  cwd: string,
  env?: Record<string, string>,
): Promise<void> {
  return new Promise((resolve, reject) => {
    const p = spawn(cmd, args, {
      cwd,
      env: { ...process.env, ...env },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stderr = "";
    p.stderr?.on("data", (d) => (stderr += d.toString()));
    p.on("exit", (code) => {
      if (code === 0) resolve();
      else reject(new Error(`${cmd} ${args.join(" ")} exited ${code}\n${stderr}`));
    });
    p.on("error", reject);
  });
}

async function gtcSetup(
  bundleDir: string,
  setupAnswersPath: string,
  envOverrides?: Record<string, string>,
): Promise<void> {
  await runOrThrow(
    GTC_BIN,
    ["setup", "--non-interactive", bundleDir, "--answers", setupAnswersPath],
    bundleDir,
    envOverrides,
  );
}

/**
 * gtc setup writes config but does NOT populate the dev-store secrets backend
 * the runner reads from at startup. The runner reports
 * `using_env_fallback=false` so env vars are not consulted either. Mirror the
 * pattern in scripts/run_webchat_passthrough_e2e.sh: seed messaging-webchat-gui
 * secrets via `greentic-secrets admin set` before starting the runner. Without
 * this, the WebChat UI gets HTTP 500 on the DirectLine token request.
 *
 * Reads the values from the patched setup-answers JSON, so any value override
 * via DemoOptions.setupAnswers or the demo's patch file is honored.
 */
async function seedWebchatSecrets(
  bundleDir: string,
  setupAnswersPath: string,
  team: string,
): Promise<void> {
  const answers = JSON.parse(await readFile(setupAnswersPath, "utf8"));
  const webchat = answers?.setup_answers?.["messaging-webchat-gui"];
  if (!webchat || typeof webchat !== "object") return;

  const storePath = join(bundleDir, ".greentic", "dev", ".dev.secrets.env");
  await mkdir(dirname(storePath), { recursive: true });

  for (const [name, value] of Object.entries(webchat)) {
    if (typeof value !== "string") continue;
    await runOrThrow(
      "greentic-secrets",
      [
        "admin", "set",
        "--env", "dev",
        "--tenant", team,
        "--store-path", storePath,
        "--visibility", "team",
        "--category", "messaging-webchat-gui",
        "--name", name,
        "--value", value,
      ],
      bundleDir,
    );
  }
}

async function applyAnswersPatch(
  demoName: string,
  workerIndex: number,
  upstreamAnswersPath: string,
): Promise<string> {
  const upstream = JSON.parse(await readFile(upstreamAnswersPath, "utf8"));
  const patchPath = join(
    process.cwd(),
    "tests",
    "_fixtures",
    "demo-patches",
    `${demoName}.json`,
  );
  if (!existsSync(patchPath)) {
    return upstreamAnswersPath;
  }
  const patch = JSON.parse(await readFile(patchPath, "utf8"));
  const merged = deepMerge(upstream, patch);
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

async function gtcStart(
  bundleDir: string,
  logFile: string,
  envOverrides?: Record<string, string>,
): Promise<ChildProcess> {
  // greentic-runner --bindings expects extracted .gtbind files which only exist
  // after greentic-start mounts the bundle's squashfs. Calling runner directly
  // errors with "at least one gtbind file is required". Use greentic-start
  // start --config bundle.yaml — it handles the squashfs mount + spawns the
  // runner with correct bindings. Trade-off: greentic-start does not expose a
  // --port flag (only --admin-port), so the runner binds to its default 8080.
  // Tests run with workers: 1 (serialized) to avoid port collision; this is
  // acceptable for the PR-1 walking skeleton (one demo) and for PR-2 (~12
  // demos × ~1min ≈ 12 min wall clock per matrix cell).
  await mkdir(join(bundleDir, "..", "logs"), { recursive: true }).catch(() => {});
  const logStream = createWriteStream(logFile, { flags: "w" });
  const proc = spawn(
    "greentic-start",
    [
      "start",
      "--config", join(bundleDir, "bundle.yaml"),
      "--cloudflared", "off",
      "--ngrok", "off",
      "--quiet",
    ],
    {
      cwd: bundleDir,
      env: { ...process.env, ...envOverrides },
      stdio: ["ignore", "pipe", "pipe"],
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
        `greentic-runner exited ${proc.exitCode} before /readyz; check attached log`,
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
  throw new Error(`/readyz not ready after ${timeoutMs}ms (last: ${String(lastErr)})`);
}

async function stopGtc(proc: ChildProcess): Promise<void> {
  if (proc.exitCode !== null) return;
  proc.kill("SIGTERM");
  const killed = await Promise.race([
    new Promise<boolean>((res) => proc.once("exit", () => res(true))),
    sleep(5_000).then(() => false),
  ]);
  if (!killed && proc.exitCode === null) {
    proc.kill("SIGKILL");
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

      // greentic-start does not expose --port; runner uses default 8080.
      // Tests must run with workers: 1 (set in playwright.config.ts) to avoid
      // collision. The allocatePort helper is kept for future when an upstream
      // port flag lands.
      const port = 8080;
      const releaseTag = opts.releaseTag ?? "latest";

      const bundleDir = await ensureBundleExtracted(opts.name, testInfo.workerIndex, releaseTag);

      let setupAnswersPath: string;
      if (opts.setupAnswers) {
        setupAnswersPath = join(bundleDir, "..", `setup-answers-override-${opts.name}.json`);
        await writeFile(setupAnswersPath, JSON.stringify(opts.setupAnswers, null, 2));
      } else {
        const upstreamPath = await downloadSetupAnswers(opts.name, releaseTag);
        setupAnswersPath = await applyAnswersPatch(
          opts.name,
          testInfo.workerIndex,
          upstreamPath,
        );
      }

      await gtcSetup(bundleDir, setupAnswersPath, opts.envOverrides);

      const team = opts.team ?? "default";
      const tenant = opts.tenant ?? "demo";
      // Populate dev-store with messaging-webchat-gui secrets so the runner
      // can issue DirectLine tokens. Without this, WebChat HTML loads but the
      // token endpoint returns 500.
      await seedWebchatSecrets(bundleDir, setupAnswersPath, team);

      const logFile = join(bundleDir, "..", `gtc-${opts.name}-w${testInfo.workerIndex}.log`);
      const proc = await gtcStart(bundleDir, logFile, opts.envOverrides);

      try {
        await waitForReady(port, proc);
      } catch (e) {
        await stopGtc(proc);
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
      };
      created.push(handle);
      return handle;
    };

    await use(factory);

    for (const h of created) {
      await stopGtc(h.proc);
      if (testInfo.status === "failed" || testInfo.status === "timedOut") {
        await testInfo.attach(`gtc-log-${h.name}`, {
          path: h.logFile,
          contentType: "text/plain",
        });
      }
    }
  },
});

export { expect };
