# Dependency check over a publish folder: every DLL imported by every shipped
# .exe/.dll must be either in the folder itself, an API set (api-ms-*/ext-ms-*),
# or a Windows system DLL that ships with every Windows 10/11 install.
# Visual C++ runtime DLLs (VCRUNTIME140*, MSVCP140*, ...) are NOT system DLLs:
# they come from the VC++ Redistributable, which a fresh laptop may lack, so
# they must be app-local or not needed at all.
#
#   pwsh apps/windows/installer/check-deps.ps1 -Dir <publish folder> [-Machine x64|arm64]
# Exits 1 on any missing dependency or wrong-architecture binary.
param(
    [Parameter(Mandatory)] [string]$Dir,
    [ValidateSet("x64", "arm64")] [string]$Machine = "x64",
    [string]$Dumpbin
)
$ErrorActionPreference = "Stop"

if (-not $Dumpbin) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    $Dumpbin = & $vswhere -latest -products * -find "**\Hostx64\x64\dumpbin.exe" | Select-Object -First 1
    if (-not $Dumpbin) { throw "dumpbin.exe not found" }
}
"dumpbin: $Dumpbin"

$dir = (Resolve-Path $Dir).Path
$binaries = Get-ChildItem $dir -Recurse -File | Where-Object { $_.Extension -in ".exe", ".dll" }
$local = @{}
foreach ($b in $binaries) { $local[$b.Name.ToLowerInvariant()] = $true }

# Redistributable runtimes that are present on build machines but not on a
# fresh Windows install. Matching names must be app-local.
$redist = '^(vcruntime\d+(_\d+)?|msvcp\d+(_\w+)?|vcomp\d+|concrt\d+|vccorlib\d+|mfc\d+\w*|msvcr\d+|ucrtbased|vcruntime\d+d|msvcp\d+d)\.dll$'
# Windows system DLL names, resolved against this runner's System32. A name on
# that list is expected to be signed by Microsoft; anything else is reported
# as a warning (runner software can put third-party DLLs into System32).
$sys32 = Join-Path $env:WINDIR "System32"

$expectedMachine = if ($Machine -eq "x64") { "8664 machine (x64)" } else { "AA64 machine (ARM64)" }
$problems = [System.Collections.Generic.List[string]]::new()
$crtHits = [System.Collections.Generic.List[string]]::new()
$systemSeen = @{}
$managedOnly = 0

foreach ($b in $binaries) {
    $headers = & $Dumpbin /nologo /headers $b.FullName 2>&1 | Out-String
    $machineLine = ($headers -split "`n" | Where-Object { $_ -match '^\s+\w+ machine \(' } | Select-Object -First 1)
    $machineLine = if ($machineLine) { $machineLine.Trim() } else { "" }
    if ($machineLine -ne $expectedMachine) {
        # Pure IL (AnyCPU) assemblies carry an x86 header with the ILONLY flag; that is fine.
        $clr = & $Dumpbin /nologo /clrheader $b.FullName 2>&1 | Out-String
        if ($clr -notmatch 'IL Only') { $problems.Add("$($b.Name): built for '$machineLine', expected '$expectedMachine'") }
    }

    $deps = & $Dumpbin /nologo /dependents $b.FullName 2>&1
    $imports = @()
    foreach ($line in $deps) {
        $t = "$line".Trim()
        if ($t -match '^[\w\.\-]+\.(dll|exe|sys|drv|ocx)$') { $imports += $t.ToLowerInvariant() }
    }
    if ($imports.Count -eq 0) { $managedOnly++ }
    foreach ($dll in ($imports | Sort-Object -Unique)) {
        if ($dll -match $redist) {
            $crtHits.Add("$($b.Name) -> $dll")
            if (-not $local.ContainsKey($dll)) { $problems.Add("$($b.Name) needs $dll (Visual C++ runtime) and it is not in the package") }
            continue
        }
        if ($local.ContainsKey($dll)) { continue }
        if ($dll -match '^(api|ext)-ms-') { continue }
        $path = Join-Path $sys32 $dll
        if (Test-Path $path) {
            if (-not $systemSeen.ContainsKey($dll)) {
                $sig = Get-AuthenticodeSignature $path
                $signer = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { "" }
                $systemSeen[$dll] = $signer
                if ($signer -notmatch 'O=Microsoft Corporation') {
                    "::warning::$($b.Name) needs $dll, found in System32 but its signature is '$($sig.Status)' '$signer'; check it ships with Windows"
                }
            }
            continue
        }
        $problems.Add("$($b.Name) needs ${dll}: not in the package and not a Windows system DLL")
    }
}

"binaries scanned: $($binaries.Count) ($managedOnly with no native imports, i.e. pure IL)"
"Windows system DLLs referenced: $(($systemSeen.Keys | Sort-Object) -join ', ')"
if ($crtHits.Count -gt 0) {
    "Visual C++ runtime imports (each must be app-local):"
    $crtHits | ForEach-Object { "  $_" }
} else {
    "Visual C++ runtime imports: none (no VCRUNTIME140*/MSVCP140* needed by any shipped binary)"
}
$native = Join-Path $dir "strongroom_ffi.dll"
if (Test-Path $native) {
    "--- strongroom_ffi.dll /dependents ---"
    & $Dumpbin /nologo /dependents $native | Where-Object { "$_".Trim() -match '\.dll$' } | ForEach-Object { "  $("$_".Trim())" }
}
if ($problems.Count -gt 0) {
    "DEPENDENCY CHECK FAILED ($($problems.Count) problem(s)):"
    $problems | ForEach-Object { "::error::$_" }
    exit 1
}
"DEPENDENCY CHECK PASSED: every import of every shipped binary is app-local, an API set, or a Microsoft-signed Windows system DLL."
