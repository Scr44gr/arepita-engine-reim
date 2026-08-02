# Vendored platform packages

Arepita Engine keeps its native platform boundary in three application-neutral
packages copied from the Reimer vendor set:

- `sdl3` pins SDL 3.4.12 and owns windows, events, input, and subsystem state;
- `wgpu` pins wgpu-native 29.0.1.1 at commit
  `6aed50955d934ac36049ba8d002034841633ae02`;
- `wgpu-sdl3` adapts SDL native window handles to a WebGPU surface on Windows,
  Linux, and macOS.

The engine does not put gameplay input mappings, renderer batches, cameras, or
application state in these packages. Generated raw APIs remain available for
binding work, while normal engine code uses ownership-aware facades.

Upstream source locks, artifact hashes, ABI coverage files, and license texts
are stored beside each package. Regeneration tools download into `target/` and
verify the pinned checksums before replacing generated files.
