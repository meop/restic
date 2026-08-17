# Windows ARM64 support handoff

Status captured: 2026-08-17

This branch is investigation scaffolding for a later Windows ARM64 session. It
is not intended to be submitted upstream as documentation.

## Upstream status

- restic issue #3596 tracks official Windows ARM64 binaries:
  https://github.com/restic/restic/issues/3596
- Go has supported `windows/arm64` for years, and contributors have reported
  that restic cross-compiles and performs basic operations on Windows ARM64.
- In the latest maintainer response, the project is waiting for someone to
  contribute the remaining changes.

This is not only a release-matrix omission. A native tester reported that the
binary generally worked but `--use-fs-snapshot` failed in
`IsVolumeSupported()` with `E_INVALIDARG (0x80070057)`. The maintainer suspects
that the handwritten VSS/COM syscall arguments need to follow Windows ARM64
calling conventions, including how GUID values such as `ole.IID_NULL` are
passed.

The relevant implementation is primarily in:

- `internal/fs/vss_windows.go`
- `internal/fs/fs_local_vss_test.go`
- Windows-specific code reached by `cmd/restic/cmd_backup.go`

## Work possible without a Windows ARM64 machine

1. Confirm that current master cross-builds:
   `go run build.go --goos windows --goarch arm64`.
2. Audit every handwritten `syscall.SyscallN`/COM call in
   `internal/fs/vss_windows.go` against Microsoft ARM64 ABI documentation and
   maintained Go Windows bindings.
3. Compare the x86, x64, and ARM64 argument layouts for GUIDs, pointers,
   HRESULT returns, and COM vtable calls.
4. Prepare narrowly scoped diagnostics or tests, but do not infer runtime
   correctness from a successful cross-build.

## Native Windows ARM64 validation

Use an actual Windows ARM64 machine for the acceptance work:

1. Record Windows edition/build, Go version, filesystem type, privileges, and
   whether the terminal is native ARM64 or x64-emulated.
2. Build natively and confirm `restic version` reports `windows/arm64`.
3. Run `go test ./...` and classify failures as real architecture failures,
   Windows test-environment assumptions, or missing helper executables.
   Historical discussion notes that some tests expect an `echo` executable.
4. Run focused tests under `./internal/fs` and capture the exact VSS HRESULT,
   call arguments, and failing method before changing syscall layouts.
5. Test `backup --use-fs-snapshot` on a supported NTFS volume with suitable
   privileges. Verify snapshot creation, file reads, cleanup, and repeated
   runs—not merely process exit status.
6. Exercise a small repository through init, backup, snapshots, check,
   restore, and forget/prune; compare results with Windows x64 where useful.
7. Re-run the same cases under an x64 restic binary on the ARM64 machine to
   distinguish Windows-on-ARM behavior from native-ABI bugs.
8. After runtime correctness is established, add `windows/arm64` to the
   official build/release target list and update downstream package metadata.

## Suggested deliverables

- A minimal reproduction and ABI explanation for the VSS failure.
- A focused code fix with native ARM64 test output.
- A separate or follow-up release-matrix change, depending on maintainer
  preference.
- Notes identifying any test-suite failures unrelated to ARM64 so they are not
  hidden by broad exclusions.

