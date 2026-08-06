# Dear ImGui vendor package

This package pins Dear ImGui 1.92.8 and Dear Bindings 0.21. It exposes 730
documented core C functions, 30 SDL3/OpenGL3/wgpu backend functions, public
flag constants, ABI types, and safe `SdlOpenGl` and `SdlWgpu` lifecycle
facades. The bundled native artifact currently targets Windows x64.

Both public facades own the Dear ImGui context, process SDL events, validate
frame ordering, expose documented widgets, and shut everything down in the
required reverse order. `SdlOpenGl` borrows an SDL OpenGL context and renders
through the official OpenGL3 backend. `SdlWgpu` borrows a wgpu device and
records draw data into an active render pass. Application code does not need
`unsafe`. The generated `raw` module remains available for advanced
integrations and does require `unsafe` at native calls.

Every generated function and constant carries the comments preserved by Dear
Bindings. The Reimer language server therefore shows the signature and its
Dear ImGui documentation in VS Code hover and completion details.

## Use the package

Add `imgui`, `sdl3`, and the selected renderer package as direct path
dependencies. For OpenGL, create and make the SDL OpenGL context current before
calling `SdlOpenGl::create`. During each iteration:

1. Pass every polled SDL event to `process_event`.
2. Call `new_frame`.
3. Submit the demo window or other widgets.
4. Clear the framebuffer.
5. Call `render` and swap the SDL window.

For wgpu, create `SdlWgpu` from the application's SDL window, wgpu device, and
surface format. Start the UI with `new_frame`, build widgets, then call
`render_to_pass` with the active render-pass encoder before submitting the
frame. Use `wants_mouse` and `wants_keyboard` to prevent captured debug input
from reaching gameplay systems.

Validate the vendor package and the engine-owned adapter from the repository
root:

```powershell
reimer check vendor\imgui --locked
reimer check extensions\imgui --locked
```

Arepita applications should consume the engine-owned adapter in
`extensions/imgui` instead of calling the raw vendor package directly. Native
dependencies are declared transitively in the vendor manifests; Reimer stages
`imgui.dll`, `SDL3.dll`, `wgpu_bridge.dll`, and `wgpu_native.dll` beside a
distributable program without wrapper scripts or `PATH`/`LIB` changes.

## Reproduce the bindings and native bridge

The update script downloads only pinned upstream archives and release assets,
verifies each SHA-256 digest, regenerates the Reimer API from Dear Bindings
metadata, compiles the official SDL3/OpenGL3/wgpu backends, and records output
checksums:

```powershell
vendor\imgui\tools\generate.ps1
```

MSVC x64 build tools are required. Downloaded source, generated C glue, object
files, and symbol files remain under `target/imgui-api-gen`; they are not part
of the vendor package.

The fifteen printf-style variadic functions are intentionally excluded because
Reimer does not expose a C variadic ABI. Use non-variadic helpers such as
`ImGui_TextUnformatted`. Fourteen upstream-internal functions are also omitted;
the inactive `IMGUI_HAS_IMSTR` helper is omitted as well. `coverage.toml`
records these decisions.

Upstream references:

- [Dear ImGui 1.92.8](https://github.com/ocornut/imgui/releases/tag/v1.92.8)
- [Dear Bindings](https://github.com/dearimgui/dear_bindings)
- [Dear ImGui backend guide](https://github.com/ocornut/imgui/blob/master/docs/BACKENDS.md)
