# End-to-end installer smoke test for a CI runner (never run it on a real PC
# you care about: it creates and checks a vault in %LOCALAPPDATA%\Strongroom).
#
#   pwsh apps/windows/installer/smoke-test.ps1 -Installer Strongroom-Setup-0.1.0-x64.exe
#
# install (silent, per user) -> files + Start-menu shortcut -> launch the app
# (alive after 10 s) -> CLI: create vault, add, export VTF, re-import, CSV
# import -> silent uninstall -> program files gone, vault data still there.
param(
    [Parameter(Mandatory)] [string]$Installer
)
$ErrorActionPreference = "Stop"
function Step([string]$m) { "`n=== SMOKE: $m" }
function Ok([string]$m) { "SMOKE OK: $m" }
function Fail([string]$m) { "::error::SMOKE FAIL: $m"; exit 1 }
function Check-Exit([string]$what) { if ($LASTEXITCODE -ne 0) { Fail "$what exited with $LASTEXITCODE" } }

$Installer = (Resolve-Path $Installer).Path
$work = Join-Path ($env:RUNNER_TEMP ?? $env:TEMP) "strongroom-smoke"
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $work | Out-Null
$appDir = Join-Path $env:LOCALAPPDATA "Programs\Strongroom"
$dataDefault = Join-Path $env:LOCALAPPDATA "Strongroom"
$startLnk = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Strongroom.lnk"
$desktopLnk = Join-Path ([Environment]::GetFolderPath("Desktop")) "Strongroom.lnk"
$uninstKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{6B0F3C1E-5E7A-4C55-9A6E-1D2F0B9C7A41}_is1"

Step "runner"
"OS: $([Environment]::OSVersion.VersionString); arch: $([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture); user: $env:USERNAME"
"installer: $Installer ($([math]::Round((Get-Item $Installer).Length / 1MB, 1)) MB)"
"signature: $((Get-AuthenticodeSignature $Installer).Status)"
if (Test-Path $appDir) { Fail "$appDir already exists before install" }

# ---------------------------------------------------------------- install
Step "silent per-user install"
$log = Join-Path $work "install.log"
$p = Start-Process -FilePath $Installer -ArgumentList "/VERYSILENT", "/CURRENTUSER", "/SUPPRESSMSGBOXES", "/NORESTART", "/LOG=`"$log`"" -Wait -PassThru
"installer exit code: $($p.ExitCode)"
if ($p.ExitCode -ne 0) { Get-Content $log -Tail 40; Fail "installer failed" }
Get-Content $log | Select-String -Pattern "Installation process succeeded|Dest filename: .*Strongroom.exe|Creating shortcut" | ForEach-Object { "  log: $($_.Line)" }

foreach ($f in "Strongroom.exe", "strongroom-cli.exe", "strongroom_ffi.dll", "Strongroom.ico", "unins000.exe", "Microsoft.WindowsAppRuntime.dll", "coreclr.dll") {
    if (-not (Test-Path (Join-Path $appDir $f))) { Fail "missing $appDir\$f" }
}
$files = Get-ChildItem $appDir -Recurse -File
Ok "installed to $appDir ($($files.Count) files, $([math]::Round(($files | Measure-Object Length -Sum).Sum / 1MB)) MB)"
$longest = ($files | ForEach-Object { $_.FullName.Length } | Measure-Object -Maximum).Maximum
"longest installed path: $longest characters (MAX_PATH is 260)"

if (-not (Test-Path $startLnk)) { Fail "Start-menu shortcut missing: $startLnk" }
$target = (New-Object -ComObject WScript.Shell).CreateShortcut($startLnk).TargetPath
if ($target -ne (Join-Path $appDir "Strongroom.exe")) { Fail "Start-menu shortcut points to '$target'" }
Ok "Start-menu shortcut $startLnk -> $target"
if (Test-Path $desktopLnk) { Fail "desktop shortcut created although the task is unchecked by default" }
Ok "no desktop shortcut (optional task, off by default)"
$reg = Get-ItemProperty $uninstKey -ErrorAction SilentlyContinue
if (-not $reg) { Fail "uninstall entry missing under HKCU" }
Ok "Apps & features entry (HKCU): '$($reg.DisplayName)' version $($reg.DisplayVersion)"

# ---------------------------------------------------------------- launch
Step "launch installed app"
$appData = Join-Path $work "app-data"
New-Item -ItemType Directory -Force $appData | Out-Null
$env:STRONGROOM_DATA_DIR = $appData
$app = Start-Process -FilePath (Join-Path $appDir "Strongroom.exe") -WorkingDirectory $appDir -PassThru
Start-Sleep -Seconds 10
$app.Refresh()
if ($app.HasExited) {
    "--- diagnostics.log"; Get-Content (Join-Path $appData "diagnostics.log") -ErrorAction SilentlyContinue
    Get-WinEvent -LogName Application -MaxEvents 20 -ErrorAction SilentlyContinue | Where-Object { $_.ProviderName -in '.NET Runtime', 'Application Error' } | Format-List TimeCreated, ProviderName, Message
    Fail "app exited early with code $($app.ExitCode)"
}
Ok "APP ALIVE after 10 s: pid=$($app.Id) responding=$($app.Responding) title='$($app.MainWindowTitle)' workingSetMB=$([math]::Round($app.WorkingSet64 / 1MB))"
Get-Content (Join-Path $appData "diagnostics.log") -ErrorAction SilentlyContinue | ForEach-Object { "  diag: $_" }
Stop-Process -Id $app.Id -Force
Remove-Item Env:STRONGROOM_DATA_DIR

# ---------------------------------------------------------------- CLI
Step "installed CLI round-trip"
$cli = Join-Path $appDir "strongroom-cli.exe"
$cliDir = Join-Path $work "cli-vaults"
New-Item -ItemType Directory -Force $cliDir | Out-Null
$env:STRONGROOM_PASSWORD = "smoke-" + [guid]::NewGuid().ToString("N")

& $cli probe; Check-Exit "cli probe"
& $cli roundtrip --dir (Join-Path $cliDir "roundtrip"); Check-Exit "cli roundtrip"

$vault = Join-Path $cliDir "manual.srdb"
$skFile = Join-Path $cliDir "manual.secret-key.txt"
& $cli create --vault $vault --secret-key-out $skFile; Check-Exit "cli create"
$env:STRONGROOM_SECRET_KEY = (Get-Content $skFile -Raw).Trim()
& $cli add --vault $vault --title "Smoke: Example Login" --username alice@example.com --url https://example.com/; Check-Exit "cli add"
$vtf = Join-Path $cliDir "manual.vtf"
& $cli export --vault $vault --out $vtf; Check-Exit "cli export"
& $cli inspect --in $vtf; Check-Exit "cli inspect"
$imported = & $cli import --in $vtf; Check-Exit "cli import"
$imported | ForEach-Object { "  $_" }
if (-not ($imported -match '^TITLE: Smoke: Example Login$')) { Fail "re-imported VTF does not contain the added item" }
Ok "VTF export -> re-import into a fresh vault returned the added item"

$csv = Join-Path $cliDir "edge-export.csv"
Set-Content -Path $csv -Encoding utf8 -Value "name,url,username,password,note`nexample.org,https://example.org/,bob,smoke-csv-pw,`n"
$csvOut = & $cli import-csv --vault $vault --in $csv --source chrome; Check-Exit "cli import-csv"
$csvOut | ForEach-Object { "  $_" }
if (-not ($csvOut -match '^IMPORTED CSV: added=1 ')) { Fail "Chrome/Edge CSV import did not add exactly one item" }
Ok "Chrome/Edge CSV import added 1 item"
Remove-Item $csv

