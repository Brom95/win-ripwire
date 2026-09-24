# update-ripwire.ps1 — Windows install route for a maintainer checkout.
# External to ripwire; NOT committed to the ripwire project.
#
# Usage:
#   .\update-ripwire.ps1              # full run: clone (if needed), pull, build, install
#   .\update-ripwire.ps1 --version    # report script version and exit
#   .\update-ripwire.ps1 --help       # show usage and exit

param(
  [switch]$Version = $null,
  [switch]$Help = $null,
  [string]$Prefix = "",
  # Upstream repository (the script clones it into ripwire/ if the
  # checkout is missing, and pulls from it on later runs).
  [string]$RepoUrl = "https://github.com/redhat-et/ripwire.git",
  # Explicit tool paths (override automatic discovery; useful for testing
  # when LLVM / ninja / cmake are not on PATH).
  [string]$ClangCl = "",
  [string]$Ninja = "",
  [string]$Vcvars = "",
  [string]$CMake = "",
  # Where to build (else <script root>/build-install-win).
  [string]$BuildDirOverride = "",
  # Partial-run switches (for testing individual stages).
  [switch]$SkipPull = $null,
  [switch]$SkipBuild = $null
)

$ErrorActionPreference = "Stop"

# ── Script identity ─────────────────────────────────────────────────────────
$ScriptVersion = "0.6.2"

# ── Paths ───────────────────────────────────────────────────────────────────
$RootDir       = $PSScriptRoot
$RipwireDir    = Join-Path $RootDir "ripwire"
$BuildDir      = Join-Path $RootDir "build-install-win"
if ($BuildDirOverride) { $BuildDir = $BuildDirOverride }
$DefaultPrefix = "C:\Program Files\ripwire"

# ── Version flag (task 1.1: report version/usage) ───────────────────────────
if ($Version) {
  Write-Host "update-ripwire.ps1 version $ScriptVersion"
  exit 0
}

# ── Help flag ───────────────────────────────────────────────────────────────
function Show-Usage {
  Write-Host "update-ripwire.ps1 — Windows install route for a maintainer checkout."
  Write-Host ""
  Write-Host "Usage:"
  Write-Host "  .\update-ripwire.ps1              full run: pull, build, install"
  Write-Host "  .\update-ripwire.ps1 --version    report script version and exit"
  Write-Host "  .\update-ripwire.ps1 --help       show this usage and exit"
  Write-Host ""
  Write-Host "Options:"
  Write-Host "  -Prefix <dir>          override the install prefix (else RIPWIRE_INSTALL_PREFIX, else C:\Program Files\ripwire)"
  Write-Host "  -RepoUrl <url>         upstream repository (default: https://github.com/redhat-et/ripwire.git)"
  Write-Host "  -ClangCl <path>        explicit clang-cl.exe (else auto-discovery)"
  Write-Host "  -Ninja <path>          explicit ninja.exe   (else auto-discovery)"
  Write-Host "  -Vcvars <path>         explicit vcvars64.bat (else auto-discovery)"
  Write-Host "  -CMake <path>          explicit cmake      (else PATH)"
  Write-Host "  -BuildDir <dir>        build directory    (else <root>/build-install-win)"
  Write-Host "  -SkipPull              skip the git pull (test install stages only)"
  Write-Host "  -SkipBuild             skip the build (build dir must already hold ripwire.exe)"
}

if ($Help) {
  Show-Usage
  exit 0
}

# ── Helper: fail loudly ─────────────────────────────────────────────────────
function Stop-Fail([string]$msg) {
  Write-Host ("update-ripwire.ps1: ERROR: " + $msg) -ForegroundColor Red
  exit 1
}

# ── Helper: run git without throwing on stderr ──────────────────────────────
# PowerShell 5.1 turns git's stderr into error records; under $ErrorActionPreference
# "Stop" those throw (RemoteCommandError) before we can read $LASTEXITCODE.
# Switch to "Continue" just for the call, capture output + exit code, restore.
function Invoke-Git {
  param([string[]]$ArgList)
  $saved = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $out = & git @ArgList 2>&1
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $saved
  }
  return $out
}

