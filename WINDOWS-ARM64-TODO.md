# Windows ARM64 release readiness

Tracks [#3596](https://github.com/restic/restic/issues/3596).

The fork's native Windows ARM64 Go job already passes:
https://github.com/meop/restic/actions/runs/33244335034

Before adding a Windows ARM64 release asset, compare native ARM64 behavior with
the existing Windows x64 release and record the results below.

## Required checks

- [x] Run the complete `go test ./...` suite on a native Windows ARM64 runner.
      Compare the result with the existing Windows x64 job. Investigate any
      ARM64-only failure; do not treat a failure in another platform's matrix
      job as an ARM64 regression.
- [x] On native Windows ARM64, exercise a local repository end to end:
      `init`, `backup`, `restore`, `check`, and `forget --prune`. Confirm that
      `restic version` reports `windows/arm64`.
- [x] Repeat the backup scenario with `--use-fs-snapshot` on a local NTFS
      volume, then restore and verify the snapshot's contents. This is the
      architecture-sensitive path requested in #3596.
- [x] Run the same VSS scenario on Windows x64 and compare success/failure,
      command output, and error codes. Keep any test repository and debug logs
      free of sensitive paths or credentials before attaching evidence.
- [x] If ARM64 VSS fails while x64 succeeds, investigate the COM/VSS call ABI
      in `internal/fs/vss_windows.go`, especially GUID/IID argument passing.
      The issue discussion notes that Windows ARM64 calling conventions may
      differ from x64.
- [ ] Once the checks pass, trace the release/self-update asset naming and add
      `windows_arm64` to the release build only in a focused follow-up commit.

## Evidence to attach to the eventual PR

- Native Windows x64 and ARM64 job links.
- The exact `go test ./...` result for each architecture.
- Sanitized output for the regular and VSS backup/restore checks.
- The generated release asset name and a `restic self-update` lookup result.

## Results (2026-10-04)

Run with `windows-arm64/run-checks.sh` (scripts in this branch; logs stay
local) on two Windows 11 26H2 machines, both over SSH from an elevated
administrator session, Go 1.27.0:

- ARM64: resin, a QEMU VM (4 cores, 8 GB).
- x64: glass, Windows 11 Pro.

### VSS on ARM64 never ran: restic refused it

`--use-fs-snapshot` on ARM64 failed before touching VSS: "executables
compiled for arm64 can't use VSS on other architectures". The architecture
check in `newVssSnapshot` only allowed amd64 and 386; on a native arm64
process `IsWow64Process` is false, so restic treated it as 32-bit.

Behind that check is the ABI problem #3596 suspected. `IsVolumeSupported`,
`AddToSnapshotSet`, `DeleteSnapshots` and `GetSnapshotProperties` take a
`VSS_ID` (GUID) by value. amd64 passes a 16-byte struct by reference (restic
passes a pointer), 386 on the stack (restic splits it into four words), and
arm64 in two general-purpose registers.

Commit "fs: support VSS snapshots on Windows arm64" in this branch allows
arm64 and passes those GUIDs as two register words. Results on resin:

| Build | `backup --use-fs-snapshot` |
| --- | --- |
| Upstream | Refused with the architecture error |
| Architecture check fixed, GUIDs still as pointers (control) | Access violation (`0xc0000005`) in the first GUID-taking call, `IsVolumeSupported` |
| Both changes | Shadow copy created, snapshot saved, restore byte-identical (125 files), no shadow copy left, `check --read-data` clean |

### Scenarios (both machines)

`restic version` reports the right platform; init, two backups, restore
(byte-identical), `check --read-data`, `forget --keep-last 1 --prune`, and
`check` all pass on both. The VSS backup and restore pass on x64 unchanged
and on ARM64 with the fix.

### `go test ./...`

The same tests fail on both architectures, and each has an environmental
cause, so none is an ARM64 regression:

- Tests that run `true`, `false` and `echo` need Git for Windows' `usr\bin`
  on PATH, as GitHub's runners have; the check script now adds it.
- `TestStdinFromCommand*` runs `python`; on glass that is a uv launcher that
  failed to start Python.
- The restorer and `TestRestoreFileAttributes` attribute tests expect EFS
  encryption to round-trip; EFS does not work on glass (the script records
  "EFS works"), and the same tests fail on resin.

Final side-by-side, with Git's tools on PATH and the EFS probe (both
machines report Windows 11 Pro, "EFS works: False"):

| | ARM64 (resin) | x64 (glass) |
| --- | --- | --- |
| Packages passing | 49 | 49 |
| Failing | `cmd/restic` (`TestStdinFromCommand*`), `internal/fs` (`TestRestoreFileAttributes`), `internal/restorer` (6 attribute tests) | the same tests |
| Cause | uv's `python` launcher fails to start Python; EFS unavailable | same |

So the suite shows no ARM64-specific failure.

GitHub Actions covers the environment-dependent tests: in fork run
https://github.com/meop/restic/actions/runs/37238010216 (this branch, with
the VSS fix, on current master) the full suite passes on both `windows-latest`
and native `windows-11-arm`, including `cmd/restic` (the Python tests),
`internal/fs` and `internal/restorer` (the EFS attribute tests). That run's
only failures are Linux cloud-backend tests that need upstream's secrets.

Still to do: the release asset and self-update naming; then decide how to
offer the VSS fix upstream (it changes behaviour for ARM64 users today,
independent of a release asset).
