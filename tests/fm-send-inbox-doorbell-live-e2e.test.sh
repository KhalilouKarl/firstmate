#!/usr/bin/env bash
# tests/fm-send-inbox-doorbell-live-e2e.test.sh - the live doorbell guard
# (live-harness-optin family).
#
# The steering inbox's one behavioral assumption is that a real worker agent
# follows the constant self-describing doorbell line: list the inbox, read and
# act on its records in numeric order, then mv each into handled/. The
# doorbell names the inbox as "$FM_TASK_INBOX", so each worker is launched the
# way bin/fm-spawn.sh launches it, with FM_TASK_INBOX exported to its home's
# state/<task>.inbox, and receives no brief at all: it must resolve the inbox
# from the doorbell plus its own environment. A stub can only confirm the
# assumption already written into the stub, so per
# .agents/skills/firstmate-coding-guidelines this is proven against every
# INSTALLED verified harness: each is launched idle in an isolated tmux server,
# steered through the REAL fm-send (durable record + doorbell), and must both
# ACT on the instruction (create a named file) and ACKNOWLEDGE it (the mv into
# handled/), failing loudly with the harness name and version.
#
# Run explicitly with FM_SEND_INBOX_LIVE_E2E=1. This test spends a small
# number of real model tokens per installed harness (one short turn each) -
# authorized by the harness-dependent-checks rule. An absent harness is
# reported explicitly and skipped; a run that verified nothing fails rather
# than passing vacuously. Restrict with
# FM_SEND_INBOX_LIVE_HARNESSES="claude codex ..." when needed, and tune the
# per-harness wait with FM_SEND_INBOX_LIVE_TIMEOUT (seconds, default 240).
# Codex replays the generated worker flags; optionally select its model with
# FM_SEND_INBOX_LIVE_CODEX_MODEL. Its reader is paused while fm-send queues
# the doorbell, then resumed: text and Enter must submit even as one burst,
# without a recovery re-ring hiding a missed submission.
# Record the dated per-harness result in
# docs/verification/runtime-backends.md ("Steering-inbox doorbell").
#
# Folder trust: harnesses launch with the repo root as cwd, which the
# operator's machine has normally already trusted; a trust dialog is a real
# unready state and correctly fails that harness's check.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate opt-in FM_SEND_INBOX_LIVE_E2E tmux

unset NO_MISTAKES_GATE

SOCKET="fm-inbox-live-$$"
SESSION="inboxlive"
LAB=$(fm_test_tmproot fm-inbox-live)
LAB=$(cd "$LAB" && pwd)
TIMEOUT=${FM_SEND_INBOX_LIVE_TIMEOUT:-240}
CHECKED=0
FAILED=0
STOPPED_READER=''
STOPPED_IDENTITY=''

pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

cleanup() {
  if [ -n "$STOPPED_READER" ] && \
    [ "$(fm_test_pid_identity "$STOPPED_READER" 2>/dev/null)" = "$STOPPED_IDENTITY" ]; then
    kill -CONT "$STOPPED_READER" 2>/dev/null || true
  fi
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

# fm-send and the composer readiness read both reach tmux through bare `tmux`
# calls, so a PATH shim pins them to the private socket.
SHIM_DIR="$LAB/shim"
mkdir -p "$SHIM_DIR"
REAL_TMUX=$(command -v tmux)
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-inbox-lib.sh"

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 220 -y 50 -c "$ROOT"

harness_version() {  # <binary>
  "$1" --version 2>/dev/null | head -1 || printf 'version-unknown'
}

# Launch <name> idle with its unattended-autonomy flags (the same posture
# bin/fm-spawn.sh uses), so the doorbell-triggered shell actions need no
# interactive approval.
launch_cmd() {  # <name>
  local launch flags isolated=''
  case "$1" in
    claude) printf '%s' 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '\''{"feedbackDrafts":"off"}'\''' ;;
    codex)
      if [ -n "${FM_SEND_INBOX_LIVE_CODEX_MODEL:-}" ]; then
        launch=$(fm_test_capture_codex_launch "$LAB/codex-launch" --mode no-mistakes --yolo off \
          --model "$FM_SEND_INBOX_LIVE_CODEX_MODEL") || return 1
      else
        launch=$(fm_test_capture_codex_launch "$LAB/codex-launch" --mode no-mistakes --yolo off) || return 1
      fi
      flags=$(fm_test_codex_global_flags "$launch")
      # Keep this private session independent of a surrounding Codex run.
      # Older CLIs have no daemon option and need only the environment reset.
      if codex --help 2>/dev/null | grep -q -- '--no-daemon'; then
        isolated='--no-daemon '
      fi
      printf '%s' "env -u CODEX_THREAD_ID codex $isolated$flags"
      ;;
    opencode) printf '%s' "OPENCODE_CONFIG_CONTENT='{\"permission\":{\"*\":\"allow\"}}' opencode" ;;
    pi|pi-signed) printf '%s' "$1" ;;
    grok) printf '%s' 'grok --always-approve' ;;
    kimi) printf '%s' 'kimi --auto' ;;
    muse) printf '%s' 'MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on muse --yolo' ;;
    *) return 1 ;;
  esac
}

