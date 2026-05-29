# Managing the hook

Install, uninstall, opt projects in/out, rotate keys, debug, and adapt to Linux.

---

## Install

### Scripted (recommended)

```bash
./scripts/install.sh
```

This is idempotent. It:
1. copies `hooks/langfuse_hook.py` + `langfuse_hook_wrapper.sh` into `~/.claude/hooks/`,
2. builds `~/.claude/hooks/.venv` and installs the **pinned** SDK `langfuse>=4.0,<5`,
3. merges a `Stop` hook into `~/.claude/settings.json` without clobbering existing
   hooks (it backs the file up to `settings.json.bak` first and skips if already present).

Then do the two things the installer can't (secret + per-project opt-in) — see below.

### Manual (no script)

```bash
# 1. copy hook + wrapper
mkdir -p ~/.claude/hooks ~/.claude/state
cp hooks/langfuse_hook.py        ~/.claude/hooks/
cp hooks/langfuse_hook_wrapper.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/langfuse_hook_wrapper.sh

# 2. venv with the PINNED SDK (see the gotcha section — do not skip the pin)
python3 -m venv ~/.claude/hooks/.venv
~/.claude/hooks/.venv/bin/python -m pip install "langfuse>=4.0,<5"
```

Then register the hook in `~/.claude/settings.json`. Merge this into the existing
JSON (don't overwrite the file):

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "/Users/<you>/.claude/hooks/langfuse_hook_wrapper.sh" } ] }
    ]
  }
}
```

Use the **absolute** path to the wrapper.

---

## Store the secret (Keychain)

The secret key never lives in any settings file. The wrapper reads it from the
macOS Keychain at runtime, only for opted-in projects.

```bash
security add-generic-password -U -a "$USER" -s LANGFUSE_SECRET_KEY -T /usr/bin/security -w
```

`-w` prompts for the value on a hidden line — it's never echoed, never in shell
history, never in this repo. `-U` updates the entry if it already exists.

Verify it's retrievable:

```bash
security find-generic-password -a "$USER" -s LANGFUSE_SECRET_KEY -w >/dev/null && echo "secret present"
```

---

## Opt a project in

Tracing is **off everywhere by default**. To enable it for one project, drop a
`settings.local.json` into that project's `.claude/` directory:

```bash
mkdir -p <project>/.claude
cp examples/settings.local.json.example <project>/.claude/settings.local.json
# then edit it: set LANGFUSE_PUBLIC_KEY and LANGFUSE_BASE_URL, remove the _comment keys
```

The file uses Claude Code's `env` block, which is injected into the hook's
environment:

```json
{
  "env": {
    "TRACE_TO_LANGFUSE": "true",
    "LANGFUSE_PUBLIC_KEY": "pk-lf-…",
    "LANGFUSE_BASE_URL": "https://cloud.langfuse.com"
  }
}
```

| Key | Notes |
|---|---|
| `TRACE_TO_LANGFUSE` | Must be exactly `"true"`. Anything else = silent no-op. |
| `LANGFUSE_PUBLIC_KEY` | Your `pk-lf-…` public key. Safe in this gitignored file. |
| `LANGFUSE_BASE_URL` | **Full URL**, not a region code. EU: `https://cloud.langfuse.com` · US: `https://us.cloud.langfuse.com` · self-hosted: e.g. `http://localhost:3000`. Defaults to EU cloud if omitted. |
| `CC_LANGFUSE_DEBUG` | `"true"` for verbose logs. Optional. |
| `CC_LANGFUSE_MAX_CHARS` | Per-field truncation cap (default `20000`). Optional. |

> The hook also accepts `CC_LANGFUSE_PUBLIC_KEY` / `CC_LANGFUSE_SECRET_KEY` /
> `CC_LANGFUSE_BASE_URL` as aliases (checked first), if you prefer namespaced vars.

`settings.local.json` is gitignored by this repo's `.gitignore`; keep it that way
in your own projects too.

### Opt a project out

Delete `<project>/.claude/settings.local.json`, or set `TRACE_TO_LANGFUSE` to
anything other than `"true"`.

---

## Verify it's working

After a session in an opted-in project, idle a moment (the hook fires on `Stop`):

```bash
cat ~/.claude/state/langfuse_hook.log        # expect:  Processed N turns in 0.xx s (session=…)
```

Then open your Langfuse project → **Tracing** → look for traces named
`Claude Code - Turn N` tagged `claude-code`, and the **Sessions** view to see the
whole conversation grouped.

---

## The SDK-pin gotcha (read this if you see zero traces)

