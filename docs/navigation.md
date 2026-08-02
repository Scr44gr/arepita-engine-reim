# Weighted grid navigation

`NavigationGrid` stores one row-major traversal cost per tile. Zero means
blocked; every walkable cost is finite and at least one. `PathFinder` owns all
A* scratch and returns the lowest-cost cardinal path without allocating during
a search.

```reimer
from arepita_engine::navigation import GridPoint, NavigationGrid, PathFinder;

let mut navigation = NavigationGrid::filled(&allocator, 256, 256, 1.0)?;
defer navigation.release();

navigation.set_cost(GridPoint::new(18, 30), 1.15);
navigation.set_blocked(GridPoint::new(19, 30), true);

let mut finder = PathFinder::with_capacity(&allocator, navigation.len())?;
defer finder.release();
let report = finder.find_path(
    &navigation,
    GridPoint::new(10, 12),
    GridPoint::new(80, 64),
)?;
{
    let path = finder.path();
    follow(path, report.cost);
}
```

The result slice belongs to the finder and remains valid until its next mutable
search. Copy long-lived waypoints into game-owned storage; short-lived AI can
consume the path immediately and retain only its next waypoint.

## Why an indexed heap

A basic priority queue often pushes another node whenever A* finds a cheaper
route to a tile. That is simple but can make frontier memory much larger than
the map. Arepita Engine keeps a heap-position table and performs `decrease-key`
in place. Each cell therefore appears at most once in the frontier, search
capacity is exactly the grid cell count, and tie-breaking by row-major index is
deterministic.

The finder also keeps generation-tagged seen and closed arrays. Starting a new
search increments one integer instead of clearing every cell. Only generation
wraparound performs a complete reset.

## Costs and updates

Cardinal movement pays the destination tile's cost. Requiring walkable costs
of at least one keeps Manhattan distance admissible, so the returned route is
optimal for these weights. `PathReport` exposes point count, visited-cell count,
and total cost for AI metrics and tuning.

Changing a tile increments `NavigationGrid::revision` only when the value
actually differs. Systems may cache paths against that revision. A failed
search clears the previous result and returns `OutOfBounds`, `BlockedEndpoint`,
`NoPath`, or a capacity/numeric error explicitly.

Use one finder per concurrently executing pathfinding job. Sharing a finder
between workers would serialize access to its scratch; separate prepared
finders keep searches lock-free.
