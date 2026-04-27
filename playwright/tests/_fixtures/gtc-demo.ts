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
  const cacheDir = join(REPO_TMP_BASE, `worker-${workerIndex}`, demoName);
  const bundlePath = join(cacheDir, `${demoName}-demo-bundle`);
  if (existsSync(join(bundlePath, "bundle.yaml"))) {
    return bundlePath;
  }
  await mkdir(cacheDir, { recursive: true });

  const createAnswersPath = await ensureAsset(
    demoAssetNames(demoName).createAnswers,
    { tag: releaseTag, cacheDir: join(REPO_TMP_BASE, "demo-assets", releaseTag) },
  );
  await runOrThrow(GTC_BIN, ["wizard", "--answers", createAnswersPath], cacheDir);

  if (!existsSync(bundlePath)) {
    throw new Error(`expected ${bundlePath} after gtc wizard, not found`);
  }
  return bundlePath;
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

async function applyAnswersPatch(
  demoName: string,
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
  const dest = join(REPO_TMP_BASE, "patched-answers", `${demoName}.json`);
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
  port: number,
  logFile: string,
  envOverrides?: Record<string, string>,
): Promise<ChildProcess> {
  // Per spec §13.5 / preflight finding: gtc start does NOT expose --port. We
  // call greentic-runner directly with --port and the bundle's resolved
  // bindings path. greentic-runner is installed alongside gtc by `gtc install`.
  await mkdir(join(bundleDir, "..", "logs"), { recursive: true }).catch(() => {});
  const logStream = createWriteStream(logFile, { flags: "w" });
  const bindingsPath = join(bundleDir, "resolved");
  const proc = spawn(
    "greentic-runner",
    [
      "--port", String(port),
      "--bindings", bindingsPath,
      "--no-cache",
    ],
    {
      cwd: bundleDir,
      env: { ...process.env, ...envOverrides },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  proc.stdout?.pipe(logStream);
  proc.stderr?.pipe(logStream);
  // ENOENT (missing binary) and other spawn errors land here; without this
  // handler Node would emit an unhandled error and the test would fail with a
  // confusing /readyz timeout instead of the real cause.
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

      const port = allocatePort({
        workerIndex: testInfo.workerIndex,
        fixtureIndex: created.length,
      });
      const releaseTag = opts.releaseTag ?? "latest";

      const bundleDir = await ensureBundleExtracted(opts.name, testInfo.workerIndex, releaseTag);

      let setupAnswersPath: string;
      if (opts.setupAnswers) {
        setupAnswersPath = join(bundleDir, "..", `setup-answers-override-${opts.name}.json`);
        await writeFile(setupAnswersPath, JSON.stringify(opts.setupAnswers, null, 2));
      } else {
        const upstreamPath = await downloadSetupAnswers(opts.name, releaseTag);
        setupAnswersPath = await applyAnswersPatch(opts.name, upstreamPath);
      }

      await gtcSetup(bundleDir, setupAnswersPath, opts.envOverrides);

      const logFile = join(bundleDir, "..", `gtc-${opts.name}-w${testInfo.workerIndex}.log`);
      const proc = await gtcStart(bundleDir, port, logFile, opts.envOverrides);

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

      const team = opts.team ?? "default";
      const tenant = opts.tenant ?? "demo";
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
