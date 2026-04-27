import { mkdir, writeFile, readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { createHash } from "node:crypto";

const REPO = "greenticai/greentic-demo";

export interface AssetTag {
  tag: "latest" | string;
}

export interface DemoAssetNames {
  createAnswers: string;
  setupAnswers: string;
  bundle: string;
  pack: string;
}

export function releaseAssetUrl(filename: string, { tag }: AssetTag): string {
  if (tag === "latest") {
    return `https://github.com/${REPO}/releases/latest/download/${filename}`;
  }
  return `https://github.com/${REPO}/releases/download/${tag}/${filename}`;
}

export function demoAssetNames(demoName: string): DemoAssetNames {
  return {
    createAnswers: `${demoName}-create-answers.json`,
    setupAnswers: `${demoName}-setup-answers.json`,
    bundle: `${demoName}-demo.gtbundle`,
    pack: `${demoName}.gtpack`,
  };
}

export interface DownloadOpts {
  tag?: string;
  cacheDir?: string;
  fetchImpl?: typeof fetch;
}

/** Downloads a single asset to cacheDir/<filename>; reuses cached copy if present. */
export async function ensureAsset(
  filename: string,
  opts: DownloadOpts = {},
): Promise<string> {
  const tag = opts.tag ?? "latest";
  const cacheDir = opts.cacheDir ?? join(process.cwd(), "tmp", "demo-assets", tag);
  const dest = join(cacheDir, filename);

  if (existsSync(dest)) {
    return dest;
  }

  const url = releaseAssetUrl(filename, { tag });
  const fetcher = opts.fetchImpl ?? fetch;
  const res = await fetcher(url, { redirect: "follow" });
  if (!res.ok) {
    throw new Error(`download failed: ${url} → ${res.status} ${res.statusText}`);
  }
  const buf = Buffer.from(await res.arrayBuffer());
  await mkdir(dirname(dest), { recursive: true });
  await writeFile(dest, buf);
  return dest;
}

/** Downloads the canonical setup-answers JSON for a demo and parses it. */
export async function loadSetupAnswers(
  demoName: string,
  opts: DownloadOpts = {},
): Promise<Record<string, unknown>> {
  const path = await ensureAsset(demoAssetNames(demoName).setupAnswers, opts);
  return JSON.parse(await readFile(path, "utf8"));
}

/** Returns the path to the cached bundle file (download if missing). */
export async function ensureBundle(
  demoName: string,
  opts: DownloadOpts = {},
): Promise<string> {
  return ensureAsset(demoAssetNames(demoName).bundle, opts);
}

/** Sha256 of a file — used to detect cache corruption between runs. */
export async function sha256OfFile(path: string): Promise<string> {
  const data = await readFile(path);
  return createHash("sha256").update(data).digest("hex");
}
