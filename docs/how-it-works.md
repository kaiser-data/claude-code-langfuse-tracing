# How it works

This explains the architecture of the Claude Code → Langfuse tracing hook: the
`Stop`-hook contract, how transcripts are read incrementally, how turns are
assembled, and how spans are backdated to real timestamps.

All file references are to `hooks/langfuse_hook.py` (the vendored upstream hook)
and `hooks/langfuse_hook_wrapper.sh` (this repo's Keychain wrapper).

---

## The pipeline

```
Claude Code session
      │  (writes JSONL transcript continuously)
      ▼
~/.claude/projects/<…>/<session>.jsonl
      │  on every assistant response, Claude Code fires the Stop hook
      ▼
langfuse_hook_wrapper.sh   ── injects LANGFUSE_SECRET_KEY from Keychain (opt-in only)
      │                       and execs the venv python
      ▼
langfuse_hook.py           ── reads ONLY new bytes → assembles turns → emits spans
      │                       (batched, async flush capped at 5 s)
      ▼
Langfuse                   ── one trace per turn: generations → nested tool spans
```

---

## The Stop-hook contract

Claude Code fires `Stop` after each assistant response and passes a JSON payload
on **stdin**. The hook only needs two fields, and tolerates several spellings of
each (`extract_session_and_transcript`, L185):

- a **session id** — `sessionId` / `session_id` / `session.id`
- a **transcript path** — `transcriptPath` / `transcript_path` / `transcript.path`

If either is missing, the hook **fails open** (returns 0, does nothing; L703).
It never guesses the transcript location.

The wrapper passes stdin straight through (`exec`, no buffering) so the payload
reaches Python untouched.

### Two gates before anything happens

1. **The wrapper** only touches the Keychain when `TRACE_TO_LANGFUSE=true` and the
   secret isn't already in the environment (wrapper L20). Every project you didn't
   opt in causes zero Keychain prompts.
2. **The hook** re-checks `TRACE_TO_LANGFUSE == "true"` (L690) and requires both a
   public and secret key (L697). Missing any → return 0.

So a non-opted-in project is a true no-op at both layers.

---

## Incremental transcript reading

The transcript grows as the session continues, and the hook fires many times per
session. Re-parsing the whole file every time would be wasteful and would
duplicate traces. Instead the hook keeps a **byte offset per (session, transcript)**
in `~/.claude/state/langfuse_state.json`.

`read_new_jsonl` (L347):
- seeks to the saved offset and reads only the new bytes,
- keeps a `buffer` for a trailing partial line (a row still being written),
- detects truncation/rotation (`file_size < offset`) and restarts from 0,
- parses complete lines as JSON, skipping anything unparseable.

State is written back under a best-effort `fcntl` file lock
(`langfuse_state.lock`, L719) so concurrent Stop hooks don't corrupt it.
Entries older than 30 days are pruned on save (L139) to keep the file bounded.

The state key is `sha256(session_id::transcript_path)` (L161) — stable even if a
session id ever collides.

---

## Turn assembly

`build_turns` (L403) groups the flat row stream into turns. A **turn** is:

```
one user message (not a tool result)
  → one or more assistant messages
  → tool_result rows (which arrive as role=user with tool_result content blocks)
```

Key details:
- A new non-tool-result **user** message flushes the previous turn and starts a new one.
- Assistant messages are **deduped by `message.id`**, latest row wins (L457) — Claude
  Code rewrites a streaming assistant row multiple times.
- **Tool results are matched to tool calls by `tool_use_id`** (L438), latest wins.
- Assistant rows seen before any user message are ignored (L453).

Because reads are incremental, a turn can span two hook invocations; the partial-line
`buffer` and offset make the next read continue cleanly.

---

## Emitting to Langfuse, backdated

Each turn becomes a trace named **`Claude Code - Turn N`**, tagged `claude-code`,
grouped by `session_id` via `propagate_attributes` (L532).

Structure emitted (`emit_turn`, L515):
- **Trace span** — input = the user message, output = the final assistant text.
- **One generation per assistant message** (`Claude Generation k`) — model, input
  (user msg for the first, prior tool results for later ones), output (text +
  `tool_calls`), and Anthropic **`usage_details`** when present.
- **One tool span per `tool_use`** (`Tool: <name>`), nested under its generation,
  with the tool input and the matched tool-result output.

### Why "backdated" matters

Langfuse SDK 4.x's `start_observation()` has no `start_time` argument, so naively
emitting would stamp everything with "now" — collapsing the real timeline. The hook
works around this in `_start_backdated` (L477): it talks to the underlying **OTel
tracer** directly (`langfuse._otel_tracer.start_span(start_time=…)`) and wraps the
result with `_create_observation_from_otel_span`. Timestamps come from the transcript
rows (`parse_ts`, L313), converted to epoch nanoseconds (`_to_ns`, L470).

Result: spans land at the wall-clock time they actually happened, and the timeline
nests tools inside generations inside the turn correctly (generations are ended
*after* their tools, L668).

> **This is the SDK-pin gotcha.** `_otel_tracer` / `_create_observation_from_otel_span`
> are SDK-4.x internals. The hook explicitly checks for them and raises a clear error
> naming the fix (L492). Installing langfuse v5+ would make every `emit_turn` throw,
> get caught (L746), and emit **zero** traces. The installer pins `>=4.0,<5`.

---

## Fail-open & non-blocking, everywhere

- The langfuse import itself is wrapped — if it's not installed, the script
  `sys.exit(0)` immediately (L21).
- Every error path in `main()` returns 0 (L757–763).
- The final flush+shutdown runs on a **daemon thread joined with a 5 s cap**
  (L765–778), so a slow or unreachable Langfuse can never stall your coding session.
- Field text is truncated at `CC_LANGFUSE_MAX_CHARS` (default 20000) with a sha256
  recorded for the original (L270), bounding payload size.

The design guarantee: tracing can fail in any way and your Claude Code session is
unaffected.

---

## Where state lives

| Path | What |
|---|---|
| `~/.claude/hooks/langfuse_hook.py` | the hook (installed copy) |
| `~/.claude/hooks/langfuse_hook_wrapper.sh` | the Keychain wrapper |
| `~/.claude/hooks/.venv/` | isolated venv with pinned `langfuse` |
| `~/.claude/state/langfuse_state.json` | per-session byte offset + turn count |
| `~/.claude/state/langfuse_state.lock` | fcntl lock for the state file |
| `~/.claude/state/langfuse_hook.log` | rotating log (5 MB × 3) |

See [`managing.md`](managing.md) for operating all of this.
