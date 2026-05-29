# Possibilities

Once your Claude Code sessions land in Langfuse as structured traces, a bunch of
things open up. This is a map of what you can build on top — some with this hook
as-is, some by instrumenting your *other* apps directly.

---

## What you get for free, today

Each turn is a trace (`Claude Code - Turn N`, tagged `claude-code`, grouped by
`session_id`) with generations → nested tool spans, real timestamps, and Anthropic
`usage_details`. From that alone:

- **Session replay** — the Langfuse *Sessions* view reconstructs a whole coding
  session turn by turn.
- **Token & cost dashboards** — `usage_details` (input / output / cache read / cache
  creation) lets Langfuse compute cost per turn, per session, per model. Filter the
  `claude-code` tag and group by `session_id` or `model`.
- **Tool-use analytics** — every tool call is its own span (`Tool: <name>`), so you
  can see which tools dominate, how long they take, and their inputs/outputs.

---

## Model comparison (Opus vs Sonnet vs Haiku)

The generation spans carry `model`. Run the same kind of task across different
models (or let `/model` switch mid-stream) and compare:

- tokens per turn and total cost for equivalent work,
- cache-hit economics (`cache_read_input_tokens` vs `cache_creation_input_tokens`),
- number of turns / tool calls to reach a result.

Filter by the `claude-code` tag, break down by `model`. This is a cheap, real-world
token-economy benchmark using your actual workload instead of synthetic prompts.

---

## Build eval datasets from real sessions

Langfuse can turn traces into **datasets**. Your dev sessions become a source of
realistic examples:

1. Filter traces (e.g. turns where a specific tool was used, or a particular repo).
2. Add interesting turns to a Langfuse dataset (input = user message, expected
   output = the final assistant text already on the trace).
3. Run experiments against that dataset when you change prompts, models, or tooling.

Because the hook records the *final* assistant text as the trace output, curated
turns make decent regression cases for "did this prompt change make things worse?".

---

## Scoring & evals on dev sessions

Attach **scores** to traces — manually in the UI, or programmatically:

- **Manual review**: thumbs-up/down a turn during review; track quality over time.
- **LLM-as-judge**: run a Langfuse evaluator over the `claude-code` traces to score
  helpfulness, correctness, or whether the tool calls matched intent.
- **Heuristic scores**: e.g. flag turns with > N tool calls, or turns that ended
  without resolving (error in last tool result).

Over a few weeks this turns "vibes about whether Claude is helping" into a metric.

---

## Tracing your *other* apps (not Claude Code)

This hook **only** reads Claude Code transcripts. For a Chainlit app, a FastAPI
service, an agent loop, etc., instrument the Langfuse SDK directly — and point it at
the **same** Langfuse project so everything lands together:

```python
from langfuse import Langfuse, observe

langfuse = Langfuse(public_key="pk-lf-…", secret_key="sk-lf-…",
                    host="https://cloud.langfuse.com")

@observe()
def handle_request(user_input: str) -> str:
    # your model call here; @observe captures input/output/timing
    ...
```

For raw Anthropic calls, wrap them in a generation span and forward `response.usage`
as `usage_details` (the same fields this hook uses) so cost math is consistent across
hook-traced and SDK-traced work.

> Keep the SDK in your app on whatever version you like — the **4.x pin only applies
> to the venv this hook runs in** (`~/.claude/hooks/.venv`), because the hook uses
> 4.x internals to backdate spans. Your apps are independent.

---

## Team setups

- **Shared project, per-dev tags**: everyone points at one Langfuse project; add a
  per-developer tag or a metadata field (you can extend the hook's `metadata` /
  `tags` in `emit_turn`) to slice by person.
- **Local-first / privacy**: point `LANGFUSE_BASE_URL` at a self-hosted Langfuse
  (Docker) so transcripts never leave your network. Same hook, different host.
- **Per-repo opt-in**: because opt-in is a per-project `settings.local.json`, you can
  enable tracing only on the repos where it's wanted and leave client/sensitive repos
  untraced (true no-op, no Keychain access).

---

## Extending the hook itself

The emit logic lives in `emit_turn` (`hooks/langfuse_hook.py` L515). Reasonable,
low-risk extensions:

- **More tags / metadata**: add repo name, git branch, or a team id to `tags=` /
  `metadata=` so traces are easier to slice.
- **Coarser granularity**: emit one trace per *session* instead of per *turn* by
  changing the trace grouping (heavier change — turn assembly assumes per-turn).
- **Redaction**: extend `truncate_text` / the content extractors to scrub secrets
  before they reach Langfuse if your transcripts contain sensitive output.

If you modify the hook, note it diverges from the vendored upstream copy — keep the
diff small so you can re-sync when Langfuse updates the original (see `NOTICE`).

---

## What this is *not* good for

- **Real-time, mid-turn tracing** — the hook emits on `Stop` (after each response),
  not while a turn is streaming. For live tracing, instrument the SDK in-process.
- **Non-macOS secret storage out of the box** — the Keychain wrapper is macOS-only;
  see the Linux notes in [`managing.md`](managing.md).