# A vault in the real default data folder, as a user's would be.
New-Item -ItemType Directory -Force $dataDefault | Out-Null
$userVault = Join-Path $dataDefault "vault.srdb"
& $cli create --vault $userVault --secret-key-out (Join-Path $work "user.secret-key.txt"); Check-Exit "cli create (default data folder)"
$env:STRONGROOM_SECRET_KEY = (Get-Content (Join-Path $work "user.secret-key.txt") -Raw).Trim()
& $cli add --vault $userVault --title "Smoke: must survive uninstall"; Check-Exit "cli add (default data folder)"

$before = @{}
foreach ($f in (Get-ChildItem $cliDir, $dataDefault -Recurse -File)) { $before[$f.FullName] = (Get-FileHash $f.FullName -Algorithm SHA256).Hash }
Ok "vault data before uninstall: $($before.Count) files in $cliDir and $dataDefault"

# ---------------------------------------------------------------- uninstall
Step "silent uninstall"
$uninst = (Get-ItemProperty $uninstKey).UninstallString.Trim('"')
"uninstaller: $uninst"
$ulog = Join-Path $work "uninstall.log"
$u = Start-Process -FilePath $uninst -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/LOG=`"$ulog`"" -Wait -PassThru
"uninstaller exit code: $($u.ExitCode)"
# unins000.exe re-launches itself from %TEMP%; wait for the files to go.
$deadline = (Get-Date).AddSeconds(120)
while ((Test-Path (Join-Path $appDir "Strongroom.exe")) -or (Test-Path (Join-Path $appDir "unins000.exe"))) {
    if ((Get-Date) -gt $deadline) { Fail "program files still present 120 s after uninstall" }
    Start-Sleep -Seconds 2
}
Start-Sleep -Seconds 3
if (Test-Path $ulog) { Get-Content $ulog | Select-String -Pattern "Your vault was NOT deleted|Uninstallation process succeeded|Deleting directory" | ForEach-Object { "  log: $($_.Line)" } }
if (Test-Path $appDir) {
    $left = Get-ChildItem $appDir -Recurse -Force
    if ($left) { $left | ForEach-Object { "  left: $($_.FullName)" }; Fail "$appDir not empty after uninstall" }
}
Ok "program folder $appDir removed"
if (Test-Path $startLnk) { Fail "Start-menu shortcut still present" }
Ok "Start-menu shortcut removed"
if (Get-ItemProperty $uninstKey -ErrorAction SilentlyContinue) { Fail "uninstall entry still present" }
Ok "Apps & features entry removed"

# ---------------------------------------------------------------- data kept
Step "vault data preserved"
foreach ($k in $before.Keys) {
    if (-not (Test-Path $k)) { Fail "vault data deleted by uninstall: $k" }
    if ((Get-FileHash $k -Algorithm SHA256).Hash -ne $before[$k]) { Fail "vault data changed by uninstall: $k" }
}
Get-ChildItem $dataDefault -File | ForEach-Object { "  kept: $($_.FullName) ($($_.Length) bytes)" }
Ok "all $($before.Count) vault data files still present and byte-identical after uninstall (including $userVault)"

Remove-Item Env:STRONGROOM_PASSWORD, Env:STRONGROOM_SECRET_KEY -ErrorAction SilentlyContinue
"`nSMOKE TEST PASSED: install -> launch -> CLI round-trip -> uninstall -> data preserved"
