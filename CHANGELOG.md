# Changelog

## 1.1.16

- Fixed resource-estimate range parsing when the installer uses a restricted global `IFS`.
- Preserved preflight resource reporting and confirmation before download/build operations.

## 1.1.15

- Added host resource preflight before any download or compilation.
- Reports Ubuntu version, CPU model/topology, memory, swap, disk space, and planned build jobs.
- Added conservative build-time estimate and explicit user confirmation.

## 1.1.14

- Added Ubuntu 26.04 CMake 4.x compatibility through `CMAKE_POLICY_VERSION_MINIMUM=3.5` scoped to the EverSDK build environment.

## 1.1.13

- Added explicit `CT_JOBS=2` limit for crosstool-NG on Ubuntu 26.04.
- Retained outer build parallelism controls.

## 1.1.12

- Added conservative host build parallelism control for Ubuntu 26.04 to reduce memory pressure during GCC builds.

## 1.1.11

- Added private GNU Make 4.3 for Ubuntu 26.04 compatibility with the legacy glibc toolchain build.

## 1.1.10

- Added private GCC/G++ 13 host compiler handling for Ubuntu 26.04.

## 1.1.9

- Added Ubuntu 22.04, 24.04, and 26.04 LTS host detection and dependency preflight.

## 1.1.8 and earlier

- Added staged builds, validation before promotion, backup/restore, package ownership tracking, safe removal, ADB contributor support, and verified archive seeding for unreliable upstream mirrors.
