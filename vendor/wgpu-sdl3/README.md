# SDL3 surface adapter for wgpu

This package creates an owning `wgpu::Surface` from a borrowed `sdl3::Window`
without adding platform-specific state to either vendor package.

Supported native window systems:

- Windows: `HWND` and `HINSTANCE` from SDL window properties.
- Linux: Wayland when SDL exposes a Wayland display and surface, otherwise
  Xlib.
- macOS: an SDL Metal view whose `CAMetalLayer` remains alive until the WebGPU
  surface is released.

Create the adapter after the SDL window and WebGPU instance. Destroy it before
the SDL window. On macOS, `WindowSurface::deinit` releases the WebGPU surface
before destroying the SDL Metal view, preserving the required native lifetime.

`create_surface(&window, instance)` consumes the `Instance` owner. The created
`wgpu::Surface` retains the native instance reference it needs, while
`WindowSurface` borrows the SDL window so the compiler rejects destroying or
moving that window too early. Pass `instance.clone_ref()` when the application
needs to keep its original instance owner.
