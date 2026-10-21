# Rust endpoint test (Windows)
#
# Installs Rust (rustup), several toolchain versions (stable, an older stable,
# nightly) and Bazel (via Bazelisk), then downloads a tiny Rust project and
# builds, tests and runs it with each toolchain and with Bazel.
#
# Run as a normal user from a PowerShell window:
#   powershell -ExecutionPolicy Bypass -File .\test-windows.ps1
#
# Every step runs even if an earlier one fails, so the summary shows exactly
# which steps did not work.

# ---- Settings -------------------------------------------------------------
# rustup uses its own defaults (%USERPROFILE%\.rustup, %USERPROFILE%\.cargo).
# To put the project somewhere else, change $WorkDir, for example C:\RustDev\src.
$WorkDir = "$env:USERPROFILE\rust-endpoint-test"
$OlderToolchain = "1.80.0"
$ProjectUrl = "https://github.com/sethcall/rust-endpoint-test/archive/refs/heads/main.zip"
# Rust on Windows needs the Microsoft C++ Build Tools (link.exe). If they are
# missing, install them with winget (shows an administrator prompt).
$InstallBuildTools = $true
# Leave empty for Bazel's default output location. Set to a short path such as
# C:\_bzl if Bazel reports path-length errors.
$BazelOutputUserRoot = ""
# ---------------------------------------------------------------------------

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$Stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$Log = Join-Path $WorkDir "rust-endpoint-test-$Stamp.log"
Start-Transcript -Path $Log | Out-Null

$Results = New-Object System.Collections.Generic.List[string]
$Failed = 0

function Step([string]$Name, [scriptblock]$Block) {
    Write-Host ""
    Write-Host ("=== [{0}] {1}" -f (Get-Date).ToUniversalTime().ToString("HH:mm:ssZ"), $Name)
    $global:LASTEXITCODE = 0
    $ok = $true
    try {
        # Show command output; a [bool] emitted by the block is its verdict.
        & $Block | ForEach-Object {
            if ($_ -is [bool]) { $ok = $ok -and $_ } else { Write-Host $_ }
        }
        if ($global:LASTEXITCODE -ne 0) { $ok = $false; Write-Host "Exit code: $global:LASTEXITCODE" }
    } catch {
        Write-Host "Error: $_"
        $ok = $false
    }
    if ($ok) { $script:Results.Add("PASS  $Name") }
    else { $script:Results.Add("FAIL  $Name"); $script:Failed++ }
}

# Runs a command, prints its output and checks the output contains $Expected.
function Expect-Output([string]$Expected, [scriptblock]$Block) {
    $out = & $Block | Out-String
    Write-Host $out
    if ($global:LASTEXITCODE -ne 0) { return $false }
    if (-not $out.Contains($Expected)) { Write-Host "Expected output to contain: $Expected"; return $false }
    return $true
}

$Arch = $env:PROCESSOR_ARCHITECTURE
switch ($Arch) {
    "AMD64" { $RustTriple = "x86_64-pc-windows-msvc";  $BazeliskAsset = "bazelisk-windows-amd64.exe"; $VcComponent = "Microsoft.VisualStudio.Component.VC.Tools.x86.x64" }
    "ARM64" { $RustTriple = "aarch64-pc-windows-msvc"; $BazeliskAsset = "bazelisk-windows-arm64.exe"; $VcComponent = "Microsoft.VisualStudio.Component.VC.Tools.ARM64" }
    default { Write-Host "Unsupported architecture: $Arch"; Stop-Transcript | Out-Null; return }
}

$Os = Get-CimInstance Win32_OperatingSystem
Write-Host "Rust endpoint test (Windows)"
Write-Host "Host:      $env:COMPUTERNAME"
Write-Host "User:      $env:USERDOMAIN\$env:USERNAME"
Write-Host "OS:        $($Os.Caption) $($Os.Version), $Arch"
Write-Host "Work dir:  $WorkDir"
Write-Host "Log file:  $Log"
Write-Host "Start UTC: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"

$env:Path = "$env:USERPROFILE\.cargo\bin;$WorkDir\bin;$env:Path"
$Proj = Join-Path $WorkDir "rust-endpoint-test-main"
$Vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"

function Test-BuildTools {
    if (-not (Test-Path $Vswhere)) { return $false }
    $path = & $Vswhere -products * -latest -requires $VcComponent -property installationPath
    return [bool]$path
}

