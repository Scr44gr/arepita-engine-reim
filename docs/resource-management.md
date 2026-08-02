# Resource management

Arepita Engine separates three kinds of state:

- Components are compact `Copy` data in sparse sets.
- Resources are explicit typed fields in application state.
- Assets are owned, potentially non-`Copy` values behind generational handles.

This split keeps ownership visible and avoids global registries keyed by class
names or strings.

`AssetStore<T>` invalidates stale handles with a generation counter and calls
`Asset::release` exactly once for every live value. `Application<State>` calls
`ApplicationState::release` during shutdown, including initialization failure
paths. GPU resources are grouped by `Renderer`, which releases child buffers
and pipelines before the device and surface.

Use `allocated_bytes()` on entity/component stores and
`allocated_gpu_bytes()` on the renderer to build a stable, explicit memory
budget. These counters report reserved payload storage, not allocator metadata
or opaque driver allocations.

`SpriteBatch::allocated_bytes()` includes optional transparent-sort scratch and
radix tables after `prepare_sorting`. `WorkerPool` owns native threads and must
be released only after submitted work has joined; `for_each_mut` performs that
join before returning, so the borrowed component store cannot outlive worker
access. `DataParallelSchedule` treats every system return as a join barrier and
does not own the pool, making the shutdown order explicit: release schedules,
then the worker pool, then application-owned storage.

Arena-backed owners invalidate every child `Vec` before releasing the arena.
Their lengths and tracked byte counts therefore become zero after cleanup;
they never retain a readable slice into freed arena memory. Repeated cleanup is
a no-op. Mutating operations on a released owner return an error or `false`,
while lookups expose no stale values.

Treat `release`/`deinit` as the final lifecycle barrier even though these guards
make accidental reuse safe. Borrowed slices from component stores, navigation,
collision queries, packs, or save documents must end before cleanup; Reimer's
borrow checker enforces that ordering.
