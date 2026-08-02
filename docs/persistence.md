# Versioned persistence

Arepita Engine separates game-specific serialization from file publication.
`SaveWriter` and `SaveReader` encode a compact payload without allocation.
`SaveBuffer` wraps that payload in a bounded, versioned envelope, while
`write_atomic` publishes the complete envelope through a synchronized temporary
file.

## Encoding game state

Prepare payload storage once, write fields in a documented order, and use a
schema number whenever that order or meaning changes.

```reimer
from arepita_engine::persistence import SaveBuffer, SaveWriter, write_atomic;
from std::alloc import allocate_bytes, general_allocator;
from std::slice import byte_range;

let allocator = general_allocator();
let mut payload_storage = allocate_bytes(&allocator, 256)?;
defer payload_storage.release();

let payload_length = {
    let mut writer = SaveWriter::new(payload_storage.as_mut_bytes());
    writer.write_u64(player_id)?;
    writer.write_f32(position_x)?;
    writer.write_f32(position_y)?;
    writer.write_str(display_name)?;
    writer.position()
};

let payload = match byte_range(
    payload_storage.as_bytes(),
    0,
    payload_length,
) {
    Some(value) => value,
    None => panic("prepared payload length became inconsistent"),
};
let mut save = SaveBuffer::from_payload(&allocator, 3, payload)?;
defer save.release();
write_atomic("saves/world.save", "saves/world.save.tmp", &save)?;
```

Every variable-length byte sequence and UTF-8 string uses a little-endian
`u32` byte length. Primitive values are little-endian. `write_bytes` and
`write_str` reject insufficient capacity before modifying the output, so a
failed field write never leaves a partial field behind.

## Loading and migration

`SaveDocument::load` checks the file-size ceiling before allocating, validates
the fixed header, verifies both checksums, and then exposes the payload as a
zero-copy borrowed slice.

```reimer
from arepita_engine::persistence import SaveDocument, SaveReader;

let mut document = SaveDocument::load(&allocator, "saves/world.save")?;
defer document.release();

match document.schema() {
    3 => {
        let payload = document.payload()?;
        let mut reader = SaveReader::new(payload);
        let player_id = reader.read_u64()?;
        let position_x = reader.read_f32()?;
        let position_y = reader.read_f32()?;
        let display_name = reader.read_str()?;
        reader.finish()?;
        restore_player(player_id, position_x, position_y, display_name);
    },
    2 => migrate_schema_two(&document)?,
    _ => report_unsupported_schema(document.schema()),
}
```

The envelope format has its own format version. The schema is application
owned. Keep migrations explicit and bounded; never reinterpret an old payload
as the latest struct layout.

## Envelope layout

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 8 | `ARESAVE\0` magic |
| 8 | 2 | envelope format version |
| 10 | 2 | header size (`32`) |
| 12 | 4 | application schema |
| 16 | 8 | payload byte length |
| 24 | 4 | payload CRC-32/ISO-HDLC |
| 28 | 4 | CRC-32/ISO-HDLC of header bytes `0..28` |
| 32 | variable | application payload |

The default payload ceiling is 64 MiB. Use `from_payload_bounded` and
`load_bounded` when a smaller game-specific limit is appropriate. Smaller
limits reduce both denial-of-service surface and worst-case memory use.

## Publication and security contract

`write_atomic` writes and synchronizes the temporary file before atomically
replacing the destination. The temporary path must be a dedicated engine-
managed name in the same directory as the destination. Keeping both paths on
the same filesystem is required by the replacement operation. The old
destination remains untouched when writing, synchronization, or replacement
fails.

The implementation calls `File::sync_all`, not only `flush`, before replacement.
Rust documents `sync_all` as attempting to synchronize file content and
metadata, while `rename` remains limited to paths on the same filesystem:
[File::sync_all](https://doc.rust-lang.org/std/fs/struct.File.html#method.sync_all)
and [std::fs::rename](https://doc.rust-lang.org/std/fs/fn.rename.html).

The current API does not synchronize the parent directory after replacement.
Atomic visibility is provided, but persistence of the directory entry across a
sudden power loss remains filesystem- and platform-dependent. A game that
requires the strongest crash-consistency guarantee should keep a previous save
or journal until a later successful startup confirms the new file.

CRC detects accidental corruption. It is not encryption and does not prove who
created a file. Treat attacker-controlled saves as untrusted: retain strict
size limits, reject invalid enums and counts in the game-specific decoder, and
use an authenticated format when tamper resistance is required. Coordinate
multiple writers externally; one temporary path is intentionally not a locking
protocol.

## Memory ownership

- `SaveWriter` and `SaveReader` only borrow caller-owned memory.
- `SaveBuffer` owns exactly one envelope allocation and releases it with
  `release`.
- `SaveDocument` owns exactly one file allocation and exposes a zero-copy
  payload borrow.
- A payload borrow must end before releasing or mutating its owner.

The engine contains no `unsafe` persistence code. Raw file handles, UTF-8
validation, and byte-slice construction stay behind the Reimer standard
library's checked wrappers.
