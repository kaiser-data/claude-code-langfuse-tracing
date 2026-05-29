#!/usr/bin/env bash
#
# install.sh — set up the Claude Code -> Langfuse Stop hook.
#
# What it does (all idempotent):
#   1. Copies hooks/langfuse_hook.py + langfuse_hook_wrapper.sh into ~/.claude/hooks/
#   2. Builds an isolated venv at ~/.claude/hooks/.venv with a PINNED Langfuse SDK
#      (>=4.0,<5 — the hook depends on SDK-4.x internals; v5 would emit zero traces).
#   3. Merges a Stop-hook entry into ~/.claude/settings.json WITHOUT clobbering any
#      existing hooks (deep JSON merge, deduped).
#
# It does NOT touch your secret (that lives in the Keychain) and does NOT opt any
# project in (that's the per-project settings.local.json — see examples/).
#
# Re-running is safe: copies overwrite, the venv is reused, and the settings entry
# is only added if missing.

set -euo pipefail

# --- locate repo + targets ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_HOOK="$REPO_DIR/hooks/langfuse_hook.py"
SRC_WRAPPER="$REPO_DIR/hooks/langfuse_hook_wrapper.sh"

CLAUDE_DIR="$HOME/.claude"
HOOK_DIR="$CLAUDE_DIR/hooks"
STATE_DIR="$CLAUDE_DIR/state"
VENV_DIR="$HOOK_DIR/.venv"
VENV_PY="$VENV_DIR/bin/python"
SETTINGS="$CLAUDE_DIR/settings.json"
WRAPPER_DEST="$HOOK_DIR/langfuse_hook_wrapper.sh"

LANGFUSE_SPEC="langfuse>=4.0,<5"

say()  { printf '  %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
warn() { printf '⚠ %s\n' "$*" >&2; }
die()  { printf '✗ %s\n' "$*" >&2; exit 1; }

# --- preflight ---
[ -f "$SRC_HOOK" ]    || die "missing $SRC_HOOK — run this from the cloned repo."
[ -f "$SRC_WRAPPER" ] || die "missing $SRC_WRAPPER — run this from the cloned repo."
command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH (need 3.9+)."

PYVER="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
say "python3 = $PYVER"

# --- 1. copy hook + wrapper ---
mkdir -p "$HOOK_DIR" "$STATE_DIR"
cp "$SRC_HOOK"    "$HOOK_DIR/langfuse_hook.py"
cp "$SRC_WRAPPER" "$WRAPPER_DEST"
chmod +x "$WRAPPER_DEST"
ok "installed hook + wrapper into $HOOK_DIR"

# --- 2. venv with pinned SDK ---
if [ ! -x "$VENV_PY" ]; then
    say "creating venv at $VENV_DIR"
    python3 -m venv "$VENV_DIR"
fi
"$VENV_PY" -m pip install --quiet --upgrade pip >/dev/null
say "installing $LANGFUSE_SPEC (this is the pin that matters)"
"$VENV_PY" -m pip install --quiet "$LANGFUSE_SPEC"
INSTALLED_VER="$("$VENV_PY" -c 'import langfuse; print(getattr(langfuse, "__version__", "?"))' 2>/dev/null || echo "?")"
ok "langfuse $INSTALLED_VER in venv"

# --- 3. merge Stop hook into settings.json (deep, non-clobbering) ---
# Use the venv python for a reliable JSON deep-merge. The hook command is the
# wrapper's absolute path so it resolves regardless of the shell's ~ expansion.
HOOK_CMD="$WRAPPER_DEST"
SETTINGS="$SETTINGS" HOOK_CMD="$HOOK_CMD" "$VENV_PY" - <<'PY'
import json, os, sys
from pathlib import Path

settings_path = Path(os.environ["SETTINGS"])
hook_cmd = os.environ["HOOK_CMD"]

data = {}
if settings_path.exists():
    try:
        data = json.loads(settings_path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            print("⚠ settings.json is not a JSON object; leaving it untouched.", file=sys.stderr)
            sys.exit(0)
    except Exception as e:
        print(f"✗ settings.json exists but is invalid JSON ({e}); refusing to overwrite.", file=sys.stderr)
        sys.exit(1)

hooks = data.setdefault("hooks", {})
stop = hooks.setdefault("Stop", [])

def already_registered(stop_list) -> bool:
    for group in stop_list:
        if not isinstance(group, dict):
            continue
        for h in group.get("hooks", []):
            if isinstance(h, dict) and h.get("command") == hook_cmd:
                return True
    return False

if already_registered(stop):
    print("✓ Stop hook already registered in settings.json (no change)")
    sys.exit(0)

stop.append({"hooks": [{"type": "command", "command": hook_cmd}]})

# Backup once, then write atomically.
if settings_path.exists():
    bak = settings_path.with_suffix(".json.bak")
    bak.write_text(settings_path.read_text(encoding="utf-8"), encoding="utf-8")
    print(f"  backed up existing settings.json -> {bak.name}")

settings_path.parent.mkdir(parents=True, exist_ok=True)
tmp = settings_path.with_suffix(".json.tmp")
tmp.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
os.replace(tmp, settings_path)
print("✓ registered Stop hook in settings.json")
PY

cat <<EOF

Next steps:
  1. Store your Langfuse SECRET key in the Keychain (prompts on a hidden line):
       security add-generic-password -U -a "\$USER" -s LANGFUSE_SECRET_KEY -T /usr/bin/security -w

  2. Opt a project in: copy examples/settings.local.json.example to that project's
     .claude/settings.local.json and fill in your PUBLIC key + LANGFUSE_BASE_URL.

  3. Run a session there, idle a moment, then check:
       cat ~/.claude/state/langfuse_hook.log     # expect: Processed N turns in ...
EOF