# Wait for the harness to look steerable. 0 = the composer classified a
# proven empty; 2 = the readiness budget expired without an empty verdict but
# also without a pending one. The caller proceeds on 2 with a note, because
# that mirrors production exactly: the send path's composer check is ADVISORY
# and skips only on visibly pending text, so a harness whose idle screen the
# classifier cannot positively identify still gets its doorbell (the composer
# matrix guard, not this one, owns re-proving the classifier per release).
wait_ready() {  # <window>
  local win=$1 i=0 budget=60 verdict dismissed=0 screen
  while [ "$i" -lt "$budget" ]; do
    verdict=$(fm_tmux_composer_state "$SESSION:$win")
    [ "$verdict" = empty ] && return 0
    i=$((i + 1))
    # Dismiss one non-trust startup modal (update prompts), as the composer
    # matrix guard does; never Enter, which could accept an upgrade.
    if [ "$dismissed" -eq 0 ] && [ "$i" -ge $((budget / 3)) ]; then
      screen=$(tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null || true)
      if ! printf '%s\n' "$screen" | grep -qi 'trust'; then
        tmux -L "$SOCKET" send-keys -t "$SESSION:$win" Escape 2>/dev/null || true
      fi
      dismissed=1
    fi
    sleep 1
  done
  case "$verdict" in
    pending) return 1 ;;
  esac
  return 2
}

