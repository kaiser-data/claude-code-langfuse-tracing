<div align="center">

# 🔭 Claude Code → Langfuse Tracing

### See *everything* your AI pair-programmer did — without touching a line of code.

Every prompt, every response, every tool call, every token, every timestamp —
replayed into [**Langfuse**](https://langfuse.com) as a clean, nested,
session-grouped timeline.

<br>

![Platform](https://img.shields.io/badge/platform-macOS-000000?logo=apple&logoColor=white)
![Python](https://img.shields.io/badge/python-3.9%2B-3776AB?logo=python&logoColor=white)
![Langfuse](https://img.shields.io/badge/Langfuse-SDK%204.x-1e1e2e)
![Hook](https://img.shields.io/badge/integration-Stop%20hook-7c3aed)
![License](https://img.shields.io/badge/license-MIT-22c55e)
![Code intrusion](https://img.shields.io/badge/code%20intrusion-zero-22c55e)

</div>

---

## 💡 The idea behind it

Coding agents have become a black box. You fire off a task, watch a wall of output
scroll by, and at the end you have *a result* — but no durable record of **how** the
agent got there: which tools it reached for, how many tokens each turn burned, where it
looped, how Opus compares to Sonnet on the same job. That history scrolls off your
terminal and is gone.

But it isn't actually gone. **Claude Code already writes a complete, structured JSONL
transcript of every session to disk.** The data exists — it's just trapped in files
nobody reads.

This project's bet: *don't instrument the agent, instrument the trail it leaves behind.*
A single **`Stop` hook** fires after each response, reads the new lines of that
transcript, reconstructs them into turns, and replays them into Langfuse as proper
traces — generations with nested tool spans, backdated to the moment they really
happened. The result is the exact observability you'd get from wrapping every LLM call
in an SDK… **with zero SDK, zero proxy, and zero risk to your request path.**

## 🦾 Why this is a strong addon

| | |
|---|---|
| 🧊 **Zero code intrusion** | It reads transcripts *after the fact*. No wrapper around your model calls, no proxy, no middleware — nothing that can break or slow down a real coding session. |
| 🛡️ **Truly fail-open** | Every error path exits `0`. The flush runs on a daemon thread capped at 5 s. A slow, broken, or unreachable Langfuse can **never** stall or crash your agent. |
| 🔐 **Secret stays out of git, files & transcripts** | The Langfuse secret lives in the **macOS Keychain**, pulled at runtime only for projects you opt in. Nothing sensitive in `settings.json`, in the transcript, or in version control. |
| ⏱️ **Real timelines, not "now"** | Spans are *backdated* to transcript timestamps, so the Langfuse waterfall shows what actually happened when — tools nested correctly inside generations inside turns. |
| 💸 **Token & cost truth** | Anthropic `usage` (input/output/cache read/cache creation) flows through as `usage_details`, so Langfuse computes real cost per turn, per session, per model. |
| ♻️ **Incremental & cheap** | A byte offset per transcript means each `Stop` emits only *new* turns. Re-runs are near-free and never duplicate. |
| 🎯 **Opt-in per project** | Off everywhere by default. One gitignored file turns it on for exactly the repos you choose; every other project is a true no-op (not even a Keychain touch). |

> **TL;DR** — The cheapest observability you'll ever add: it's already-written data,
> a single hook, and a secret that never leaves your Keychain.

---

Claude Code writes a complete JSONL transcript of every session to disk. This project
ships a **`Stop` hook** that reads those transcripts and replays them into Langfuse as
structured traces. You get a per-turn timeline (generations → nested tool calls) grouped
by session, with token usage and real timestamps — the same view you'd get from
instrumenting an SDK, except nothing in your runtime path changes.

It also ships a **secure, multi-project setup** that keeps your Langfuse secret in the
macOS Keychain instead of a plaintext config file, and scopes tracing to exactly the
projects you opt in.

```
┌────────────────┐   writes    ┌──────────────────────┐
│  Claude Code   │ ──────────▶ │  ~/.claude/.../*.jsonl │   (session transcript)
│   session      │             └──────────┬───────────┘
└──────┬─────────┘                        │ reads new bytes
       │ fires Stop hook                  ▼
       │ (after each response)   ┌──────────────────────┐
       └───────────────────────▶ │  langfuse_hook.py     │
                                 │  parse → turns →      │
                                 │  backdated spans      │
                                 └──────────┬───────────┘
                                            │ batched, async, 5s cap
                                            ▼
                                 ┌──────────────────────┐
                                 │      Langfuse         │  traces / generations / tools
                                 └──────────────────────┘
```

---

## Why bother? (advantages)

| Advantage | What it buys you |
|---|---|
| **Zero code intrusion** | It reads transcripts *after the fact*. No SDK wrapper around your model calls, no proxy, no risk of breaking the request path. |
| **Full fidelity** | Each turn becomes a trace: user prompt → one generation per assistant message → nested tool-call spans, each with input/output and **real timestamps** (backdated, not "now"). |
| **Token & cost visibility** | Anthropic `usage` (input/output/cache read/cache creation) is forwarded as `usage_details`, so Langfuse can compute cost per turn / per session / per model. |
| **Session grouping** | All turns of a Claude Code session share one `session_id`, so the Langfuse *Sessions* view reconstructs the whole conversation. |
| **Fail-open & non-blocking** | Any error exits 0. Flush is capped at 5 s on a daemon thread. A slow or down Langfuse can never stall or break your coding session. |
| **Incremental & cheap** | The hook tracks a byte offset per transcript and only emits *new* turns each time — re-runs are near-free and don't duplicate. |
| **Local-first option** | Point it at self-hosted Langfuse (Docker) instead of cloud; your transcripts never leave your network. |
| **Secret stays out of files & git** | This repo's wrapper pulls the secret from the **Keychain** at runtime. Nothing sensitive in `settings.json`, in the transcript, or in version control. |

### When this is the right tool
- You want to **see and review** what your agent did across long sessions.
- You want **token/cost dashboards** for your Claude Code usage by project or model.
- You want to **build eval datasets** from real sessions (Langfuse can turn traces into datasets).
- You're comparing models (e.g. Opus vs Sonnet) on token economy for the same work.

### When it isn't
- You need **real-time** tracing *during* a turn — this emits on `Stop`, i.e. after each response, not mid-stream.
- You want to trace a **non-Claude-Code app** (Chainlit, a FastAPI service…) — for those, instrument the SDK directly (see [`docs/possibilities.md`](docs/possibilities.md)); this hook only reads Claude Code transcripts.

---

## Quickstart

**Prerequisites:** macOS (for the Keychain wrapper — Linux notes in [`docs/managing.md`](docs/managing.md)), Python 3.9+, a Langfuse project (cloud free tier or self-hosted).

```bash
# 1. Clone
git clone https://github.com/kaiser-data/claude-code-langfuse-tracing.git
cd claude-code-langfuse-tracing

# 2. Run the installer — creates an isolated venv, copies the hook + wrapper,
#    and registers the Stop hook in ~/.claude/settings.json (merges, doesn't clobber).
./scripts/install.sh

# 3. Store your Langfuse secret in the Keychain (prompts on a hidden line —
#    never echoed, never in shell history, never in this repo).
security add-generic-password -U -a "$USER" -s LANGFUSE_SECRET_KEY -T /usr/bin/security -w

# 4. Opt a project in: drop examples/settings.local.json.example into that
#    project's .claude/settings.local.json and fill in your PUBLIC key +
#    LANGFUSE_BASE_URL (https://cloud.langfuse.com EU, https://us.cloud.langfuse.com US).
```

Then run any Claude Code session in that project, let it idle a moment, and check:

```bash
cat ~/.claude/state/langfuse_hook.log     # expect:  Processed N turns in ...
```
…and your Langfuse project's **Tracing** tab for traces named **`Claude Code - Turn N`** tagged `claude-code`.

Full step-by-step (including the manual install without the script) is in
[`docs/managing.md`](docs/managing.md).

---

## The secure setup, in one picture

This is the part most "add a hook" guides skip. The default Langfuse docs put your
**secret key in plaintext** in `.claude/settings.json`. This repo splits config by
sensitivity:

| Lives in | What | Committed to git? |
|---|---|---|
| **macOS Keychain** | `LANGFUSE_SECRET_KEY` (the secret) | never |
| `<project>/.claude/settings.local.json` | `LANGFUSE_PUBLIC_KEY` (public), `LANGFUSE_BASE_URL`, `TRACE_TO_LANGFUSE=true` | gitignored |
| `~/.claude/settings.json` | the hook registration only | n/a (personal global) |

The wrapper script (`hooks/langfuse_hook_wrapper.sh`) only touches the Keychain when
`TRACE_TO_LANGFUSE=true`, so every project you *didn't* opt in stays a silent no-op.

---

## Documentation

- **[docs/how-it-works.md](docs/how-it-works.md)** — the architecture: the Stop hook contract, incremental transcript reading, turn assembly, and how spans are backdated to real timestamps.
- **[docs/managing.md](docs/managing.md)** — install/uninstall, multi-project, key rotation, debug logging, log/state files, the SDK-pin gotcha, Linux adaptation, troubleshooting.
- **[docs/possibilities.md](docs/possibilities.md)** — extensions: scoring/evals on dev sessions, cost dashboards, model comparison, tracing your *other* apps, building datasets, team setups.

---

## Credits & licensing

- **`hooks/langfuse_hook.py`** is the official hook from
  [`langfuse/langfuse-docs`](https://github.com/langfuse/langfuse-docs/blob/main/content/integrations/other/claude-code.mdx)
  (MIT). It's vendored here **unmodified** so you can diff it against upstream. All credit to the Langfuse team. See [`NOTICE`](NOTICE).
- **`hooks/langfuse_hook_wrapper.sh`**, the `scripts/`, `docs/` and examples are original to this repo, MIT-licensed (see [`LICENSE`](LICENSE)).
- This is a community convenience wrapper. Not affiliated with or endorsed by Anthropic or Langfuse.
