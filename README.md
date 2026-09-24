# ripwire-win

A small Windows install route for [**ripwire**](https://github.com/redhat-et/ripwire):
a PowerShell installer that clones the upstream repository, builds it with
clang-cl + Ninja, and installs the binary to a chosen prefix.

> **Note:** Everything in this repository (the installer, the documentation,
> and the surrounding tooling) was created with the help of AI. The only
> thing vendored from upstream is the `ripwire/` source checkout, which is
> cloned by the installer and kept in sync with
> [https://github.com/redhat-et/ripwire](https://github.com/redhat-et/ripwire).

## What's here

| Path | Purpose |
| --- | --- |
| `update-ripwire.ps1` | The installer script (clone / pull / build / install). |
| `update-ripwire.bat` | A thin launcher so the script can be run from a plain command prompt. |
| `.gitignore` | Keeps the repo to just the two files above; build/checkout dirs are ignored. |

The `ripwire/` directory is **not** committed — the installer creates it.

## Requirements

The installer auto-discovers tools when possible, but on a typical Windows dev
box the following are expected:

- **git** — to clone and pull the upstream checkout.
- **CMake** — for configure/build.
- **clang-cl** (LLVM) — the C/C++ compiler.
- **Ninja** — the build generator.
- **Visual Studio 2022 Build Tools** (or 2019) — for `vcvars64.bat`, which
  puts the MSVC SDK `rc.exe`/include/lib paths on `PATH`. Without this the
  MSVC link rule fails even when clang-cl works.

## Installation

A full run (clone if needed, pull, build, install) from the repo root:

```bat
update-ripwire.bat
```

or directly:

```bat
powershell -ExecutionPolicy Bypass -File .\update-ripwire.ps1
```

### Common options

```bat
:: Install to a writable prefix (e.g. when not elevated; C:\Program Files needs elevation)
update-ripwire.bat -Prefix D:\ripwire-install

:: Use explicit tool paths (useful when LLVM/Ninja/CMake are not on PATH)
update-ripwire.bat ^
  -ClangCl "C:\Program Files\LLVM\bin\clang-cl.exe" ^
  -Ninja "C:\Users\you\AppData\Local\Microsoft\WinGet\cache\ninja.exe" ^
  -Vcvars "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" ^
  -CMake "C:\Program Files\CMake\bin\cmake.exe" ^
  -Prefix "D:\ripwire-install"

:: Install only (no pull, no build) — needs a pre-built ripwire.exe
update-ripwire.bat -SkipPull -SkipBuild -Prefix D:\ripwire-install

:: Show version / usage
update-ripwire.bat --version
update-ripwire.bat --help
```

### What a full run does

1. **Clone / pull** — clones `ripwire/` from `https://github.com/redhat-et/ripwire`
   if the checkout is missing, otherwise pulls the latest `main`.
2. **Build** — configures with CMake + Ninja, `RIPWIRE_NATIVE=ON`, `Release`,
   using clang-cl.
3. **Install** — copies `ripwire.exe` to `<prefix>/bin/`, stages skills/hooks
   under `<prefix>/share/ripwire/`, and appends `<prefix>/bin` to the user
   `PATH` if it isn't already present.

The default install prefix is `C:\Program Files\ripwire`; pass `-Prefix` for
a writable location when running without elevation.

## Upstream

This project is an external installer only — it does not fork or modify ripwire.
All source code comes from the upstream repository:

- **Upstream:** https://github.com/redhat-et/ripwire
- **Upstream docs:** https://github.com/redhat-et/ripwire/blob/main/docs/OVERVIEW.md

## License

This repository (installer + docs) is provided as-is for convenience. The
upstream ripwire code is governed by [its own license](https://github.com/redhat-et/ripwire/blob/main/LICENSE).