# 1. Prerequisite: Microsoft C++ Build Tools (provides link.exe).
Step "Microsoft C++ Build Tools present" {
    if (Test-BuildTools) { Write-Host "Found."; return $true }
    if (-not $InstallBuildTools) { Write-Host "Not found and `$InstallBuildTools is off."; return $false }
    Write-Host "Not found; installing with winget (approve the administrator prompt)..."
    winget install --id Microsoft.VisualStudio.2022.BuildTools -e --accept-source-agreements --accept-package-agreements `
        --override "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
    $global:LASTEXITCODE = 0
    return (Test-BuildTools)
}

# 2. Install Rust with rustup (no admin rights).
Step "Install rustup + stable toolchain" {
    if (Get-Command rustup -ErrorAction SilentlyContinue) {
        Write-Host "rustup already installed; updating instead."
        rustup self update
        rustup update stable
    } else {
        $init = Join-Path $WorkDir "rustup-init.exe"
        Invoke-WebRequest -UseBasicParsing -Uri "https://static.rust-lang.org/rustup/dist/$RustTriple/rustup-init.exe" -OutFile $init
        & $init -y --no-modify-path --profile minimal --default-toolchain stable
    }
}
Step "rustc runs" { rustc --version }
Step "cargo runs" { cargo --version }

# 3. Download the sample project (no git needed).
Step "Download sample project" {
    $zip = Join-Path $WorkDir "project.zip"
    if (Test-Path $Proj) { Remove-Item -Recurse -Force $Proj }
    Invoke-WebRequest -UseBasicParsing -Uri $ProjectUrl -OutFile $zip
    Expand-Archive -Force -Path $zip -DestinationPath $WorkDir
    Test-Path (Join-Path $Proj "Cargo.toml")
}
Set-Location $Proj

# 4. Build, test and run with stable. build.rs and the test binary are
#    freshly compiled executables that run immediately.
Step "cargo build (stable)" { cargo +stable build }
Step "cargo test (stable)" { cargo +stable test }
Step "cargo run (stable)" { Expect-Output "Hello from Rust!" { cargo +stable run } }

# 5. Install an older stable and nightly side by side, then rebuild with each.
Step "Install toolchain $OlderToolchain" { rustup toolchain install $OlderToolchain --profile minimal }
Step "cargo test ($OlderToolchain)" { cargo "+$OlderToolchain" test }
Step "cargo run ($OlderToolchain)" { Expect-Output "rustc $OlderToolchain" { cargo "+$OlderToolchain" run } }

Step "Install toolchain nightly" { rustup toolchain install nightly --profile minimal }
Step "cargo test (nightly)" { cargo +nightly test }
Step "cargo run (nightly)" { Expect-Output "-nightly" { cargo +nightly run } }

# 6. Per-project pinning, the way real projects select a version.
Step "rustup override set $OlderToolchain" { rustup override set $OlderToolchain }
Step "cargo run (pinned via override)" { Expect-Output "rustc $OlderToolchain" { cargo run } }
rustup override unset | Out-Null

# 7. Directly run the built executable (as a developer would after building).
Step "Run built binary directly" { Expect-Output "Hello from Rust!" { & .\target\debug\rust-endpoint-test.exe } }

# 8. Install Bazel via Bazelisk (reads .bazelversion), then build, test, run.
$Bazel = Join-Path $WorkDir "bin\bazel.exe"
Step "Install Bazelisk" {
    New-Item -ItemType Directory -Force -Path (Join-Path $WorkDir "bin") | Out-Null
    Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/bazelbuild/bazelisk/releases/latest/download/$BazeliskAsset" -OutFile $Bazel
    Test-Path $Bazel
}
$BazelStartup = @()
if ($BazelOutputUserRoot) { $BazelStartup += "--output_user_root=$BazelOutputUserRoot" }

Step "bazel version" { & $Bazel @BazelStartup version }
Step "bazel build //:hello" { & $Bazel @BazelStartup build //:hello }
Step "bazel test //:hello_test" { & $Bazel @BazelStartup test //:hello_test }
Step "bazel run //:hello" { Expect-Output "Built with: Bazel rules_rust" { & $Bazel @BazelStartup run //:hello } }
& $Bazel @BazelStartup shutdown 2>$null | Out-Null

# ---- Summary --------------------------------------------------------------
Write-Host ""
Write-Host "End UTC:   $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
Write-Host ""
Write-Host "================ SUMMARY ================"
$Results | ForEach-Object { Write-Host $_ }
Write-Host "========================================="
if ($Failed -eq 0) {
    Write-Host "All $($Results.Count) steps PASSED on this host."
} else {
    Write-Host "$Failed of $($Results.Count) steps FAILED. TEST FAILED."
}
Write-Host "Log saved to: $Log"
Stop-Transcript | Out-Null