The hook depends on **Langfuse SDK 4.x internals** (`_otel_tracer`,
`_create_observation_from_otel_span`) to backdate spans to real timestamps. If the
venv has langfuse **v5+**, every turn fails to emit — the hook raises a clear error,
catches it, logs it, and produces **zero traces** while looking installed.

Symptom: log shows `emit_turn failed: RuntimeError: Langfuse SDK 5.x is missing …`.

Fix:

```bash
~/.claude/hooks/.venv/bin/python -m pip install "langfuse>=4.0,<5"
```

The installer pins this automatically; only manual installs or a `pip install -U`
can break it.

Related: if the venv is **missing entirely**, the wrapper falls back to system
`python3` (wrapper L28). If that python lacks langfuse, the import fails and the hook
exits 0 silently — "ran, no error, no traces". Rebuild the venv to fix.

---

## Debug logging

Set `CC_LANGFUSE_DEBUG=true` in the project's `settings.local.json` `env` block,
run a session, then:

```bash
tail -f ~/.claude/state/langfuse_hook.log
```

Debug lines show stdin size, payload keys, offset/rotation decisions, and per-turn
emit results. The log rotates at 5 MB, keeping 3 backups.

You can also run the hook by hand against a real transcript:

```bash
TRACE_TO_LANGFUSE=true \
LANGFUSE_PUBLIC_KEY=pk-lf-… LANGFUSE_SECRET_KEY=sk-lf-… \
LANGFUSE_BASE_URL=https://cloud.langfuse.com \
CC_LANGFUSE_DEBUG=true \
echo '{"session_id":"test","transcript_path":"/path/to/session.jsonl"}' \
  | ~/.claude/hooks/.venv/bin/python ~/.claude/hooks/langfuse_hook.py
```

---

## Rotate keys

- **Secret:** re-run the `security add-generic-password -U …` command with the new
  value. The `-U` flag overwrites the existing entry; nothing else changes.
- **Public key / host:** edit `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_BASE_URL` in each
  project's `settings.local.json`.

No reinstall needed for either.

---

## Uninstall

```bash
# 1. remove the installed hook files + venv
rm -rf ~/.claude/hooks/langfuse_hook.py ~/.claude/hooks/langfuse_hook_wrapper.sh ~/.claude/hooks/.venv

# 2. remove the Stop entry from ~/.claude/settings.json (edit by hand; delete the
#    object whose command ends in langfuse_hook_wrapper.sh)

# 3. (optional) drop state + logs
rm -f ~/.claude/state/langfuse_hook.log ~/.claude/state/langfuse_state.json ~/.claude/state/langfuse_state.lock

# 4. (optional) remove the secret
security delete-generic-password -a "$USER" -s LANGFUSE_SECRET_KEY

# 5. remove per-project opt-ins
#    delete each <project>/.claude/settings.local.json you created
```

---

## Linux adaptation

The hook (`langfuse_hook.py`) is pure Python and already cross-platform — it uses
`fcntl` only when available (L92) and otherwise proceeds without a lock.

Only the **wrapper** is macOS-specific because it uses the Keychain (`security`).
On Linux, replace the Keychain lookup with your secret store. Two options:

**A. `secret-tool` (libsecret / GNOME Keyring):**

```bash
# store once:
secret-tool store --label="Langfuse" service langfuse key secret
# in the wrapper, replace the `security find-generic-password …` line with:
secret="$(secret-tool lookup service langfuse key secret 2>/dev/null || true)"
```

**B. Plain env var** (less secure — keep it out of git): set `LANGFUSE_SECRET_KEY`
directly in the project `env` block and skip the wrapper's Keychain step entirely
(the hook reads `LANGFUSE_SECRET_KEY` from the environment regardless).

Everything else — venv, settings.json registration, state files — is identical.

---

## Troubleshooting quick table

| Symptom | Likely cause | Fix |
|---|---|---|
| Log says `emit_turn failed: RuntimeError … SDK 5.x` | langfuse v5+ in venv | pin `>=4.0,<5` (above) |
| No log file at all | hook never ran / not opted in | check `Stop` entry in `settings.json`; check `TRACE_TO_LANGFUSE=true` |
| Log: `Missing session_id or transcript_path` | payload shape changed | run with `CC_LANGFUSE_DEBUG=true`, inspect `payload top-level keys` |
| Traces in EU but you're on US | `LANGFUSE_BASE_URL` unset → EU default | set `https://us.cloud.langfuse.com` |
| Ran, no error, no traces | venv missing → system python without langfuse | rebuild venv |
| Keychain prompt every session | expected first time; click "Always Allow" | the `-T /usr/bin/security` in the add command pre-authorizes |
