# Windows ARM64 release readiness

Tracks [#3596](https://github.com/restic/restic/issues/3596).

The fork's native Windows ARM64 Go job already passes:
https://github.com/meop/restic/actions/runs/33244335034

Before adding a Windows ARM64 release asset, compare native ARM64 behavior with
the existing Windows x64 release and record the results below.

## Required checks

- [ ] Run the complete `go test ./...` suite on a native Windows ARM64 runner.
      Compare the result with the existing Windows x64 job. Investigate any
      ARM64-only failure; do not treat a failure in another platform's matrix
      job as an ARM64 regression.
- [ ] On native Windows ARM64, exercise a local repository end to end:
      `init`, `backup`, `restore`, `check`, and `forget --prune`. Confirm that
      `restic version` reports `windows/arm64`.
- [ ] Repeat the backup scenario with `--use-fs-snapshot` on a local NTFS
      volume, then restore and verify the snapshot's contents. This is the
      architecture-sensitive path requested in #3596.
- [ ] Run the same VSS scenario on Windows x64 and compare success/failure,
      command output, and error codes. Keep any test repository and debug logs
      free of sensitive paths or credentials before attaching evidence.
- [ ] If ARM64 VSS fails while x64 succeeds, investigate the COM/VSS call ABI
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
