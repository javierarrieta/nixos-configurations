/**
 * Compaction model: summarize with a free hosted model instead of the conversation model.
 *
 * Managed by home-manager: this file is linked read-only into
 * ~/.pi/agent/extensions/ by modules/home-manager/dev-tools.nix (piExtensionNames).
 * Edit the repo copy; the linked file cannot be edited.
 *
 * Pi has no "compaction model" setting -- compaction always uses the selected model
 * (docs/compaction.md only exposes reserveTokens/keepRecentTokens). This extension
 * answers `session_before_compact` before Pi's default summarizer, so the summary call
 * goes to OpenRouter and never occupies the local halogen inference slot on llm01.
 *
 * Pi's own summarization prompt, structured summary format, file tracking and cut point
 * are reused: `compact()` is Pi's real compaction function, only the model, auth and
 * headers change. Works with any selected conversation model, so settings.json stays as
 * home-manager declares it (defaultProvider llm01-halogen).
 *
 * Why SUMMARIZERS is ordered this way -- measured 2026-10-17 on pi's real
 * summarization prompt (18 planted exact identifiers):
 *   inkling:free       18/18 kept, 18.6s, 1M ctx / 262k out
 *   laguna-s-2.1:free  14/18 kept, 14.6s, 262k ctx / 32k out
 *
 * Measured 2026-10-18 against openrouter.ai/api/v1 with this machine's key:
 *   - inkling:free is $0 and answers in ~1.5s.
 *   - The :free tier answers 403 "only available on agentic harnesses" without OpenRouter
 *     app attribution headers, so they are added explicitly below. Pi adds them itself
 *     only in the agent stream function (core/provider-attribution.js) and only while
 *     install telemetry is enabled; compact() is called here without a streamFn, so it
 *     goes through completeSimple() and those headers would be missing.
 *   - inkling reasons by default (66 reasoning tokens on a one-word prompt).
 *     reasoning:{effort:"none"} disables it, but compact() exposes no body override, so
 *     summaries pay the reasoning cost. Free tier, so left alone.
 *
 * Branch summaries (/tree) are NOT routed here; they still use the selected model.
 */
import { compact } from "@earendil-works/pi-coding-agent";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/** Tried in order; the first one in the catalog with working auth wins. */
const SUMMARIZERS = [
	{ provider: "openrouter", id: "thinkingmachines/inkling:free" },
	{ provider: "openrouter", id: "poolside/laguna-s-2.1:free" },
];

/** Summaries do not need reasoning, and Pi omits the reasoning param for "off". */
const THINKING = "off" as const;

function attributionHeaders(model: { provider: string; baseUrl: string }): Record<string, string> | undefined {
	const isOpenRouter = model.provider === "openrouter" || model.baseUrl.includes("openrouter.ai");
	return isOpenRouter
		? {
				"HTTP-Referer": "https://pi.dev",
				"X-OpenRouter-Title": "pi",
				"X-OpenRouter-Categories": "cli-agent",
			}
		: undefined;
}

export default function (pi: ExtensionAPI) {
	pi.on("session_before_compact", async (event, ctx) => {
		const { preparation, customInstructions, signal } = event;
		if (signal.aborted) return undefined;

		for (const candidate of SUMMARIZERS) {
			const found = ctx.modelRegistry.find(candidate.provider, candidate.id);
			if (!found) continue;

			const auth = await ctx.modelRegistry.getApiKeyAndHeaders(found);
			if (!auth.ok) {
				ctx.ui.notify(`compaction: ${candidate.provider}/${candidate.id} unavailable (${auth.error})`, "warning");
				continue;
			}

			const model = auth.baseUrl ? { ...found, baseUrl: auth.baseUrl } : found;
			const headers = { ...(auth.headers ?? {}), ...(attributionHeaders(model) ?? {}) };

			ctx.ui.notify(
				`compaction: summarizing ${preparation.tokensBefore.toLocaleString()} tokens with ${model.provider}/${model.id}`,
				"info",
			);

			try {
				// Pi's real compaction: same prompt, same summary format, same file tracking.
				const result = await compact(
					preparation,
					model,
					auth.apiKey,
					headers,
					customInstructions,
					signal,
					THINKING,
					undefined,
					auth.env,
				);
				return { compaction: result };
			} catch (error) {
				if (signal.aborted) return undefined;
				const message = error instanceof Error ? error.message : String(error);
				ctx.ui.notify(`compaction: ${model.provider}/${model.id} failed (${message}), falling back`, "warning");
			}
		}

		// Nothing usable: let Pi summarize with the selected model.
		return undefined;
	});
}
