# Changelog

## v1.0.0 — Initial Public Release

This is the first public release of EverSDK Ubuntu Installer.

The installer was developed and validated through a series of internal
pre-release builds numbered 1.1.0 through 1.1.16. Those numbers represent
development iterations only and were never public releases. Public semantic
versioning begins with v1.0.0.

### Included in v1.0.0

- Supports Ubuntu 22.04 LTS, 24.04 LTS, and 26.04 LTS.
- Uses the upstream JohnnyonFlame/EverSDK repository and normal `build-sdk.sh`
  workflow rather than maintaining a fork.
- Builds in a timestamped staging tree and validates the completed SDK before
  replacing an existing installation.
- Automatically backs up an existing EverSDK installation before replacement.
- Provides manual backup, restore, status, and clean removal operations.
- Tracks only APT packages that were absent before the installer introduced
  them.
- Does not run `apt autoremove`.
- Includes ADB as a host-side contributor utility without requiring an attached
  Evercade device for installation or validation.
- Preloads selected verified upstream archives when required to work around
  unreliable or inaccessible mirrors while retaining checksum validation.
- Adds Ubuntu 26.04 host compatibility using an isolated GCC/G++ 13 compiler,
  private GNU Make 4.3, bounded crosstool-NG parallelism, and a CMake policy
  compatibility floor.
- Performs a host-resource preflight before downloads or compilation.
- Reports CPU, CPU topology, memory, swap, available disk space, planned build
  parallelism, and a conservative build-time estimate.
- Requires explicit user confirmation before beginning downloads or compilation.
- Uses the standalone state directory
  `~/.local/state/eversdk-ubuntu-installer`.
- Safely migrates state from the pre-release development path
  `~/.local/state/commander-keen-evercade/eversdk-installer`, preserving
  backups, logs, package-ownership history, and last-success metadata.

## Pre-release Development History

The following versions were internal development/test iterations that led to
v1.0.0. They are documented for engineering traceability only and are not part
of the public release sequence.

### Development 1.1.16

- Fixed resource-estimate range parsing when the installer uses a restricted
  global `IFS`.
- Preserved preflight resource reporting and confirmation before download/build
  operations.

### Development 1.1.15

- Added host resource preflight before any download or compilation.
- Reports Ubuntu version, CPU model/topology, memory, swap, disk space, and
  planned build jobs.
- Added conservative build-time estimate and explicit user confirmation.

### Development 1.1.14

- Added Ubuntu 26.04 CMake 4.x compatibility through
  `CMAKE_POLICY_VERSION_MINIMUM=3.5` scoped to the EverSDK build environment.

### Development 1.1.13

- Added explicit `CT_JOBS=2` limit for crosstool-NG on Ubuntu 26.04.
- Retained outer build parallelism controls.

### Development 1.1.12

- Added conservative host build parallelism control for Ubuntu 26.04 to reduce
  memory pressure during GCC builds.

### Development 1.1.11

- Added private GNU Make 4.3 for Ubuntu 26.04 compatibility with the legacy
  glibc toolchain build.

### Development 1.1.10

- Added private GCC/G++ 13 host compiler handling for Ubuntu 26.04.

### Development 1.1.9

- Added Ubuntu 22.04, 24.04, and 26.04 LTS host detection and dependency
  preflight.

### Development 1.1.8 and earlier

- Added staged builds, validation before promotion, backup/restore, package
  ownership tracking, safe removal, ADB contributor support, and verified
  archive seeding for unreliable upstream mirrors.

Public release numbering begins at v1.0.0.
