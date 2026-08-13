[CmdletBinding()]
param(
    [string]$Rev,
    [string]$Target,
    [string]$Args,
    [string]$Mode = "d8",
    [string]$Patch,
    [string]$Jobs,
    [switch]$Quick,
    [switch]$Rebuild,
    [switch]$Help
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ImageName = "v8-builder"

function Show-Usage {
    Write-Host @"
V8 Builder - build d8 or v8dasm for Linux x64 in Docker

Usage:
  .\build.ps1 -Rev <hash> -Target <folder> -Args <gn_args_file> [options]

Required:
  -Rev       V8 git revision hash (or branch/tag)
  -Target    Full path to output directory
  -Args      File containing GN args (one per line)

Optional:
  -Mode      Build mode: "d8" (default) or "dasm" (v8 bytecode disassembler)
  -Patch     Patch file to apply after checkout (omit to skip)
  -Jobs      Max parallel compile jobs (default: nproc/2 to avoid OOM)
  -Quick     Skip fetch/checkout/sync - just rebuild with current source
  -Rebuild   Force Docker image rebuild

Examples:
  # Build d8 for exploit dev
  .\build.ps1 -Rev 12.1.285.26 -Target .\output\cve-2024-1234 -Args args\debug.gn -Patch exploit.patch

  # Build v8dasm bytecode disassembler
  .\build.ps1 -Mode dasm -Rev 2b2f6915852 -Target .\output\dasm -Args args\dasm.gn -Patch patches\dasm.patch

Output structure (<target>\):
  d8 mode:   out\d8, out\icudtl.dat, out\snapshot_blob.bin, out\.gdbinit, v8\src\, v8\include\
  dasm mode: out\v8dasm, v8\src\, v8\include\
"@
    exit 1
}

if ($Help) { Show-Usage }

# ---- Validate arguments ----
if ($Mode -notin @("d8", "dasm")) {
    Write-Host "Error: -Mode must be 'd8' or 'dasm'"
    exit 1
}

if ($Quick) {
    if (-not $Target) { Write-Host "Error: -Target is required"; Show-Usage }
    if (-not $Args)   { Write-Host "Error: -Args is required";   Show-Usage }
} else {
    if (-not $Rev)    { Write-Host "Error: -Rev is required";    Show-Usage }
    if (-not $Target) { Write-Host "Error: -Target is required"; Show-Usage }
    if (-not $Args)   { Write-Host "Error: -Args is required";   Show-Usage }
}

# ---- Resolve paths ----
$GnArgsPath = Resolve-Path $Args -ErrorAction Stop
$OutputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Target)
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}
$OutputDir = Resolve-Path $OutputDir

# ---- Build Docker image ----
$ImageExists = docker images -q $ImageName 2>$null
if (-not $ImageExists -or $Rebuild) {
    Write-Host "[*] Building Docker image ($ImageName)..."
    docker build --platform linux/amd64 -t $ImageName $ScriptDir
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} else {
    Write-Host "[*] Docker image $ImageName exists (use -Rebuild to force)"
}

# ---- Create persistent volumes ----
docker volume create v8-src     2>$null | Out-Null
docker volume create ccache-vol 2>$null | Out-Null

# ---- Prepare docker arguments ----
$DockerArgs = @(
    "--platform", "linux/amd64"
    "--rm"
    "-v", "v8-src:/v8"
    "-v", "ccache-vol:/root/.ccache"
    "-v", "${OutputDir}:/output"
    "-v", "${ScriptDir}\build-inside.sh:/usr/local/bin/build-inside.sh:ro"
    "-v", "${GnArgsPath}:/tmp/gn_args.txt:ro"
    "-e", "CCACHE_DIR=/root/.ccache"
    "-e", "QUICK_MODE=$($Quick.ToString().ToLower())"
    "-e", "BUILD_MODE=$Mode"
)

# Mount v8dasm.cpp for dasm mode
if ($Mode -eq "dasm") {
    $V8DasmSrc = Join-Path $ScriptDir "v8dasm.cpp"
    if (-not (Test-Path $V8DasmSrc)) {
        Write-Host "Error: v8dasm.cpp not found at $V8DasmSrc"
        exit 1
    }
    $DockerArgs += @("-v", "${V8DasmSrc}:/tmp/v8dasm.cpp:ro")
}

# Patch mount (optional)
$PatchArg = "none"
if ($Patch) {
    $PatchPath = Resolve-Path $Patch -ErrorAction Stop
    $DockerArgs += @("-v", "${PatchPath}:/tmp/patch.diff:ro")
    $PatchArg = "/tmp/patch.diff"
}

# ---- Run build ----
Write-Host "[*] Starting build container..."
if ($Quick) { Write-Host "    Mode:     QUICK (rebuild only)" }
Write-Host "    Build:    $Mode"
if ($Rev)   { Write-Host "    Revision: $Rev" }
Write-Host "    Target:   $OutputDir"
Write-Host "    GN args:  $Args"
if ($Patch) { Write-Host "    Patch:    $Patch" }
if ($Jobs)  { Write-Host "    Jobs:     $Jobs" }
Write-Host ""

$RevArg = if ($Rev) { $Rev } else { "none" }
$JobsArg = if ($Jobs) { $Jobs } else { "" }

docker run @DockerArgs $ImageName $RevArg $PatchArg "/tmp/gn_args.txt" "/output" $JobsArg
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ""
Write-Host "[*] Output ready at: $OutputDir"
$BinaryName = if ($Mode -eq "dasm") { "v8dasm" } else { "d8" }
$BinaryPath = Join-Path $OutputDir "out\$BinaryName"
if (Test-Path $BinaryPath) {
    Get-Item $BinaryPath | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
} else {
    Write-Host "Warning: $BinaryName not found in output"
}
