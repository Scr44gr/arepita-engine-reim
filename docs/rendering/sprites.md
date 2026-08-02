# Sprite rendering

The current renderer draws packed textured or colored sprites through SDL3 and
wgpu. The pipeline, sampler, atlas binding, and instance buffer are persistent;
a frame uploads one contiguous `SpriteInstance` slice and submits one instanced
draw call.

## Ownership

```reimer
let mut host = WindowHost::create(c"Game", 1280, 720)?;
defer host.release();

let window = host.window()?;
let mut renderer = Renderer::create(window, 16_384)?;
defer renderer.release();

let allocator = general_allocator();
let mut sprites = SpriteBatch::with_capacity(&allocator, 16_384)?;
defer sprites.deinit();
sprites.prepare_sorting(16_384)?;
```

`Renderer` borrows the SDL window and owns every GPU child. Release it before
the `WindowHost`; the `defer` order above does that automatically.

## Presentation policy

`Renderer::create` defaults to `PresentationMode::Fifo`, which is guaranteed by
WebGPU and prevents tearing. Benchmarks or latency-sensitive applications can
request another mode explicitly:

```reimer
let config = RendererConfig::new(50_000)
    .with_presentation_mode(PresentationMode::Immediate);
let mut renderer = Renderer::create_with_config(window, config)?;
```

`Immediate` minimizes latency but may tear. `Mailbox` keeps only the newest
queued frame without tearing, while `FifoRelaxed` may present late frames
immediately. These modes are platform-dependent. Creation returns
`RendererError::PresentModeUnavailable` when the surface and adapter do not
support the requested policy; the engine never changes the requested workload
silently. The selected mode is retained when `renderer.resize()` reconfigures
the surface.

## Atlas upload

Upload one tightly packed sRGB RGBA8 atlas during loading:

```reimer
renderer.set_sprite_atlas_rgba8(width, height, pixels)?;

let region = AtlasRegion::from_pixels(
    width,
    height,
    tile_x,
    tile_y,
    tile_width,
    tile_height,
)?;
```

The upload validates dimensions and exact byte length before crossing the
native boundary. Replacing an atlas is transactional: the active atlas remains
usable if texture creation, binding, or upload fails.

## Application material shader

Games may replace the built-in sprite WGSL during loading:

```reimer
let mut renderer = Renderer::create(window, 16_384)?;
renderer.set_sprite_shader(GAME_SPRITE_SHADER)?;
```

Replacement is transactional. Compilation and binding are completed before
the previous pipeline is released; a failure leaves the working pipeline,
atlas texture, sampler, and instance buffer untouched. The replacement uses
the same atlas binding at group 0 (`sampler` at binding 0 and `texture_2d<f32>`
at binding 1), triangle-strip topology, and alpha blending.

The 64-byte instance input ABI is:

| Location | WGSL type | Byte offset | Values |
| ---: | --- | ---: | --- |
| 0 | `vec4<f32>` | 0 | position XY, size XY |
| 1 | `vec4<f32>` | 16 | rotation sine/cosine, UV min X, UV max Y |
| 2 | `vec4<f32>` | 32 | UV max X, UV min Y, color RG |
| 3 | `vec2<f32>` | 48 | color BA |
| 4 | `u32` | 56 | application material data in low 16 bits, material in high 16 bits |
| 5 | `f32` | 60 | transparent sort depth |

Application material indices are selected with `with_material`. Index 65,535
remains reserved for atlas-independent solid rectangles. Shader source is not
retained after pipeline creation, so it may be released with other loading
data. `with_material_data` supplies the low 16 bits without changing the
instance width; custom shaders may use them for compact indices, flags, or
quantized coordinates.

## Frame path

Populate the batch, draw it, then clear it while retaining capacity:

```reimer
let instance = SpriteInstance::new(x, y, width, height)
    .with_region(region)
    .with_color(SpriteColor::white())
    .with_depth(depth);
sprites.push(instance)?;
sprites.sort_back_to_front()?;
let report = renderer.draw_sprites(
    &sprites,
    ClearColor::rgba(0.02, 0.03, 0.06, 1.0),
)?;
sprites.clear();
```

Atlas-independent rectangles use the reserved solid material and stay in the
same instance upload and draw call:

```reimer
let panel = SpriteInstance::solid(
    x,
    y,
    width,
    height,
    SpriteColor::rgba(0.08, 0.10, 0.14, 0.95),
).with_depth(depth);
sprites.push(panel)?;
```

`RenderReport` exposes `draw_calls`, `instances`, and `uploaded_bytes` for
profiling. `renderer.allocated_gpu_bytes()` reports persistent instance-buffer
memory tracked by this backend.

The sprite pipeline uses alpha blending and intentionally has no depth buffer.
Call `prepare_sorting` during loading, then `sort_back_to_front` after scene and
UI extraction when transparent order matters. The stable four-pass radix sort
draws larger depth values first and smaller values last; equal depths preserve
submission order. It performs linear work and uses only its prepared scratch
storage. A missing scratch budget or non-finite depth returns `SortError`
without partially reordering the batch.

`SpriteInstance` currently uses normalized device coordinates: `(-1, -1)` is
the lower-left corner and `(1, 1)` is the upper-right corner. Source image
decoding and spritesheet cropping happen offline in the cooker. Multi-atlas
rendering and general material batching remain planned renderer layers; they
are not silently emulated by per-sprite draw calls.

When SDL reports a window-size or pixel-density change, call
`renderer.resize()`. A zero-sized window suspends presentation without being
treated as a fatal error.
