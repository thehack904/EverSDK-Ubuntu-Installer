# Compatibility Matrix

## Validated Ubuntu releases

| Ubuntu release | Installer | Result | Notes |
| --- | --- | --- | --- |
| 22.04.5 LTS | 1.1.x | PASS | Standard host compiler/tooling path |
| 24.04.5 LTS | 1.1.x | PASS | Standard host compiler/tooling path |
| 26.04.1 LTS | 1.1.15+ | PASS | Uses isolated GCC 13, GNU Make 4.3, bounded crosstool-NG jobs, and CMake policy compatibility |

## Successful validation criteria

A build is considered valid only when the installer confirms all of the following:

- upstream `build-sdk.sh` exists;
- CMake ARM toolchain file exists;
- Meson ARM cross file exists;
- `toolchain/bin/arm-linux-gnueabihf-gcc` exists;
- the ARM compiler starts successfully;
- `out/shell.tar.gz` exists.

Only after those checks pass is the staged tree promoted to `~/src/EverSDK`.

## Current upstream baseline

Validated EverSDK commit:

```text
31c85e0cf43a637ce7fd4d8227dbbac79fb7c2b9
```

The installer follows the upstream repository and normal `build-sdk.sh` workflow rather than maintaining a fork of EverSDK.
