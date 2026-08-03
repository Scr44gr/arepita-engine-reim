# Architecture overview

Arepita Engine keeps Arepy's approachable surface while replacing the parts
that exist mainly because Python is dynamic. The design is deliberately split
into independent layers so the ECS can be benchmarked without SDL3 or wgpu.

## Design rules

1. Components are small `Copy + Send + Sync` structs. Heap-owning state belongs
   in resources or assets, while components store compact generational handles.
2. Entity handles include an index and generation. Reusing an index invalidates
   every old handle instead of silently targeting another entity.
3. A component store is a packed sparse set. Sparse indices provide O(1)
   lookup; dense arrays provide cache-friendly iteration and parallel chunks.
4. Structural mutations occur outside active iteration. The command buffer
   will apply them at explicit schedule barriers.
5. Components live in a monomorphized heterogeneous `Registry`; resources
   remain typed fields in application state. Both avoid Arepy's class-name
   lookup and let ordinary function signatures document access.
6. Frame-stable paths allocate nothing. Growth is explicit during loading or
   command application, and capacity can be prepared before gameplay.
7. Rendering uses persistent GPU resources and packed instance batches. One
   sprite must never imply one upload or one queue submission.
8. Unsafe code is confined to standard containers and native ABI adapters.
   Engine-facing APIs remain bounds-checked and ownership-safe.
9. Persisted state uses bounded versioned envelopes. Application schemas remain
   explicit, corruption is detected before decoding, and publication happens
   only after the complete temporary file is synchronized.

## Why a static resource set

Arepy resolves injected resources through Python annotations and class-name
strings every time a system is prepared. Reimer monomorphizes variadic type
packs and can split unique tuple fields by concrete type, so component registry
lookups become constant field addresses. Application resources remain ordinary
typed state fields. Misspellings, absent components, duplicate store types, and
conflicting query access are compile-time errors.

A dynamic resource map may be added for editor plugins, but it is not the
default gameplay path.

## Scheduling model

`Schedule` runs ordinary functions deterministically in insertion order.
`DataParallelSchedule` gives each ordinary system a shared `WorkerPool`; a
system splits its packed component storage into disjoint mutable slices and
joins every job before returning. Each system boundary is therefore an
explicit barrier. Deferred structural commands are applied only at these
barriers, never while a worker holds a component slice.

Arepita does not manufacture aliased references or rely on runtime type-name
lookup. `Registry::query` uses the compiler's checked heterogeneous tuple split
to create one exclusive store borrow and disjoint shared store borrows.
Independent systems currently remain ordered, while homogeneous work inside a
system runs in parallel. This preserves the same core conflict rule used by
Bevy's multithreaded executor: concurrent work may never have conflicting data
access. A future access-graph scheduler can build on the query signatures
without changing that rule.

## Renderer direction

The renderer is a wgpu backend, not a general-purpose raw WebGPU wrapper.
Public handles are generational and backend-neutral. Internally it will use:

- an instance buffer per batch family;
- texture arrays or atlases selected by material keys;
- a measured staging strategy when multiple upload families justify it;
- explicit surface-loss and resize recovery;
- render passes described without exposing native pointers;
- feature negotiation per platform, with WebGL-compatible limits available
  for future WASM builds.

The current sprite path performs one contiguous `Queue::write_buffer` and one
instanced draw for the complete batch. This is deliberately different from
issuing one upload per sprite. wgpu documents that `write_buffer` uses staging
memory and makes the transfer visible at the next submission, so the engine
tracks uploaded bytes in `RenderReport`. A reusable belt or ring will be added
only when measurements show multiple independent upload families make the
single-write path insufficient. See the upstream
[`Queue::write_buffer` documentation](https://docs.rs/wgpu/latest/wgpu/struct.Queue.html#method.write_buffer)
and [`StagingBelt` documentation](https://docs.rs/wgpu/latest/wgpu/util/struct.StagingBelt.html).

## Measurement gates

Every optimization must be measured against a checked-in scenario. The first
ECS suite covers entity creation, insert/replace, lookup, packed iteration,
removal, stale handles, and index recycling. Renderer gates will track draw
calls, uploaded bytes, CPU frame time, GPU frame time, and peak resident memory.
