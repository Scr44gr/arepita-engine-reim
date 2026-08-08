# Native runtime ownership

`run_native` is the application boundary for SDL3 and wgpu games. A game
describes its state, assets, scene extraction, audio translation, and optional
development panels. Arepita owns the native session and drives those callbacks
at fixed lifecycle barriers.

Application code should not create a second event loop, clock, renderer,
sprite batch, or ImGui frame. Keeping those operations in one owner guarantees
that input is advanced once, simulation stages keep a deterministic order, and
every drawable frame is submitted and presented exactly once.

## Frame order

One outer frame runs in this order:

1. Begin the input snapshot and drain all SDL events.
2. Forward every raw event to input, gamepads, and the optional extension.
3. Apply resize and quit events, then finalize input and gamepad state once.
4. Sample bounded frame time and advance the fixed-step accumulator.
5. Let the game translate the input snapshot into its typed resources. ImGui
   capture is applied here, without hiding raw release events from the engine.
6. Run `Input` once, `Update` and `Physics` for every fixed step, then `Async`
   once.
7. Let the game translate domain audio requests and maintain audio once.
8. For a drawable surface, begin the optional extension frame, run `Render`
   and `RenderUi`, extract and order sprites, record the extension overlay, and
   present exactly once.
9. On exit, call the game shutdown hook once and release owners in dependency
   order.

The application can request an exit through its `NativeState`. Window closure
and fatal failures have separate `ExitReason` values, so persistence code can
avoid saving partially updated state after a fatal error.

## Ownership boundary

Arepita owns:

- SDL initialization, the window, events, input, and gamepads;
- the frame clock and bounded fixed-step clock;
- the renderer, surface resize, sprite batch, GPU frame, and presentation;
- the lifecycle and ordering of optional native extensions such as ImGui;
- native cleanup order and the single shutdown boundary.

The game owns:

- its `NativeState` and registered systems;
- cooked assets and domain-specific rendering configuration;
- input mapping from engine snapshots to gameplay resources;
- translation from gameplay feedback to engine audio commands;
- scene extraction into the engine-owned `SpriteBatch`;
- save policy and other domain-specific shutdown work.

The game provides these operations through `NativeGame<State, Owner>`. The
descriptor is monomorphized for its state and owner, so integration does not
require reflection, string lookup, virtual dispatch, or a heterogeneous
runtime map.

## Optional development extensions

`NativeExtension<State, Owner>` adds tooling without moving lifecycle work
back into the game. The ImGui package supplies `create_imgui_plugin`, which
owns event forwarding, input capture, `new_frame`, render recording, and
cleanup. A game-specific debug package only defines its panel state and draw
callback.

Release builds can use `create_no_native_extension`. The core engine therefore
does not acquire an ImGui linkage requirement when development tooling is not
selected.

Native applications may explicitly select the graphics API through
`NativeAppConfig::with_renderer_backend(RendererBackend::Vulkan)` or
`RendererBackend::OpenGl`. `RendererBackend::Automatic` preserves wgpu-native's
platform selection. The choice is made while requesting the presentation
adapter, so the engine and ImGui integration remain backend-neutral.

## Low-level APIs

`WindowHost`, `Input`, `Gamepads`, and `Renderer` remain public for focused
examples, backend tests, and tools that require a custom native loop. They are
not the normal application path. A game using `run_native` must not construct
or advance those services itself.