# ── Helper: run any exe without throwing on stderr ──────────────────────────
function Invoke-Exe {
  param([string]$Path, [string[]]$ArgList)
  $saved = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $out = & $Path @ArgList 2>&1
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $saved
  }
  return $out
}

# ── Prerequisite check (winget suggestions) ─────────────────────────────────
function Check-Prerequisites {
  $missing = @()

  # CMake (required)
  if (-not (Get-Command -ErrorAction SilentlyContinue "cmake")) {
    $missing += "CMake"
  }

  # Compilers: check each, report which are available
  $hasClangCl = Get-ClangClPath   # full-path discovery (LLVM may not be on PATH)
  $hasMsVc    = Test-HasMsvc
  $hasGcc     = Get-Command -ErrorAction SilentlyContinue "gcc"

  if (-not $hasClangCl) { $missing += "clang-cl (preferred)" }
  if (-not $hasMsVc)    { $missing += "MSVC cl.exe (fallback)" }
  if (-not $hasGcc)     { $missing += "MinGW gcc/g++ (alternative)" }

  if ($missing.Count -gt 0) {
    Write-Host "Prerequisites missing:"
    foreach ($m in $missing) { Write-Host "  - $m" }
    Write-Host ""
    Write-Host "Install via winget (if available):"
    if ("CMake" -in $missing)            { Write-Host "  winget install Kitware.CMake" }
    if (-not $hasClangCl)                { Write-Host "  winget install LLVM.LLVM   # clang-cl (preferred)" }
    if (-not $hasMsVc)                   { Write-Host "  winget install Microsoft.VisualStudio.BuildTools  # MSVC cl.exe" }
    if (-not $hasGcc)                    { Write-Host "  winget install MSYS2.MSYS2   # MinGW gcc/g++" }
  }

  # Hard stops: CMake required, at least one compiler required
  if ("CMake" -in $missing) {
    Stop-Fail "CMake is required but not found. Install it (e.g. via winget) and re-run."
  }
  if (-not $hasClangCl -and -not $hasMsVc -and -not $hasGcc) {
    Stop-Fail "No C/C++ compiler found (clang-cl, cl.exe/VS, or gcc). Install one (e.g. via winget) and re-run."
  }

  Write-Host "Prerequisites: OK (CMake present; at least one compiler available)."
}

# Detect MSVC availability: cl on PATH, or a VS install containing cl.exe.
# (CMake's default Windows generator auto-detects VS, so cl.exe need not be on PATH.)
function Test-HasMsvc {
  if (Get-Command -ErrorAction SilentlyContinue "cl") { return $true }
  $bases = @("C:\Program Files (x86)\Microsoft Visual Studio", "C:\Program Files\Microsoft Visual Studio")
  foreach ($base in $bases) {
    if (Test-Path $base) {
      $cl = Get-ChildItem -Path $base -Recurse -Filter "cl.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($cl) { return $true }
    }
  }
  return $false
}

# ── clang-cl discovery (used by Check-Prerequisites and Build-Ripwire) ───────
# Returns the full path to clang-cl.exe, or $null if not found.
function Get-ClangClPath {
  foreach ($candidate in @(
    "C:\Program Files\LLVM\bin\clang-cl.exe",
    "C:\Program Files (x86)\LLVM\bin\clang-cl.exe"
  )) {
    if (Test-Path $candidate) { return $candidate }
  }
  $cmd = Get-Command -EA SilentlyContinue "clang-cl"
  if ($cmd) { return $cmd.Source }
  return $null
}

# ── Checkout: clone the upstream repo if the checkout is missing ─────────────
function Ensure-Checkout {
  if (Test-Path $RipwireDir) {
    if (-not (Test-Path (Join-Path $RipwireDir ".git"))) {
      Stop-Fail "The ripwire directory exists but is not a git checkout. Delete it and re-run (the installer will clone a fresh copy)."
    }
    Write-Host "Checkout: ripwire/ already present (git checkout) — will pull the latest."
    return
  }
  Write-Host ("Checkout: ripwire/ not found — cloning from " + $RepoUrl + ".")
  $saved = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $out = & git clone $RepoUrl $RipwireDir 2>&1
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $saved
  }
  if ($code -ne 0) {
    Stop-Fail ("git clone failed: " + $out)
  }
  Write-Host "Checkout: ripwire cloned from $RepoUrl."
}

