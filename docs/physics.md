# Static collision broad phase

`StaticCollisionWorld` indexes level geometry in a bounded uniform grid. It is
intended for terrain obstacles, buildings, props, and other shapes that change
infrequently. Dynamic character bodies remain compact ECS components and query
this world with their swept bounds.

The implementation does not allocate a hash table or one list per cell. A
rebuild first counts references, computes contiguous cell ranges, then writes
all generational shape handles into one flat array. Queries use a caller-owned
`CollisionQuery` and a generation table to deduplicate shapes crossing multiple
cells without clearing a set every time.

```reimer
from arepita_engine::physics import ALL_LAYERS, Aabb, CollisionQuery, StaticCollider, StaticCollisionWorld;

let world_bounds = Aabb::new(0.0, 0.0, 8_192.0, 8_192.0)?;
let mut collision = StaticCollisionWorld::with_capacity(
    &allocator,
    world_bounds,
    64.0,
    50_000,
    200_000,
)?;
defer collision.release();

let wall = Aabb::new(128.0, 96.0, 64.0, 32.0)?;
let wall_handle = collision.add(StaticCollider::new(wall, 0x01))?;
collision.rebuild()?;

let mut query = CollisionQuery::with_capacity(&allocator, 50_000, 256)?;
defer query.release();
let body = Aabb::new(player_x, player_y, 12.0, 8.0)?;
let matches = collision.query(body.swept(delta_x, delta_y), ALL_LAYERS, &mut query)?;
```

Adding, removing, enabling, or changing a shape marks the index dirty. Call
`rebuild` at an explicit structural barrier; queries return `IndexDirty` until
the rebuild succeeds. If the prepared flat-entry budget is insufficient, the
old index is not exposed as current and `GridEntryCapacityExceeded` is
returned. Shape slots are generational, so reuse never makes an old handle
refer to another collider.

`Aabb::overlaps` uses strict area overlap: touching edges are not a collision.
Use `Aabb::swept` for broad-phase movement queries, then resolve each axis or
perform a narrow-phase test in game logic.

Choose cell size from representative measurements. A useful starting point is
roughly two to four times the median static collider extent. Smaller cells
reduce candidates but increase duplicated cell entries; larger cells reduce
index memory but approach a linear scan in dense areas. Run:

```powershell
.\tools\dev.ps1 collision-bench
```

The benchmark validates grid results against an exact linear scan before its
timings are considered meaningful.
