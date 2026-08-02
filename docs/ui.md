# Immediate-mode UI

Arepita Engine builds user interfaces into the same prepared `SpriteBatch` as
the 2D scene. Widgets do not own GPU buffers, allocate retained trees, or issue
individual draw calls. A frame clears one batch, appends scene and UI
instances, then submits the complete batch once.

Coordinates use physical pixels with the origin at the top-left corner. Create
a `UiViewport` from the current drawable size whenever the window changes:

```reimer
from arepita_engine::ui import UiRect, UiViewport;

let viewport = match UiViewport::new(drawable_width, drawable_height) {
    Some(value) => value,
    None => return,
};
```

A zero-sized drawable has no viewport. This is normal while a window is
minimized and should skip UI submission for that frame.

## Images, solid rectangles, and text

`image` appends one atlas region. `text` resolves pre-cooked glyphs directly
from a borrowed `PackedFont`; it does not shape, rasterize, or allocate during
the frame.

`solid` appends an atlas-independent color rectangle through a reserved sprite
material. Solid and textured instances remain in the same upload and draw
call, and changing the application atlas cannot change the rectangle color.

```reimer
from arepita_engine::render import SpriteColor;
from arepita_engine::ui import UiRect, image, solid, text;

let panel = UiRect { x: 24.0, y: 24.0, width: 320.0, height: 96.0 };
image(
    &mut batch,
    viewport,
    panel,
    white_region,
    SpriteColor::rgba(0.06, 0.08, 0.12, 0.92),
    -0.8,
)?;

let layout = text(
    &mut batch,
    &font,
    viewport,
    "Inventory",
    40.0,
    40.0,
    SpriteColor::white(),
    -0.81,
)?;
```

The font is built into the shared atlas by the asset cooker. See
[Cooked assets](assets.md) for font manifests, fallback glyphs, and pack
validation. The current text path supports UTF-8 code points present in the
font pack, newlines, four-space tabs, measurement, and `?` fallback. Advanced
script shaping and bidirectional layout require a future offline shaping
layer; the API does not pretend that glyph lookup alone solves those scripts.

## Buttons

A button is one background region plus centered text. It reads the immutable
frame input snapshot and returns interaction state instead of retaining hidden
widget state:

```reimer
from arepita_engine::render import SpriteColor;
from arepita_engine::ui import UiButtonStyle, UiRect, button;

let style = UiButtonStyle {
    normal: SpriteColor::rgba(0.16, 0.19, 0.24, 1.0),
    hovered: SpriteColor::rgba(0.23, 0.28, 0.36, 1.0),
    held: SpriteColor::rgba(0.10, 0.13, 0.18, 1.0),
    text: SpriteColor::white(),
};
let bounds = UiRect { x: 24.0, y: 140.0, width: 192.0, height: 48.0 };
let response = button(
    &mut batch,
    &font,
    &input,
    viewport,
    bounds,
    white_region,
    "Continue",
    style,
    -0.8,
)?;
if response.clicked {
    resume_game();
}
```

The background region should normally be a small white atlas entry so the
color multiplier can produce every flat UI color without extra textures.
Applications that do not need a textured button background can submit a
`solid` rectangle and label directly.

## Capacity and frame stability

Prepare the shared batch during loading for the worst expected scene plus UI
instance count. `image`, `text`, and `button` use `push_prepared` and return
`UiError::BatchCapacityExceeded` before partially appending a composite widget.
`text` and `button` preflight their full glyph count. This keeps capacity
mistakes visible while guaranteeing no allocator growth in gameplay.

Interaction uses the `Input` snapshot. Call `Input::begin_frame`, observe every
drained event, and then call `Input::update` before UI systems run. A click is
reported on the left-button release while the pointer is inside the rectangle.
