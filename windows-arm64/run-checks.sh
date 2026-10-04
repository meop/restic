#!/usr/bin/env bash
# Run the WINDOWS-ARM64-TODO.md checks (checks.ps1) on a Windows host over SSH,
# against this checkout's HEAD, and copy the logs back. Run it once on Windows
# ARM64 and once on Windows x64 to compare.
#
# Usage: windows-arm64/run-checks.sh <ssh-host> [ssh-port] [label]
#   e.g. windows-arm64/run-checks.sh metal 22222 resin-arm64
#        windows-arm64/run-checks.sh glass.lan 22 glass-x64
# Environment:
#   SKIP_TESTS=1  skip `go test ./...` (the scenarios only)
#   LOG_DIR       where logs go (default: windows-arm64/logs)
set -euo pipefail

host=${1:?usage: run-checks.sh <ssh-host> [ssh-port] [label]}
port=${2:-22}
label=${3:-$host}
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
cd "$root"

LOG_DIR=${LOG_DIR:-$here/logs}
out=$LOG_DIR/$label-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$out"
ssh_opts=(-o BatchMode=yes -p "$port")
scp_opts=(-o BatchMode=yes -q -P "$port")

archive=$(mktemp --suffix=.tar.gz)
trap 'rm -f "$archive"' EXIT
git archive --format=tar.gz -o "$archive" HEAD

# scp lands relative to the remote home directory.
remote_rel='AppData/Local/restic-windows-checks'
remote_win='$env:LOCALAPPDATA\restic-windows-checks'
skip=${SKIP_TESTS:+-SkipTests}
{
  echo "host=$host:$port label=$label commit=$(git rev-parse --short HEAD) ($(git log -1 --format=%s))"
  ssh "${ssh_opts[@]}" "$host" "New-Item -ItemType Directory -Force $remote_win | Out-Null" </dev/null
  scp "${scp_opts[@]}" "$archive" "$host:$remote_rel/src.tar.gz"
  scp "${scp_opts[@]}" "$here/checks.ps1" "$host:$remote_rel/"
  ssh "${ssh_opts[@]}" "$host" \
    "pwsh -NoProfile -NonInteractive -File $remote_win\\checks.ps1 -Archive $remote_win\\src.tar.gz -Work $remote_win $skip" </dev/null
} 2>&1 | tee "$out/summary.log"
status=${PIPESTATUS[0]}
scp "${scp_opts[@]}" "$host:$remote_rel/logs/*" "$out/" || echo "could not copy remote logs" >&2
echo "logs: $out"
exit "$status"