# ── Clean-tree guard (task 2.1) ─────────────────────────────────────────────
function Test-CleanTree {
  Push-Location $RipwireDir
  try {
    $dirty = Invoke-Git -ArgList @("status","--porcelain")
    if ($LASTEXITCODE -ne 0) {
      Stop-Fail "git is not available or the ripwire directory is not a git checkout."
    }
    if ($dirty.Count -gt 0) {
      Write-Host "update-ripwire.ps1: the checkout has uncommitted changes:"
      $dirty | ForEach-Object { Write-Host "  $_" }
      Stop-Fail "Stopping before pulling, building, or installing. Resolve the dirty files first."
    }
  } finally { Pop-Location }
}

# ── Guarded pull (task 2.2) ─────────────────────────────────────────────────
function Update-Checkout {
  Push-Location $RipwireDir
  try {
    # Report the remotes, then do a plain `git pull` from the tracked upstream.
    # No auto-rebase, no force (git's default behavior).
    $remotes = Invoke-Git -ArgList @("remote","-v")
    Write-Host ("Update: remotes: " + (($remotes -join " ")))

    $pullOut = Invoke-Git -ArgList @("pull")
    if ($LASTEXITCODE -ne 0) {
      Stop-Fail ("git pull failed: " + $pullOut)
    }
  } finally { Pop-Location }

  # Report the new HEAD
  Push-Location $RipwireDir
  try {
    $head = Invoke-Git -ArgList @("rev-parse","--short","HEAD")
    $full = Invoke-Git -ArgList @("rev-parse","HEAD")
    Write-Host ("Update: pulled, now at HEAD $head ($full)")
  } finally { Pop-Location }
}

