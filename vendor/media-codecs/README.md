# Media codecs vendor

This package is a narrow, engine-independent codec boundary for Reimer tools.
It decodes PNG images, rasterizes OpenType/TrueType glyphs, and decodes WAV,
Ogg Vorbis, or MP3 audio. It does not contain atlas placement, composition,
asset IDs, manifests, APACK serialization, renderer state, or game logic.

The public Reimer facade owns every returned allocation. Native objects use
validated integer handles rather than exposed pointers, and every native ABI
entry catches dependency panics before they cross into Reimer. Fixed-width
`@repr(C)` structures carry both a byte size and API revision. Caller-provided
limits bound encoded input, decoded output, and image dimensions.

## Build

```powershell
./tools/build.ps1 -Profile release
```

The script builds the Rust bridge with its locked dependency graph, copies the
platform artifact under `native/<os>-<architecture>`, and refreshes
`checksums.sha256`. Supported artifact layouts are Windows, Linux, and macOS on
x86-64 or AArch64. Each artifact must still be built and tested on its target
platform before a release advertises that platform.

The bridge is Rust only because mature memory-safe implementations already
exist for compressed image, font, and audio formats. All asset orchestration
and output-format logic stays in Reimer.

## Licensing

The bridge source is available under MIT or Apache-2.0. Its direct Rust
dependencies are permissively licensed:

- `fontdue`: MIT, Apache-2.0, or Zlib
- `image`: MIT or Apache-2.0
- `symphonium`: MIT or Apache-2.0

Consult `bridge/Cargo.lock` for the complete transitive dependency inventory.
