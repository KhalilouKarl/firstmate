#!/usr/bin/env bash
# Live probe: an fm-hold-v1-encoded captain-hold reason stored in a real Beads home,
# read back through bin/fm-fleet-snapshot.sh (adapter path). Isolated throwaway FM_HOME.
set -u
WT=/tmp/fm-fleet-nm/worktrees/b7a64a4e38ff/01M3WWV5AE7M0S9ZTF8GT85XSW
. "$WT/bin/fm-hold-reason-lib.sh"
H=$(mktemp -d /tmp/fm-probe.XXXXXX)
trap 'rm -rf "$H"' EXIT
mkdir -p "$H/backend/.beads" "$H/data" "$H/state" "$H/config" "$H/projects"
printf 'backend="beads"\n[beads]\npath="%s"\nbinary="br"\nactor="fixture"\n' "$H/backend" > "$H/.tasks.toml"
(cd "$H/backend" && br init --prefix fx --json >/dev/null 2>&1) || { echo "br init failed"; exit 1; }
R=$(fm_hold_reason_encode 'Pick (A) or (B)
100% sure?')
echo "stored reason: $R"
run() { (cd "$H" && env -u FM_ROOT_OVERRIDE FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" \
  FM_CONFIG_OVERRIDE="$H/config" FM_PROJECTS_OVERRIDE="$H/projects" "$@"); }
run tasks-axi add held-choice "Decision" --kind captain --repo fixture >/dev/null
run tasks-axi hold held-choice --reason "$R" --kind captain 2>&1 | tail -3
echo "--- tasks-axi list (raw)"
run tasks-axi list --fields hold_reason,hold_kind | tail -4
echo "--- snapshot records"
run "$WT/bin/fm-fleet-snapshot.sh" --json | jq -c '.backlog.source, (.backlog.records[]|{id,hold_reason,hold_kind})'
echo "--- fleet view"
run "$WT/bin/fm-fleet-view.sh" | grep -i -B1 -A1 'decision\|fm-hold\|Pick' | head
