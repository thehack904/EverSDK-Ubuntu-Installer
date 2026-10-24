# EverSDK Ubuntu Installer

A reproducible, reversible setup utility for building [EverSDK](https://github.com/JohnnyonFlame/EverSDK) on supported Ubuntu LTS releases.

The installer is intended for EverSDK contributors and homebrew developers who want a repeatable way to install dependencies, build the upstream SDK, validate the resulting ARM toolchain, back up an existing installation, restore it, or remove installer-created files.

## Supported Ubuntu releases

| Ubuntu | Status |
| --- | --- |
| 22.04 LTS | Validated |
| 24.04 LTS | Validated |
| 26.04 LTS | Validated |

Ubuntu 26.04 requires additional compatibility handling for newer host toolchain components. The installer applies those workarounds only inside the EverSDK build environment and does not replace the system compiler, GNU Make, or CMake configuration.

## What the installer does

The menu provides:

1. Install / update / build EverSDK
2. Back up the current EverSDK installation
3. Restore the latest EverSDK backup
4. Show status
5. Remove EverSDK and installer-created files
6. Exit

The installer builds updates in a staging directory first. A failed build does not replace the currently installed EverSDK tree.

Before a new build starts, the installer also reports the detected CPU, memory, swap, available disk space, planned build parallelism, and a conservative estimated build-time range. The user must confirm before downloads or compilation begin.

## Installation

Download or clone this repository, then run the script as your normal user:

```bash
chmod +x install-eversdk-ubuntu-lts.sh
./install-eversdk-ubuntu-lts.sh
```

Do **not** run the installer with `sudo`. It invokes `sudo` itself only for required APT package operations.

## Default installation location

EverSDK is installed at:

```text
~/src/EverSDK
```

Build logs, backups, and installer state are stored under the user's local state directory.

## Safety and rollback design

The installer is intentionally conservative:

- existing EverSDK installations are backed up before replacement;
- new builds occur in timestamped staging directories;
- staging builds are validated before promotion;
- failed builds leave the current installation untouched;
- only APT packages that were absent before the installer added them are recorded as installer-owned;
- package removal is optional;
- `apt autoremove` is never invoked automatically;
- upstream source archives retain their normal integrity checks.

## Ubuntu 26.04 compatibility

Ubuntu 26.04 ships newer host development tools than those used when the current EverSDK toolchain was originally developed. The installer isolates the required compatibility measures to the build process, including:

- GCC/G++ 13 as the host compiler for the EverSDK build;
- GNU Make 4.3 in a private build environment;
- bounded build parallelism for crosstool-NG/GCC;
- a CMake policy compatibility floor for older upstream projects.

These changes do not alter the system-wide compiler or Make configuration.

## Hardware access

`adb` is installed as a contributor utility when needed. A connected Evercade device is **not** required for a successful SDK installation or validation.

## Upstream project

This repository does not contain or fork EverSDK. It clones and builds the upstream project from:

https://github.com/JohnnyonFlame/EverSDK

EverSDK and all third-party components remain subject to their respective upstream licenses and terms.

## Project status

Current installer version: **1.0.0**

See [CHANGELOG.md](CHANGELOG.md) for release history and [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) for the tested platform matrix.

## License

The installer code in this repository is released under the MIT License. See [LICENSE](LICENSE).

This license applies only to this repository's installer and documentation. It does not relicense EverSDK or any upstream component downloaded or built by the installer.

## Disclaimer

This is a community-maintained contributor utility. It is not an official Evercade or EverSDK distribution.
