# Arepita Engine

Arepita Engine is a data-oriented game engine for the Reimer programming
language. Its public style is inspired by Arepy: components are ordinary
structs, systems are ordinary functions, and resources are explicit. Its
internals are designed for Reimer instead of reproducing Python's runtime
trade-offs.

The project is under active development. The current usable slice provides:

- generational entity identifiers that reject stale handles;
- packed sparse-set component storage with stable O(1) lookup;
- library-defined `@derive(Component)` validation;
- variadic, statically typed heterogeneous component registries;
- allocation-free queries with compiler-checked disjoint store access;
- `World::add_system` query injection with static dispatch and no registry
  plumbing in gameplay systems;
- explicit typed resources without string lookup;
- direct mutable component slices for allocation-free iteration and parallel
  chunk processing;
- allocation-free two-component joins for ordinary function systems;
- deferred component commands with all-or-nothing capacity preparation;
- typed generational asset stores for non-`Copy` resources;
- a deterministic application lifecycle with ordinary function schedules;
- drift-free fixed simulation with bounded catch-up, reusable worker pools,
  and barrier-joined data-parallel system schedules;
- a flat, allocation-free static collision grid with generational shape handles;
- deterministic weighted A* with indexed-heap scratch and no per-search allocation;
- deferred typed states and fixed-capacity double-buffered event channels;
- bounded versioned saves with allocation-free codecs, independent header and
  payload checksums, and synchronized atomic publication;
- allocation-free keyboard, mouse, and multi-gamepad snapshots with retained
  sub-frame transitions, generational handles, radial dead zones, hot-plug
  handling, and rumble;
- owned audio clips and a fixed-capacity, allocation-free SDL3 mixer;
- deterministic offline sprite/audio cooking with decode-once spritesheet
  regions and bounded zero-copy pack loading;
- allocation-free physical-pixel images, solid rectangles, cooked-font text,
  and immediate buttons;
- an SDL3 + wgpu renderer with a persistent sprite pipeline, one packed upload,
  one instanced draw call, and explicit GPU-memory reporting.

## Component example

```reimer
from arepita_engine::ecs import Component, Entity, Query, world;
from std::alloc import general_allocator;

@derive(Copy, Component)
struct Position {
    x: f32,
    y: f32,
}

@derive(Copy, Component)
struct Velocity {
    x: f32,
    y: f32,
}

fn movement(entity: Entity, position: &mut Position, reads: (Velocity)) {
    let _ = entity;
    let velocity = reads.0;
    position.x += velocity.x;
    position.y += velocity.y;
}

fn movement_system(query: &mut Query<Position, Velocity>) {
    let _ = query.for_each(movement);
}
```

Create a world, attach data, and register the ordinary function system:

```reimer
let allocator = general_allocator();
let mut world = world<Position, Velocity>(&allocator)?;
let entity = world.spawn()?;
let position = Position { x: 0.0, y: 0.0 };
let velocity = Velocity { x: 1.0, y: 0.0 };
let _ = world.insert<Position>(entity, position)?;
let _ = world.insert<Velocity>(entity, velocity)?;

let mut world = world.add_system(movement_system);
defer world.deinit();
world.run_systems();
```

The system signature declares its component access. `World` constructs the
matching `Query` immediately before the call, and the registry remains an
internal storage detail. Additional systems use the same fluent API:

```reimer
let mut world = world
    .add_system(movement_system)
    .add_system(collision_system);
```

Direct `Registry` and `World::query` access remain available for advanced
custom runners and isolated storage code. Normal gameplay does not need to
touch the registry.

The renderer follows the same ownership model. `WindowHost` owns SDL, while a
single `Renderer` owns the surface, device, queue, pipeline, and buffers in a
safe release order. See [`examples/sprites`](examples/sprites) for a complete
native program.

## Development

Use a Reimer compiler built from the sibling language repository while the
marker-derive feature is landing:

```text
reimer check .
reimer test .
reimer fmt . --check
```

Architecture and performance decisions live in
[`docs/architecture/overview.md`](docs/architecture/overview.md).

Start with [`docs/getting-started.md`](docs/getting-started.md), then read the
[ECS guide](docs/ecs/components-and-queries.md) and
[sprite rendering guide](docs/rendering/sprites.md). Native applications should
also read the [input guide](docs/platform-input.md) and
[audio guide](docs/audio.md). Source assets and the runtime pack format are
covered by the [cooked-assets guide](docs/assets.md).
The [UI guide](docs/ui.md) covers text, images, buttons, and frame-capacity
planning.
The [simulation guide](docs/simulation.md) covers fixed updates, overload
handling, and data-parallel component systems.
The [collision guide](docs/physics.md) covers static-world indexing, swept
queries, memory budgets, and measurement.
The [navigation guide](docs/navigation.md) covers weighted tile costs,
deterministic A*, scratch ownership, and concurrent pathfinding.
The [application-state guide](docs/application-state.md) covers scene barriers
and typed event batches.
The [persistence guide](docs/persistence.md) covers schema migration, bounded
decoding, checksums, atomic publication, and crash-consistency limits.
Reproducible scenarios and current reference results live in
[performance gates](docs/benchmarks.md).

## License

MIT.