# ── CMake build (task 3.1) ──────────────────────────────────────────────────
function Build-Ripwire {
  # ── Toolchain resolution (explicit -params win; else auto-discovery) ───────
  $clangCl = if ($ClangCl) { $ClangCl } else { Get-ClangClPath }
  if (-not $clangCl) {
    Stop-Fail "clang-cl not found (looked C:\Program Files\LLVM\bin and PATH). Install LLVM (winget install LLVM.LLVM) and re-run."
  }

  # Ninja — explicit -Ninja wins; else WinGet cache, then PATH.
  $ninja = if ($Ninja) { $Ninja } else { $null }
  if (-not $ninja) {
    $ninjaCache = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages\Ninja-build.Ninja_Microsoft.Winget.Source_8wekyb3d8bbwe\ninja.exe"
    if (Test-Path $ninjaCache) { $ninja = $ninjaCache }
  }
  if (-not $ninja) {
    $cmd = Get-Command -EA SilentlyContinue "ninja"
    if ($cmd) { $ninja = $cmd.Source }
  }
  if (-not $ninja) {
    Stop-Fail "ninja.exe not found (looked WinGet cache and PATH). Install Ninja (winget install Ninja-build.Ninja) and re-run."
  }

  # vcvars64.bat — explicit -Vcvars wins; else derive from a VS 2022 install.
  if ($Vcvars) {
    $vcvars = $Vcvars
  } else {
    $vsInstall = $null
    $vsCandidates = @(
      "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools",
      "C:\Program Files\Microsoft Visual Studio\2022\BuildTools",
      "C:\Program Files (x86)\Microsoft Visual Studio\2022\Community",
      "C:\Program Files\Microsoft Visual Studio\2022\Community",
      "C:\Program Files (x86)\Microsoft Visual Studio\2022\Enterprise",
      "C:\Program Files\Microsoft Visual Studio\2022\Enterprise"
    )
    foreach ($v in $vsCandidates) {
      if (Test-Path $v) { $vsInstall = $v; break }
    }
    if (-not $vsInstall) {
      $vswhere = Get-Command -EA SilentlyContinue "vswhere"
      if ($vswhere) {
        $vsOut = & $vswhere -latest -property installationPath 2>&1
        if ($LASTEXITCODE -eq 0 -and $vsOut) { $vsInstall = $vsOut.Trim() }
      }
    }
    if (-not $vsInstall) {
      Stop-Fail "No VS 2022 install found (BuildTools/Community/Enterprise paths, vswhere). Needed for vcvars64.bat."
    }
    $vcvars = Join-Path $vsInstall "VC\Auxiliary\Build\vcvars64.bat"
  }
  if (-not (Test-Path $vcvars)) {
    Stop-Fail "vcvars64.bat not found: $vcvars"
  }

  # cmake — explicit -CMake wins; else PATH.
  $cmakeExe = if ($CMake) { $CMake } else { $null }
  if (-not $cmakeExe) {
    $cmd = Get-Command -EA SilentlyContinue "cmake"
    if ($cmd) { $cmakeExe = $cmd.Source } else { Stop-Fail "cmake not found on PATH. Install CMake (winget install Kitware.CMake) or pass -CMake." }
  }

  Write-Host ("Build: clang-cl = $clangCl")
  Write-Host ("Build: ninja   = $ninja")
  Write-Host ("Build: vcvars  = $vcvars")
  Write-Host ("Build: cmake   = $cmakeExe")

  # Configure in a fresh build tree each run — a stale tree from a different commit
  # would leak artifacts into this build.
  if (Test-Path $BuildDir) {
    Remove-Item -Recurse -Force -Path $BuildDir
  }
  New-Item -ItemType Directory -Path $BuildDir | Out-Null

  # vcvars64.bat must run in the same process as cmake — it puts rc.exe and the SDK
  # lib/include paths on PATH, which clang-cl + the MSVC link rule need. A .bat is the
  # only way to keep those env vars alive across both calls, so we generate one and run it.
  $buildBat = Join-Path $BuildDir ".build.bat"
  $batTemplate = @'
@echo off
setlocal
echo === vcvars ===
call "%VCVARS%"
if errorlevel 1 (
  echo vcvars FAILED
  exit /b 1
)
echo === cmake configure ===
"%CMAKE%" -S "%SRC%" -B "%BUILDDIR%" -G Ninja -DCMAKE_MAKE_PROGRAM="%NINJA%" -DCMAKE_BUILD_TYPE=Release -DRIPWIRE_NATIVE=ON -DCMAKE_C_COMPILER="%CLANG_CL%" -DCMAKE_CXX_COMPILER="%CLANG_CL%"
if errorlevel 1 (
  echo CONFIG_FAILED
  exit /b 1
)
echo === build ===
"%CMAKE%" --build "%BUILDDIR%" --config Release -j 4
if errorlevel 1 (
  echo BUILD_FAILED
  exit /b 1
)
echo BUILD_OK
exit /b 0
'@
  $bat = $batTemplate
  $bat = $bat.Replace("%VCVARS%", $vcvars)
  $bat = $bat.Replace("%CMAKE%", $cmakeExe)
  $bat = $bat.Replace("%SRC%", $RipwireDir)
  $bat = $bat.Replace("%BUILDDIR%", $BuildDir)
  $bat = $bat.Replace("%NINJA%", $ninja)
  $bat = $bat.Replace("%CLANG_CL%", $clangCl)
  Set-Content -Path $buildBat -Value $bat -Encoding ASCII

  # Run the build bat (streams to console; exit code drives the gate).
  $saved = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    & $buildBat
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $saved
  }
  if ($code -ne 0) {
    Stop-Fail ("CMake build failed (exit $code). See the build output above and $BuildDir.")
  }

  # Verify ripwire.exe exists
  $exePath = Join-Path $BuildDir "ripwire.exe"
  if (-not (Test-Path $exePath)) {
    Stop-Fail "Build produced no ripwire.exe at $exePath"
  }
  Write-Host "Build: ripwire.exe built successfully."
}

