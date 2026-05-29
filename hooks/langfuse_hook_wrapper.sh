#!/usr/bin/env bash
# Claude Code -> Langfuse hook wrapper.
#
# Purpose: inject the Langfuse secret key from the macOS Keychain ONLY when
# tracing is enabled for the current project (TRACE_TO_LANGFUSE=true), then run
# the hook in its isolated venv. The secret never lives in any settings file.
#
# Fail-open by design: nothing here may break or stall the Claude Code session.
# stdin (the hook JSON payload) is passed straight through to the Python hook.

set -u

HOOK_DIR="$HOME/.claude/hooks"
VENV_PY="$HOOK_DIR/.venv/bin/python"
HOOK="$HOOK_DIR/langfuse_hook.py"

# Only touch the Keychain when this project opted in and the secret isn't
# already in the environment. This keeps every other project from triggering a
# Keychain access on each Stop.
if [ "${TRACE_TO_LANGFUSE:-}" = "true" ] && [ -z "${LANGFUSE_SECRET_KEY:-}" ]; then
    secret="$(security find-generic-password -a "$USER" -s LANGFUSE_SECRET_KEY -w 2>/dev/null || true)"
    if [ -n "$secret" ]; then
        export LANGFUSE_SECRET_KEY="$secret"
    fi
fi

# Prefer the isolated venv; fall back to python3 on PATH if the venv is missing.
if [ -x "$VENV_PY" ]; then
    exec "$VENV_PY" "$HOOK"
else
    exec python3 "$HOOK"
fi