check_harness_doorbell() {  # <name>
  local name=$1 version cmd win="hx-$1" home task acted rec handled i ready_rc pane_pid group reader parent send_rc
  version=$(harness_version "$name")
  cmd=$(launch_cmd "$name") || {
    FAILED=1
    printf 'not ok - %s (%s): could not build the live launch recipe\n' "$name" "$version" >&2
    return 0
  }
  home="$LAB/$name-home"
  mkdir -p "$home/state"
  task="live-$name"
  acted="$LAB/acted-$name"
  tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$win" -c "$ROOT" \
    -- bash -lc "export FM_TASK_INBOX=$(printf '%q' "$home/state/$task.inbox"); $cmd" \
    || { FAILED=1; printf 'not ok - %s (%s): could not launch in the isolated tmux server\n' "$name" "$version" >&2; return 0; }
  tmux -L "$SOCKET" set-window-option -t "$SESSION:$win" automatic-rename off
  tmux -L "$SOCKET" set-window-option -t "$SESSION:$win" allow-rename off
  wait_ready "$win"; ready_rc=$?
  if [ "$ready_rc" -eq 1 ]; then
    FAILED=1
    printf 'not ok - %s (%s): composer stayed visibly pending; the pane is not steerable\n' "$name" "$version" >&2
    tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null | grep '[^[:space:]]' | tail -6 | sed 's/^/#   /' >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  [ "$ready_rc" -eq 0 ] || note "$name ($version): idle composer never classified empty; proceeding as production does (advisory check skips only on pending)"
  printf 'window=%s:%s\nkind=ship\nharness=%s\n' "$SESSION" "$win" "$name" > "$home/state/$task.meta"
  if [ "$name" = codex ]; then
    # Pause the native terminal reader, not its Node shim: stopping the whole
    # pane group did not retain a stopped state in the live pause baseline.
    # Scope discovery to this private pane's group and prove ancestry before
    # signaling; retain start identity so cleanup cannot resume a reused PID.
    pane_pid=$(tmux -L "$SOCKET" display-message -p -t "$SESSION:$win" '#{pane_pid}')
    group=$(ps -o pgid= -p "$pane_pid" | tr -d '[:space:]')
    case "$pane_pid" in
      ''|*[!0-9]*) fail "codex ($version): private pane has no valid process ID" ;;
    esac
    [ "$group" = "$pane_pid" ] || fail "codex ($version): private pane does not own its process group"
    reader=$(ps -axo pid=,pgid=,comm= | awk -v group="$group" \
      '$2 == group && $3 ~ /(^|\/)codex([_-].*)?$/ {print $1}')
    case "$reader" in
      ''|*[!0-9]*) fail "codex ($version): private pane has no unique native reader" ;;
    esac
    parent=$reader
    i=0
    while [ "$parent" != "$pane_pid" ] && [ "$i" -lt 16 ]; do
      parent=$(ps -o ppid= -p "$parent" | tr -d '[:space:]')
      [ -n "$parent" ] || break
      i=$((i + 1))
    done
    [ "$parent" = "$pane_pid" ] || fail "codex ($version): native reader is outside the private pane's ancestry"
    STOPPED_IDENTITY=$(fm_test_pid_identity "$reader") || fail "codex ($version): native reader has no start identity"
    STOPPED_READER=$reader
    [ "$(fm_test_pid_identity "$reader")" = "$STOPPED_IDENTITY" ] || fail "codex ($version): native reader changed before pause"
    kill -STOP "$STOPPED_READER" || fail "codex ($version): could not pause the private reader"
    # Signal delivery is asynchronous; wait for the observed stopped state.
    i=0
    while ! ps -o stat= -p "$reader" | grep -q T && [ "$i" -lt 50 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    ps -o stat= -p "$reader" | grep -q T || fail "codex ($version): private reader did not stop"
  fi
  if FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-send.sh" "$task" \
    "Firstmate live check: run exactly this shell command now: touch $acted - then follow the mv instruction you were given for this message. Reply with one short line." \
    >/dev/null 2>&1; then
    send_rc=0
  else
    send_rc=1
  fi
  if [ -n "$STOPPED_READER" ]; then
    [ "$(fm_test_pid_identity "$STOPPED_READER")" = "$STOPPED_IDENTITY" ] || fail "codex ($version): native reader changed before resume"
    kill -CONT "$STOPPED_READER" || fail "codex ($version): could not resume the private reader"
    STOPPED_READER=''
  fi
  if [ "$send_rc" -ne 0 ]; then
    FAILED=1
    printf 'not ok - %s (%s): fm-send refused the live steer\n' "$name" "$version" >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  fi
  rec="$home/state/$task.inbox/001.msg"
  handled="$home/state/$task.inbox/handled/001.msg"
  [ -f "$rec" ] || {
    FAILED=1
    printf 'not ok - %s (%s): fm-send left no durable inbox record\n' "$name" "$version" >&2
    tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
    return 0
  }
  i=0
  while [ "$i" -lt "$TIMEOUT" ]; do
    [ -f "$handled" ] && [ -e "$acted" ] && break
    # Halfway through, play the watcher's role once: re-ring an unacknowledged
    # message so a doorbell swallowed by a startup or update modal recovers
    # exactly as the production re-ring ladder recovers it.
    if [ "$name" != codex ] && [ "$i" -eq $((TIMEOUT / 2)) ] && [ -f "$rec" ]; then
      fm_task_inbox_ring tmux "$SESSION:$win" "$rec" || true
      note "$name ($version): re-rang the doorbell once (watcher's role) at ${i}s"
    fi
    sleep 1
    i=$((i + 1))
  done
  if [ -f "$handled" ] && [ -e "$acted" ]; then
    CHECKED=$((CHECKED + 1))
    pass "$name ($version): the doorbell reached a real worker, which acted and acked with the mv"
    [ "$name" != codex ] || pass "codex ($version): queued text and Enter submitted after reader pause without a recovery re-ring"
  else
    FAILED=1
    printf 'not ok - %s (%s): doorbell not honored within %ss (acted=%s acked=%s)\n' \
      "$name" "$version" "$TIMEOUT" "$([ -e "$acted" ] && echo yes || echo no)" \
      "$([ -f "$handled" ] && echo yes || echo no)" >&2
    tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$win" 2>/dev/null | grep '[^[:space:]]' | tail -10 | sed 's/^/#   /' >&2
  fi
  tmux -L "$SOCKET" kill-window -t "$SESSION:$win" 2>/dev/null || true
}

HARNESSES=${FM_SEND_INBOX_LIVE_HARNESSES:-'claude codex opencode pi grok kimi muse'}
for h in $HARNESSES; do
  if command -v "$h" >/dev/null 2>&1; then
    check_harness_doorbell "$h"
  else
    note "harness absent, not verified here: $h"
  fi
done

if [ "$FAILED" -ne 0 ]; then
  printf 'not ok - live steering-inbox doorbell guard found failures above\n' >&2
  exit 1
fi
if [ "$CHECKED" -eq 0 ]; then
  printf 'not ok - live steering-inbox doorbell guard verified nothing (no harness installed?)\n' >&2
  exit 1
fi
pass "live steering-inbox doorbell guard: $CHECKED harness(es) honored the doorbell contract"