# ── Prefix resolution (task 4.1) ────────────────────────────────────────────
function Resolve-Prefix {
  $envPrefix = $env:RIPWIRE_INSTALL_PREFIX
  if ($envPrefix) {
    Write-Host "Prefix: using RIPWIRE_INSTALL_PREFIX override"
    return $envPrefix
  }
  if ($Prefix) {
    Write-Host "Prefix: using -Prefix argument"
    return $Prefix
  }
  Write-Host "Prefix: using default global prefix"
  return $DefaultPrefix
}

# ── Atomic binary replace (task 4.2) ────────────────────────────────────────
function Install-Binary([string]$prefix, [string]$exePath) {
  $binDir = Join-Path $prefix "bin"
  New-Item -ItemType Directory -Path $binDir -Force | Out-Null

  # Stage to a temp file in the bin dir, then remove the old binary (if any) and
  # move the staged file over it (same volume — atomic on an empty target).
  $staged = Join-Path $binDir ".ripwire.install.tmp"
  Copy-Item -Path $exePath -Destination $staged -Force
  $dest = Join-Path $binDir "ripwire.exe"
  if (Test-Path $dest) { Remove-Item -Force $dest }
  [System.IO.File]::Move($staged, $dest)
  Write-Host "Install: binary placed at $dest"
}

# ── Wipe-and-restage skills/hooks (task 4.3) ─────────────────────────────────
function Install-SkillsAndHooks([string]$prefix) {
  $shareDir   = Join-Path $prefix "share/ripwire"
  $skillsDir  = Join-Path $shareDir "skills"
  $hooksDir   = Join-Path $shareDir "hooks"

  # Wipe first (cmake --install is additive — a skill this source no longer ships
  # would survive an upgrade and be re-linked as live). Wipe + restage each run.
  if (Test-Path $skillsDir) { Remove-Item -Recurse -Force $skillsDir }
  if (Test-Path $hooksDir)  { Remove-Item -Recurse -Force $hooksDir }

  # Restage skills: create the dir, then copy the SOURCE CONTENTS into it (not the
  # source dir itself, which would nest it).
  $srcSkills = Join-Path $RipwireDir "skills"
  if (Test-Path $srcSkills) {
    New-Item -ItemType Directory -Path $skillsDir -Force | Out-Null
    Get-ChildItem -Path $srcSkills -Force | Copy-Item -Destination $skillsDir -Recurse -Force
    Write-Host "Install: staged skills at $skillsDir"
  } else {
    Write-Warning "No skills directory in the source tree; skipping."
  }

  # Restage hooks: same pattern.
  $srcHooks = Join-Path $RipwireDir "hooks"
  if (Test-Path $srcHooks) {
    New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null
    Get-ChildItem -Path $srcHooks -Force | Copy-Item -Destination $hooksDir -Recurse -Force
    Write-Host "Install: staged hooks at $hooksDir"
  } else {
    Write-Warning "No hooks directory in the source tree; skipping."
  }
}

# ── Version verification gate (task 5.1) ─────────────────────────────────────
function Test-VersionGate([string]$exePath) {
  $versionOut = & $exePath --version 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) {
    Stop-Fail "The built ripwire.exe does not report its version when run; refusing to install it."
  }
  # Extract the first semver-looking token. -match + $matches is more reliable than
  # Select-String's MatchInfo (whose .Groups is null in this PowerShell version).
  if ($versionOut -match "(\d+\.\d+\.\d+)") {
    $v = $matches[1]
    Write-Host "Version gate: binary reports version $v"
  } else {
    Stop-Fail "The built ripwire.exe reports no version string; refusing to install it."
  }
}

