# wgpu vendor package

This package pins wgpu-native 29.0.1.1 and exposes the standard WebGPU C API
plus wgpu-native extensions to Reimer. The generated raw layer preserves the
upstream documentation so signatures, structures, constants, and functions
are available to editor hover and completion.

The package supports the native ABIs used by 64-bit Windows, Linux, and macOS
on x86-64 and AArch64. Release archives are selected by operating system and
architecture and are verified against `artifacts.lock.json` before use.

Raw functions require `unsafe` because they accept native pointers and expose
manual reference-counting rules. Application code should use the safe facade,
which owns handles, performs synchronous adapter/device requests without busy
waiting, and keeps callback trampolines inside the native bridge.

The bridge uses operating-system blocking primitives for callbacks and
`wgpuDevicePoll(wait = true)` for GPU progress because this pinned wgpu-native
release does not implement `wgpuInstanceWaitAny`. It contains no polling loop.

## Use the package

Add the path dependency:

```toml
[dependencies]
wgpu = { path = "../reimer/vendor/wgpu", version = "^29.0" }
```

Run the engine's manifest-backed wgpu window example:

```powershell
reimer run examples\wgpu-clear --release
```

The package manifest supplies the loader and linker inputs transitively, so
the command does not require a wrapper or `PATH`/`LIB` changes.

For window surfaces, use the separate `vendor/wgpu-sdl3` adapter. Keeping the
adapter separate prevents SDL-specific handles and lifetimes from leaking into
the core WebGPU package.

## ABI support

By-value `@repr(C)` descriptors use Microsoft x64, System V AMD64, AAPCS64, or
Apple AArch64 rules according to the target triple. Unsupported 32-bit and
big-endian aggregate ABIs fail explicitly during code generation.

## Reproduce the package

Run the pinned generator from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File vendor\wgpu\tools\generate.ps1
```

Downloads and extraction remain under `target/wgpu-api-gen`. The exact headers
used by the generator are retained under `upstream/include`, while distributable
native runtime files are placed under `native/<platform>`.

Upstream references:

- [wgpu-native](https://github.com/gfx-rs/wgpu-native)
- [WebGPU C headers](https://github.com/webgpu-native/webgpu-headers)
- [WebGPU specification](https://www.w3.org/TR/webgpu/)
