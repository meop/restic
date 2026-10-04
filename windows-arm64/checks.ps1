# Runs on a Windows host (copied there by run-checks.sh). Works through the
# checks in WINDOWS-ARM64-TODO.md: the Go test suite, a local repository end to
# end, and the same backup through a VSS snapshot. Every check prints PASS or
# FAIL; full command output goes to $Work\logs. Run from an elevated session,
# since VSS needs administrator rights.
param(
    [Parameter(Mandatory)] [string] $Archive,
    [Parameter(Mandatory)] [string] $Work,
    [switch] $SkipTests
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$failed = 0

$logs = Join-Path $Work 'logs'
$src = Join-Path $Work 'src'
foreach ($d in 'src', 'data', 'repo', 'restore-plain', 'restore-vss', 'logs') {
    $p = Join-Path $Work $d
    if (Test-Path $p) { Remove-Item -Recurse -Force $p }
    New-Item -ItemType Directory -Force $p | Out-Null
}

function Check([string] $name, [scriptblock] $body) {
    try {
        $detail = & $body
        "PASS  $name  $detail"
    } catch {
        "FAIL  $name  $($_.Exception.Message)"
        $script:failed++
    }
}

# Runs a native command, logs its output to $logs\<log>.log, and throws on a
# nonzero exit. Returns the output.
function Invoke-Logged([string] $log, [string] $exe, [string[]] $argv) {
    $out = & $exe @argv 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $out | Set-Content -Encoding utf8 (Join-Path $logs "$log.log")
    if ($code -ne 0) { throw "exit $code (see $log.log): $(($out | Select-Object -Last 3) -join ' / ')" }
    $out
}

function Get-TreeHashes([string] $root) {
    $map = @{}
    Get-ChildItem -LiteralPath $root -Recurse -File -Force | ForEach-Object {
        $rel = $_.FullName.Substring($root.Length).TrimStart('\')
        $map[$rel] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }
    $map
}

function Compare-Trees([string] $expected, [string] $actual) {
    $a = Get-TreeHashes $expected
    $b = Get-TreeHashes $actual
    $diff = @()
    foreach ($k in $a.Keys) { if ($b[$k] -ne $a[$k]) { $diff += $k } }
    foreach ($k in $b.Keys) { if (-not $a.ContainsKey($k)) { $diff += "+$k" } }
    if ($diff) { throw "$($diff.Count) differing files, e.g. $($diff | Select-Object -First 3)" }
    "$($a.Count) files identical"
}

# restic restores the snapshot's absolute path under the target
# (target\C\Users\...\data); find the restored copy of the data directory.
function Find-Restored([string] $target) {
    # -Force: the restored AppData directory keeps its hidden attribute.
    $marker = Get-ChildItem -LiteralPath $target -Recurse -File -Force -Filter 'restic-check-marker.txt' | Select-Object -First 1
    if (-not $marker) { throw "restored data not found under $target" }
    $marker.Directory.FullName
}

"host: $env:COMPUTERNAME $([Runtime.InteropServices.RuntimeInformation]::OSArchitecture), Windows $([Environment]::OSVersion.Version)"
"elevated: $(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators'))"
"go: $(go version)"
"edition: $((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID)"
# Several restic tests encrypt files with EFS and expect the attribute back;
# record whether EFS works here so those results can be read correctly.
$efsProbe = Join-Path $Work 'efs-probe.txt'
Set-Content $efsProbe 'probe'
cipher /e $efsProbe 2>&1 | Out-Null
"EFS works: $(((Get-Item $efsProbe).Attributes -band [IO.FileAttributes]::Encrypted) -ne 0)"
Remove-Item -Force $efsProbe

tar -xzf $Archive -C $src
if ($LASTEXITCODE -ne 0) { throw "tar failed: $LASTEXITCODE" }
Push-Location $src
try {
    if (-not $SkipTests) {
        # The whole suite; a package failure is recorded, not fatal. Some tests
        # run `true`, `false` and `echo`; GitHub's Windows runners provide them
        # from Git for Windows, so do the same.
        $gitUsrBin = Join-Path $env:ProgramFiles 'Git\usr\bin'
        if (Test-Path $gitUsrBin) { $env:PATH = "$env:PATH;$gitUsrBin" }
        $start = Get-Date
        & go test -count=1 ./... 2>&1 | ForEach-Object { "$_" } | Set-Content -Encoding utf8 (Join-Path $logs 'go-test.log')
        $code = $LASTEXITCODE
        $lines = Get-Content (Join-Path $logs 'go-test.log')
        $ok = @($lines | Where-Object { $_ -match '^ok\s' }).Count
        $fail = @($lines | Where-Object { $_ -match '^(FAIL|---\sFAIL)' })
        $mins = [math]::Round(((Get-Date) - $start).TotalMinutes, 1)
        if ($code -eq 0) { "PASS  go test ./...  $ok packages ok in $mins min" }
        else { "FAIL  go test ./...  exit $code, $ok packages ok in $mins min; failures:"; $fail | ForEach-Object { "        $_" }; $failed++ }
    }

    $restic = Join-Path $Work 'restic.exe'
    Check 'go build ./cmd/restic' { Invoke-Logged 'build' 'go' @('build', '-o', $restic, './cmd/restic') | Out-Null; 'ok' }
} finally {
    Pop-Location
}

Check 'restic version' {
    $v = Invoke-Logged 'version' $restic @('version')
    $arch = if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'windows/arm64' } else { 'windows/amd64' }
    if ("$v" -notmatch [regex]::Escape($arch)) { throw "expected $arch in: $v" }
    "$v"
}

# Generated data only, so nothing personal ends up in the logs or repository.
$data = Join-Path $Work 'data'
Set-Content -LiteralPath (Join-Path $data 'restic-check-marker.txt') 'marker'
$rng = [Random]::new(3596)
foreach ($i in 1..120) {
    $dir = Join-Path $data ("dir{0:D2}" -f ($i % 12))
    New-Item -ItemType Directory -Force $dir | Out-Null
    $bytes = [byte[]]::new($rng.Next(0, 64KB))
    $rng.NextBytes($bytes)
    [IO.File]::WriteAllBytes((Join-Path $dir "file$i.bin"), $bytes)
}
$big = [byte[]]::new(24MB); $rng.NextBytes($big)
[IO.File]::WriteAllBytes((Join-Path $data 'large.bin'), $big)
Set-Content -LiteralPath (Join-Path $data 'naïve-文件 ünïcödé.txt') 'unicode name'
New-Item -ItemType File -Force (Join-Path $data 'empty.txt') | Out-Null

$env:RESTIC_REPOSITORY = Join-Path $Work 'repo'
$env:RESTIC_PASSWORD = 'windows-check-only'   # throwaway repository in $Work

Check 'init' { Invoke-Logged 'init' $restic @('init') | Out-Null; 'ok' }
Check 'backup' { (Invoke-Logged 'backup-1' $restic @('backup', '--host', 'check', $data) | Select-String '^snapshot ').ToString() }
Set-Content -LiteralPath (Join-Path $data 'dir00\file12.bin') 'changed'
Set-Content -LiteralPath (Join-Path $data 'added.txt') 'added'
Check 'second backup' { (Invoke-Logged 'backup-2' $restic @('backup', '--host', 'check', $data) | Select-String '^snapshot ').ToString() }
Check 'restore' {
    Invoke-Logged 'restore-plain' $restic @('restore', 'latest', '--target', (Join-Path $Work 'restore-plain')) | Out-Null
    Compare-Trees $data (Find-Restored (Join-Path $Work 'restore-plain'))
}
Check 'check --read-data' { Invoke-Logged 'check-1' $restic @('check', '--read-data') | Out-Null; 'no errors' }
Check 'forget --keep-last 1 --prune' {
    Invoke-Logged 'forget-prune' $restic @('forget', '--keep-last', '1', '--prune') | Out-Null
    $n = @((Invoke-Logged 'snapshots' $restic @('snapshots', '--json') | ConvertFrom-Json)).Count
    if ($n -ne 1) { throw "$n snapshots left" }
    '1 snapshot left'
}
Check 'check after prune' { Invoke-Logged 'check-2' $restic @('check') | Out-Null; 'no errors' }

# The architecture-sensitive path from #3596: back up through a VSS snapshot.
# Existing shadow copies (restore points and the like) are the machine's own;
# only new ones left behind by restic count.
$shadowsBefore = @(Get-CimInstance Win32_ShadowCopy -ErrorAction SilentlyContinue | ForEach-Object ID)
Check 'backup --use-fs-snapshot' {
    $out = Invoke-Logged 'backup-vss' $restic @('backup', '--host', 'check', '--use-fs-snapshot', $data)
    $vss = $out | Select-String -SimpleMatch 'VSS', 'snapshot for' | Select-Object -First 2
    $warn = $out | Select-String -Pattern 'error|warning|fail' | Select-Object -First 2
    if ($warn) { throw "backup reported: $($warn -join ' / ')" }
    "$(($out | Select-String '^snapshot ').ToString()); $($vss -join ' / ')"
}
Check 'restore VSS snapshot' {
    Invoke-Logged 'restore-vss' $restic @('restore', 'latest', '--target', (Join-Path $Work 'restore-vss')) | Out-Null
    Compare-Trees $data (Find-Restored (Join-Path $Work 'restore-vss'))
}
Check 'no new VSS shadow copies left' {
    $left = @(Get-CimInstance Win32_ShadowCopy -ErrorAction SilentlyContinue | Where-Object { $_.ID -notin $shadowsBefore })
    if ($left) { throw "$($left.Count) new shadow copies remain: $($left.ID -join ', ')" }
    "none new ($($shadowsBefore.Count) pre-existing)"
}
Check 'check after VSS backup' { Invoke-Logged 'check-3' $restic @('check', '--read-data') | Out-Null; 'no errors' }

if ($failed) { "$failed check(s) failed"; exit 1 }
'all checks passed'