# ── PATH append (task 6.1) ───────────────────────────────────────────────────
function Update-Path([string]$prefix, [bool]$elevated) {
  $binDir = Join-Path $prefix "bin"
  $installedExe = Join-Path $binDir "ripwire.exe"

  if ($elevated) {
    # Machine-wide PATH (HKLM)
    $key = "HKLM:\SYSTEM\CurrentControlSet\Control\Session 001\Environment"
    $existing = Get-ItemProperty -Path $key -Name "Path" -ErrorAction SilentlyContinue
    $cur = $existing.Path
    if ($cur -and ($cur -split ';') -contains $binDir) {
      Write-Host "PATH: $binDir is already on the machine PATH."
      return
    }
    $newVal = if ($cur) { "$binDir;$cur" } else { $binDir }
    Set-ItemProperty -Path $key -Name "Path" -Value $newVal
    Write-Host "PATH: appended $binDir to the machine PATH (HKLM)."
  } else {
    # User-level PATH with disclosure (not elevated; HKLM write skipped)
    $userKey = "HKCU:\Environment"
    $existingUser = Get-ItemProperty -Path $userKey -Name "Path" -ErrorAction SilentlyContinue
    $curUser = $existingUser.Path
    if ($curUser -and ($curUser -split ';') -contains $binDir) {
      Write-Host "PATH: $binDir is already on the user PATH."
      return
    }
    $newValUser = if ($curUser) { "$binDir;$curUser" } else { $binDir }
    Set-ItemProperty -Path $userKey -Name "Path" -Value $newValUser
    Write-Host "PATH: appended $binDir to the user-level PATH (not elevated; HKLM write skipped)."
  }

  # Name what was written, and disclose what `ripwire` currently resolves to
  # (mirror of install.sh's "stranger audit": never silently claim a stale ripwire).
  Write-Host ("Installed: " + $installedExe)
  $resolved = (Get-Command ripwire -EA SilentlyContinue).Source
  if ($resolved) {
    if ($resolved -ne $installedExe) {
      Write-Host "NOTE: `0`ripwire`0` on PATH currently resolves to $resolved, not the one just installed — that one runs until PATH puts $binDir first."
    } else {
      Write-Host "NOTE: `0`ripwire`0` resolves to $resolved (the one just installed)."
    }
  }
}

# ── Elevation detection (for PATH scope) ─────────────────────────────────────
# WindowsIdentity.IsElevated returns null in some sandboxed PowerShell runs;
# fall back to a machine-registry write probe (HKLM write is elevated-only).
function Test-IsElevated {
  try {
    $elev = [System.Security.Principal.WindowsIdentity]::GetCurrent().IsElevated
    if ($null -ne $elev) { return [bool]$elev }
  } catch { }
  try {
    Set-ItemProperty -Path "HKLM:\Software\__qwen_elev_probe" -Name "x" -Value 1 -ErrorAction Stop
    Remove-ItemProperty -Path "HKLM:\Software\__qwen_elev_probe" -Name "x" -ErrorAction SilentlyContinue
    return $true
  } catch {
    return $false
  }
}

# ── Main flow ────────────────────────────────────────────────────────────────
$stageSummary = "full run (pull, build, install)"
if ($SkipPull -and $SkipBuild) { $stageSummary = "install only (skip pull, skip build)" }
elseif ($SkipPull)              { $stageSummary = "build + install (skip pull)" }
elseif ($SkipBuild)             { $stageSummary = "pull + install (skip build)" }

Write-Host ("update-ripwire.ps1 v$ScriptVersion — " + $stageSummary)
Write-Host ""

Check-Prerequisites

if (-not $SkipPull) {
  Ensure-Checkout
  Test-CleanTree
  Update-Checkout
} else {
  Write-Host "Pull: skipped (-SkipPull)"
}

$exePath = Join-Path $BuildDir "ripwire.exe"
if ($SkipBuild) {
  if (-not (Test-Path $exePath)) {
    Stop-Fail "-SkipBuild was set but no ripwire.exe exists in $BuildDir — run the full run (or a build) first."
  }
  Write-Host ("Build: skipped (-SkipBuild); using existing $exePath")
} else {
  Build-Ripwire
}

$prefix       = Resolve-Prefix
$binDir       = Join-Path $prefix "bin"
$installedExe = Join-Path $binDir "ripwire.exe"

# Version verification gate before install
Test-VersionGate $exePath

# Install layout
Install-Binary -prefix $prefix -exePath $exePath
Install-SkillsAndHooks -prefix $prefix

# PATH visibility
$isElevated = Test-IsElevated
Update-Path -prefix $prefix -elevated $isElevated

Write-Host ("Done. ripwire is installed at " + $installedExe + ".")
