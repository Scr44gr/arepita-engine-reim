# Keyboard, mouse, and gamepads

Arepita Engine samples input into fixed-size frame snapshots. Input queries do
not allocate. Transition methods combine adjacent snapshots with SDL events,
so a tap that begins and ends between two rendered frames is still observed.

## Keyboard and mouse

Create `Input` after the window host, start its frame before draining events,
and sample device state afterward:

```reimer
from arepita_engine::platform import Input;
import arepita_engine::platform::keys;

let mut input = Input::new();

input.begin_frame();
while polling {
    match host.poll_event() {
        Some(event) => input.observe_event(&event),
        None => polling = false,
    }
}
input.update();
if input.key_pressed(keys::ESCAPE) {
    running = false;
}
```

Use `key_down` for continuous movement and `key_pressed` or `key_released` for
one-frame actions. Mouse buttons follow the same convention. Repeated key-down
events do not create new presses. Cursor deltas are computed from snapshots.

## Gamepad ownership

`Gamepads` opens native devices, owns copied UTF-8 names, and reserves a fixed
number of stable slots. It must be released before `WindowHost`:

```reimer
from std::alloc import general_allocator;
from arepita_engine::platform import Gamepads;

let allocator = general_allocator();
let mut gamepads = Gamepads::create(&host, &allocator, 4)?;
defer gamepads.release();
```

Feed every polled event to the manager. Then sample all active devices once:

```reimer
while polling {
    match host.poll_event() {
        Some(event) => {
            let change = gamepads.handle_event(&event);
            // Process the same event for window and application events.
        },
        None => polling = false,
    }
}
gamepads.update();
```

Handles contain a slot and generation. Disconnecting a device invalidates its
old handle, even if another device later reuses the slot.

## Standard controls

The `platform::gamepad` module uses positional face-button names. This avoids
assuming that the bottom button is always labelled A or Cross.

```reimer
import arepita_engine::platform::gamepad;

match gamepads.first() {
    Some(handle) => {
        let movement = gamepads.stick(
            handle,
            gamepad::LEFT_X,
            gamepad::LEFT_Y,
            0.18,
        );
        if gamepads.button_pressed(handle, gamepad::SOUTH) {
            let _ = gamepads.rumble(handle, 0.2, 0.7, 100);
        }
    },
    None => {},
}
```

Thumbsticks are normalized to `-1.0..=1.0`; triggers use `0.0..=1.0`.
`stick` applies a radial dead zone and rescales the remaining range, preserving
direction and full-scale motion. Rumble strengths are clamped to
`0.0..=1.0`.

SDL updates gamepad state through its event loop. `SDL_PollEvent` pumps that
loop automatically, which is why the engine samples after polling rather than
manually updating each device.

Primary SDL references:

- [Gamepad axis ranges](https://wiki.libsdl.org/SDL3/SDL_GetGamepadAxis)
- [Gamepad device events](https://wiki.libsdl.org/SDL3/SDL_GamepadDeviceEvent)
- [Event pumping](https://wiki.libsdl.org/SDL3/SDL_PumpEvents)
