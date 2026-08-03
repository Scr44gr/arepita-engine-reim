# Components and queries

## Components

A component is compact, copyable gameplay data:

```reimer
from arepita_engine::ecs import Component;

@derive(Copy, Component)
struct Position {
    x: f32,
    y: f32,
}
```

`@derive(Component)` is checked by the compiler. The struct must satisfy the
engine marker's `Copy + Send + Sync` supertraits. Heap allocations, files,
textures, and other owners belong in typed resources or asset stores;
components should hold small values or generational handles.

## World storage

`World<...>` owns entity allocation and one packed store for every listed
component type. Reimer expands the component pack at compile time, validates
that store types are unique, and lowers access to constant tuple fields. There
is no runtime type-name hash, erased pointer, or query allocation.

```reimer
from arepita_engine::ecs import world;
from std::alloc import general_allocator;

let allocator = general_allocator();
let mut world = world<Position, Velocity>(&allocator)?;
defer world.deinit();

let entity = world.spawn()?;
let position = Position { x: 0.0, y: 0.0 };
let velocity = Velocity { x: 1.0, y: 0.0 };
let _ = world.insert<Position>(entity, position)?;
let _ = world.insert<Velocity>(entity, velocity)?;
```

Internally, all stores share one arena and begin without reserved component
storage. The first insertion or an explicit reservation grows only the
affected packed arrays. `World::deinit` releases entities and the complete
heterogeneous component set exactly once.

## Packed storage

`ComponentStore<T>` combines a sparse entity index with dense entity and value
arrays. Lookup, replacement, and removal are O(1). Dense iteration is
contiguous, and removal uses swap-remove, so code must not rely on insertion
order.

Use `values_mut()` for the hottest single-component loop. It also feeds
`std::job::parallel_for_mut` directly without building an intermediate query.

For reusable frame schedules, register ordinary functions in
`DataParallelSchedule<State>`. Every function receives `&mut State` and a
shared `&WorkerPool`, and must return only after its slice jobs have joined.
The next system therefore observes all writes from the previous system without
locks or per-entity task allocation.

`ComponentStore<T>` remains available as an advanced standalone building
block. Use `values_mut()` for the hottest single-component loop or to feed
`std::job::parallel_for_mut` directly.

## Systems and typed queries

Systems are ordinary functions that receive a typed `Query`. Register them on
the world; the engine injects the query immediately before each call. Gameplay
code never needs to pass the registry manually.

```reimer
fn integrate(
    entity: Entity,
    position: &mut Position,
    reads: (Velocity),
) {
    let _ = entity;
    let velocity = reads.0;
    position.x += velocity.x;
    position.y += velocity.y;
}

fn movement_system(query: &mut Query<Position, Velocity>) {
    let _ = query.for_each(integrate);
}

let mut world = world.add_system(movement_system);
world.run_systems();
```

The first query type is writable and drives dense iteration. Every remaining
type is read-only and is probed by generational entity handle, so joins stay
correct when membership or dense order differs. Read values arrive in a tuple
matching their signature order. Components are compact `Copy` data, while the
writable value is borrowed in place.

System registration creates a static type chain and allocates nothing. Query
construction and iteration also allocate nothing. The generated loop is
specialized for its complete component list, and every store access becomes a
constant field address. `World::query` and `Registry` remain available for
advanced custom runners.

## Direct two-component joins

`for_each2_mut` uses the mutable store as the driving dense set and probes the
read store by generational entity handle:

```reimer
fn integrate(entity: Entity, position: &mut Position, velocity: Velocity) {
    let _ = entity;
    position.x += velocity.x;
    position.y += velocity.y;
}

let matched = for_each2_mut(&mut positions, &velocities, integrate);
```

This lower-level helper remains useful when a subsystem intentionally owns
standalone stores. New gameplay code should prefer `World::add_system` so the
function signature remains the single declaration of component access.

## Structural changes

Do not insert or remove components while iterating their packed arrays. Queue
changes in `ComponentCommands<T>` and apply them at an explicit barrier. The
command queue reserves all required dense and sparse capacity before the first
mutation, applies removals before inserts, and retains its allocation for the
next frame.
