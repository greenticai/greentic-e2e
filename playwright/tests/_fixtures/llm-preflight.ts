/**
 * Validate an LLM backend actually answers before a test spends minutes
 * driving `gtc setup` + a full browser flow toward it. Each demo's component
 * calls a different real endpoint (see call sites for which), so probing that
 * same endpoint with the same key is the only check that means anything —
 * checking "is the env var non-empty" tells you nothing about whether the
 * key is valid, expired, rate-limited, or pointed at the wrong provider.
 */

export type LlmPreflightResult = { ok: true } | { ok: false; reason: string };

const PREFLIGHT_TIMEOUT_MS = 10_000;

async function probeChatCompletions(
  url: string,
  apiKey: string,
  model: string,
): Promise<LlmPreflightResult> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), PREFLIGHT_TIMEOUT_MS);
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        model,
        messages: [{ role: "user", content: "ping" }],
        max_tokens: 1,
      }),
      signal: controller.signal,
    });
    if (res.ok) return { ok: true };
    return {
      ok: false,
      reason: `LLM preflight failed: HTTP ${res.status} from ${url}`,
    };
  } catch (err) {
    return {
      ok: false,
      reason: `LLM preflight failed: ${(err as Error).message} calling ${url}`,
    };
  } finally {
    clearTimeout(timer);
  }
}

async function probeOllama(model: string): Promise<LlmPreflightResult> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), PREFLIGHT_TIMEOUT_MS);
  try {
    const res = await fetch("http://127.0.0.1:11434/api/tags", {
      signal: controller.signal,
    });
    if (!res.ok) {
      return {
        ok: false,
        reason: `Ollama preflight failed: HTTP ${res.status} from 127.0.0.1:11434`,
      };
    }
    const body = (await res.json()) as { models?: Array<{ name: string }> };
    const hasModel = body.models?.some((m) => m.name.startsWith(model));
    if (!hasModel) {
      return {
        ok: false,
        reason: `Ollama is up but model "${model}" is not pulled`,
      };
    }
    return { ok: true };
  } catch (err) {
    return {
      ok: false,
      reason: `Ollama preflight failed: ${(err as Error).message} (LOCAL_LLM=1 but no Ollama at 127.0.0.1:11434)`,
    };
  } finally {
    clearTimeout(timer);
  }
}

/**
 * deep-research-demo's research_analyst node runs in the upstream
 * `component-llm` WASM pack, whose `openai` provider ignores the setup-answer
 * `base_url` and always calls api.openai.com — see the KNOWN LIMITATION note
 * in deep-research-demo.spec.ts. So a DeepSeek-shaped key must be validated
 * against api.openai.com (where it will actually be sent), not api.deepseek.com.
 */
export async function checkDeepResearchLlm(): Promise<LlmPreflightResult> {
  if (process.env.LOCAL_LLM === "1") {
    return probeOllama("gemma3");
  }
  const key = process.env.DEEPSEEK_KEY?.trim();
  if (!key) {
    return { ok: false, reason: "needs DEEPSEEK_KEY or LOCAL_LLM=1" };
  }
  return probeChatCompletions(
    "https://api.openai.com/v1/chat/completions",
    key,
    "gpt-4o-mini",
  );
}

/**
 * helpdesk-itsm and pet-daycare's fast2flow LLM tier both use greentic-llm's
 * native ProviderKind::Deepseek, which does call api.deepseek.com for real.
 */
export async function checkDeepseekLlm(): Promise<LlmPreflightResult> {
  const key = process.env.DEEPSEEK_KEY?.trim();
  if (!key) {
    return { ok: false, reason: "DEEPSEEK_KEY not set" };
  }
  return probeChatCompletions(
    "https://api.deepseek.com/v1/chat/completions",
    key,
    process.env.DEEPSEEK_MODEL?.trim() || "deepseek-chat",
  );
}
