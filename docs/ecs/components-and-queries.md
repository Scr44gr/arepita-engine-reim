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

## Storage

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

## Two-component joins

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

The query does not allocate. Choose the smaller mutable store as the driver
when either orientation is valid. The read component is copied because all
components are intentionally compact `Copy` data.

## Structural changes

Do not insert or remove components while iterating their packed arrays. Queue
changes in `ComponentCommands<T>` and apply them at an explicit barrier. The
command queue reserves all required dense and sparse capacity before the first
mutation, applies removals before inserts, and retains its allocation for the
next frame.
