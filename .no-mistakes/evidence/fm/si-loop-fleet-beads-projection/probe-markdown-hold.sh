#!/usr/bin/env bash
# Live probe: markdown backend keeps decoding fm-hold-v1 reasons (#6331) in the snapshot.
set -u
WT=/tmp/fm-fleet-nm/worktrees/b7a64a4e38ff/01M3WWV5AE7M0S9ZTF8GT85XSW
. "$WT/bin/fm-hold-reason-lib.sh"
H=$(mktemp -d /tmp/fm-probe.XXXXXX)
trap 'rm -rf "$H"' EXIT
mkdir -p "$H/data" "$H/state" "$H/config" "$H/projects"
printf 'backend="markdown"\n[markdown]\npath="data/backlog.md"\n' > "$H/.tasks.toml"
R=$(fm_hold_reason_encode 'Pick (A) or (B)
100% sure?')
printf '## In flight\n- [ ] held-choice - Decision (repo: fixture) (kind: captain) (hold: %s) (hold-kind: captain)\n' "$R" > "$H/data/backlog.md"
cat "$H/data/backlog.md"
(cd "$H" && env -u FM_ROOT_OVERRIDE FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" \
  FM_CONFIG_OVERRIDE="$H/config" FM_PROJECTS_OVERRIDE="$H/projects" "$WT/bin/fm-fleet-snapshot.sh" --json) \
  | jq -c '.backlog.source, .backlog.error, (.backlog.records[]|{id,hold_reason,hold_kind})'
