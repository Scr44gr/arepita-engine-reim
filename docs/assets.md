# Cooked assets

Arepita Engine converts source images and audio into one validated `.apack` file before the game starts. Shipping code does not include PNG, Ogg Vorbis, or MP3 decoders, does not pack sprites at runtime, and does not allocate while resolving an asset ID.

## Manifest

Paths are relative to the manifest. Canonical path validation rejects absolute paths, `..` escapes, and symlinks that leave the manifest directory.

```toml
[audio_settings]
sample_rate = 48000

[limits]
max_source_bytes = 67108864
max_decoded_bytes = 536870912
max_image_dimension = 8192
max_assets = 100000
max_pack_bytes = 1073741824
max_parallel_decode_bytes = 67108864

[[atlases]]
id = "world"
width = 2048
height = 2048
padding = 2

[[atlases.sprites]]
id = "actor/player/idle-0"
path = "sprites/player-sheet.png"
source_x = 0
source_y = 0
source_width = 24
source_height = 24

[[atlases.fonts]]
id = "font/ui"
path = "fonts/ui.otf"
pixel_size = 32.0
characters = " ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!?.,:-"

[[audio]]
id = "audio/step/grass"
path = "audio/grass-step.ogg"
```

IDs contain lowercase ASCII letters, digits, `.`, `_`, `-`, and `/`. The
cooker rejects duplicate IDs and hash collisions. A sprite may select a source
rectangle by providing all four `source_*` fields; partial rectangles, zero
sizes, and out-of-bounds regions fail the build.

Entries that reference the same image path are probed and decoded once. Every
selected rectangle is copied directly from that decoded sheet into the atlas;
the cooker never allocates a cropped intermediate. Independent unique images
decode in bounded parallel batches, regions are packed by the deterministic
skyline layout, and edge texels are extruded through the configured padding to
prevent texture bleeding. This makes hundreds of frames from a large sheet
cost one source decode while storing only the frames the game ships.

OTF/TTF glyph coverage is rasterized offline and packed into the same atlas,
so text and world sprites can share one draw batch. Audio is verified,
resampled offline, converted to stereo interleaved F32, and bounded by the
manifest limits.

## Build a pack

```powershell
.\tools\cook-assets.ps1 `
    -Manifest .\game-assets\assets.toml `
    -Output .\game-assets\build\game.apack
```

The destination is published atomically. Identical inputs and settings produce byte-identical output even though independent assets decode in parallel.

## Load and use assets

Hash each ID once during setup and retain the small `AssetId` value. Lookups then binary-search the validated on-disk table without allocating.

```reimer
from std::alloc import general_allocator;

from arepita_engine::asset import AssetId, AssetPack;
from arepita_engine::audio import AudioClip;

let allocator = general_allocator();
let mut pack = AssetPack::load(&allocator, "assets/game.apack")?;
defer pack.release();

let world_id = AssetId::from("world");
let grass_id = AssetId::from("world/grass");
let atlas = pack.atlas(world_id)?;
renderer.set_sprite_atlas_rgba8(
    atlas.width(),
    atlas.height(),
    atlas.pixels(),
)?;
let grass_region = pack.region(grass_id)?;

let font = pack.font(AssetId::from("font/ui"))?;
let layout = font.push_text(
    &mut batch,
    "Ready!",
    24.0,
    680.0,
    SpriteColor::white(),
    0.9,
)?;

let step = pack.audio(AssetId::from("audio/step/grass"))?;
let clip = AudioClip::from_f32_le_bytes(
    &allocator,
    step.sample_rate(),
    step.channels(),
    step.bytes(),
)?;
```

`PackedAtlas`, `PackedFont`, and `PackedAudio` borrow the pack. The ownership checker prevents releasing the pack while a view is live. Font lookup and UTF-8 layout perform no allocation; `push_text` checks the complete required sprite capacity before changing the batch, so a capacity error never leaves partial text behind. Missing glyphs fall back to `?` when that character was cooked. Audio decoding creates only the final `AudioClip` allocation.

## Validation and trust

Loading validates the complete header, format version, file length, table size, entry count, offsets, 16-byte payload alignment, sorted hashes, portable IDs, kind-specific metadata, region-to-atlas references, and CRC-32 of every payload. The default load limit is 1 GiB; use `AssetPack::load_bounded` for a smaller title-specific ceiling.

CRC-32 detects accidental corruption. It does not authenticate downloaded content. Games that update assets over an untrusted channel should verify a signed manifest or a cryptographic digest before opening the pack.

## Binary layout

All integers and IEEE-754 samples are little endian.

| Section | Layout |
|---|---|
| Header | 64 bytes: magic, major/minor version, entry count, table/name/data offsets, declared file length |
| Entry table | Sorted fixed-size 96-byte records containing kind, ID hash, name and payload ranges, CRC-32, and ten kind-specific `u32` fields |
| Names | Concatenated validated UTF-8/ASCII IDs |
| Payloads | 16-byte-aligned atlas or audio data |

Current kinds are RGBA8 sRGB atlases, atlas regions, stereo interleaved F32 audio, and sorted fixed-size font glyph tables. Unknown versions or kinds fail closed.
