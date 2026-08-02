# SDL3 vendor package

This package provides source-visible SDL 3.4.12 bindings. Its public facade is
application-neutral: reference-counted subsystem initialization, owned windows,
typed event polling, copied keyboard and mouse snapshots, clipboard text,
whole-file loading, SDL timing, owned software surfaces, lifetime-bound renderers,
and gamepad enumeration and handles. Every owned value has explicit cleanup.

Raw pointers and native calls stay inside the facade. A separate `raw`
namespace exposes the generated low-level functions, constants, callbacks, and
ABI types for binding authors; calling native functions remains `unsafe`.

## Binding architecture

The package separates three concerns:

- `raw::functions` is generated from SDL's official dynapi catalog, preserving
  its ABI order and native symbol names.
- `raw::types` is generated from target-preprocessed official headers and
  contains aliases, callbacks, concrete C layouts, and opaque nominal handles.
- `raw::constants` contains all current enum and object-like macro constants.
  Compiler utilities and SDL's deliberate migration-error aliases are recorded
  as exclusions instead of being reintroduced as obsolete API.
- the package root exposes safe, ownership-aware wrappers. These wrappers do
  not contain application input mappings, frame buffers, or rendering policy.

The safe modules are organized by SDL responsibility:

- `init`, `video`, `events`, and `input` cover lifecycle, windows, queued
  events, and copied device state;
- `surface` and `render` own software surfaces and bind renderer lifetimes to
  their window or mutable surface;
- `gamepad` owns SDL identifier arrays and open handles while exposing SDL's
  physical axes and buttons without defining application actions;
- `clipboard`, `files`, and `time` own allocations or provide allocation-free
  process services;
- `gl` binds an OpenGL context to its live window, while the separate OpenGL
  and Vulkan vendors provide their complete generated APIs.

`coverage.toml` is the machine-readable completeness contract. The current
generator emits 1,247 of SDL's 1,270 dynapi functions, 153 aliases, 36 callback
types, 122 concrete or exact-storage records, 1,164 enum constants, and 799 current object-like
macro constants. No current object-like constant is blocked. The remaining 23
functions require C variadics or platform `va_list` and are listed individually.
By-value `SDL_GUID` and `SDL_FColor` calls use the tested Windows x64 C aggregate
ABI. `SDL_Event`, `SDL_HapticEffect`, and `SDL_GamepadBinding` use exact checked
storage because Reimer does not yet expose C unions; the other 42 opaque records
are native handles and forward declarations intended for pointer use, and the
coverage report lists each one explicitly.

## Dependency

Add the package by path from an application manifest:

```toml
[dependencies]
sdl3 = { path = "../reimer/vendor/sdl3", version = "=3.4.12" }
```

Then import only the subsystems an application needs:

```reimer
from sdl3 import Subsystems, Window;
import sdl3::events as events;
import sdl3::init as init;
import sdl3::input as input;
import sdl3::raw::constants as constants;
```

Initialization is reference-counted, and windows own exactly one SDL handle:

```reimer
let systems = Subsystems::init(init::VIDEO | init::EVENTS);
let window = Window::create(
    c"SDL application",
    1280,
    720,
    constants::SDL_WINDOW_RESIZABLE,
);
```

The application must match each `Result`, then call `window.deinit()` before
`systems.deinit()`; `defer` is convenient once both values exist. The `events`
module returns owned event copies, while `input::keyboard_state()` and
`input::mouse_state()` return snapshots that retain no SDL pointers. Applications
remain responsible for mapping physical scancodes and buttons to actions.

## Bundled target

The repository currently ships the official SDL 3.4.12 Visual C++ x64
`SDL3.dll` and `SDL3.lib` under `native/windows-x86_64`. They came from
`SDL3-devel-3.4.12-VC.zip`, whose SHA-256 is recorded in `checksums.sha256`.
The SDL source and binaries use the zlib license in `LICENSE.txt`.

Run a dependent project with the vendored loader and linker paths:

```powershell
.\vendor\sdl3\tools\invoke.ps1 -Project ..\voxel-space-reimer -Command run -Release -Locked
```

For `build`, the launcher also copies `SDL3.dll` beside the generated
executable. Other operating systems can use the same source binding after a
matching, version-pinned native directory and launcher branch are added.

## Updating SDL

1. Select a stable upstream SDL release and record its exact source commit.
2. Update the pinned version, source URL, and published SHA-256 in
   `tools/generate.ps1` and the Rust generator.
3. Replace only the target-specific library files and upstream license.
4. Run the generator. It downloads, verifies, and caches the official source
   archive under `target/sdl-api-gen`. It also compiles C layout assertions for
   every exact-storage union record before writing bindings:

   ```powershell
   .\vendor\sdl3\tools\generate.ps1
   ```

   Pass `-SdlSource C:\source\SDL` only to test an already verified local source
   tree.

5. Review every `coverage.toml` change and every newly opaque or concrete type.
6. Regenerate `checksums.sha256`, then run format, check, and tests.

Generated source must not be edited by hand. Update the Rust generator or a
safe facade module so regeneration remains deterministic.
