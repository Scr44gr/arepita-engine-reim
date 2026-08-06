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

`World<Resources, Storage>` owns entity allocation, one typed resource registry,
and one packed store for every listed component type. Reimer expands the
component pack at compile time, validates that store types are unique, and
lowers access to constant tuple fields. Queries use no runtime type-name hash,
erased component pointer, or allocation.

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
from arepita_engine::ecs import Entity, Query, SystemPipeline;

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

let movement_id = world.add_system(movement_system)?;
world.run_pipeline(SystemPipeline::Update);
```

The first query type is writable and drives dense iteration. Every remaining
type is read-only and is probed by generational entity handle, so joins stay
correct when membership or dense order differs. Read values arrive in a tuple
matching their signature order. Components are compact `Copy` data, while the
writable value is borrowed in place.

System registration appends one entry to Update by default and returns a
monotonic ID owned by that world. `add_system_to` selects another pipeline. A
`SystemId` is an opaque control handle, not a persistent or cross-world key;
another or recreated world rejects it even when the visible `raw()` values
match. The world's type remains unchanged, so a
single mutable binding can register any number of heterogeneous systems.
Registration may grow pipeline storage; pipeline execution, query construction,
and iteration allocate nothing. Each entry retains an exact monomorphized
runner, and every component-store access becomes a constant field address.
`World::query` and `Registry` remain available for advanced custom runners.

## Feature plugins

An ordinary plugin function owns registration for one cohesive feature or
application composition. It receives the exact world type, mutates that world
in place, and propagates `WorldError` with `?`:

```reimer
fn movement_plugin(world: &mut GameWorld) -> Result<(), WorldError> {
    world.add_system(movement_system)?;
    world.add_system_to(SystemPipeline::Physics, collision_system)?;
    Ok(())
}

world.add_plugin(movement_plugin)?;
```

Use `add_plugins` with a fixed function array when the composition root owns
several feature or pipeline plugins. The array order is the installation order,
and iteration allocates nothing.

The native runner still owns pipeline execution. Game plugins choose pipelines
while registering systems; frame code does not call `run_pipeline` manually.
Keep ordering inside the application composition only when systems have a real
data or gameplay dependency.

Use the ID to control a system without exposing registry internals:

```reimer
let _ = world.set_system_enabled(movement_id, false);
let _ = world.set_system_enabled(movement_id, true);
let _ = world.remove_system(movement_id);
```

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
