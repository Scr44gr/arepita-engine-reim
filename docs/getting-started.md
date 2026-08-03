# Getting started

Arepita Engine is a Reimer package. During early development it expects the
engine and language repositories to be sibling directories:

```text
Documents/
  reimer/
  arepita-engine/
```

## Check and test

From the Reimer repository, run:

```powershell
cargo run -q -p reimer-cli -- check ..\arepita-engine --refresh
cargo run -q -p reimer-cli -- test ..\arepita-engine --release --refresh
```

Native tests and examples need the SDL3 and wgpu-native library directories in
`PATH` and `LIB`. The repository-level development script configures those
paths without changing the machine-wide environment:

```powershell
.\tools\dev.ps1 test
.\tools\dev.ps1 sprites
.\tools\dev.ps1 audio
.\tools\dev.ps1 bench
```

Source PNG and audio files should be converted into a deterministic runtime pack before shipping. See [Cooked assets](assets.md) for the manifest, build command, zero-copy atlas upload, and audio loading API.

## Package dependency

Add the engine as a path dependency while the public package registry is not
available:

```toml
[dependencies]
arepita_engine = { package = "arepita-engine", path = "../arepita-engine", version = "^0.1" }
```

Application code can then import only the layer it needs:

```reimer
from arepita_engine::ecs import Component, Entities, Query, Registry;
from arepita_engine::platform import Gamepads, Input, WindowHost;
from arepita_engine::render import Renderer, SpriteBatch;
from arepita_engine::ui import UiRect, UiViewport, button, image, text;
```

Read [Immediate-mode UI](ui.md) before building menus or HUDs. Its primitives
share the prepared sprite batch and therefore add no per-widget allocations or
draw calls.

## Ownership rule

Every owning engine type exposes an idempotent `release` or `deinit` method.
Register it with `defer` immediately after successful creation. The high-level
`Renderer` owns its GPU children and releases them in dependency order, while
the application continues to own the SDL `WindowHost`.

No engine-facing API requires `unsafe`. Native pointer work remains inside the
vendored SDL3, wgpu, and platform adapters.
