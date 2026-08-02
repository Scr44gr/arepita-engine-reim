# Fixed simulation and parallel systems

Games should sample wall time once per rendered frame, but run gameplay at a
fixed step. `FrameClock` measures a bounded monotonic frame delta and
`FixedClock` turns that delta into an integer update budget without accumulating
floating-point drift.

```reimer
from arepita_engine::app import FixedClock, FrameClock;
from std::time import Duration;

let mut frame_clock = FrameClock::start(Duration::from_milliseconds(250));
let mut fixed_clock = match FixedClock::new(
    Duration::from_nanoseconds(16_666_667),
    5,
) {
    Some(value) => value,
    None => panic("invalid fixed simulation settings"),
};

frame_clock.tick();
let fixed = fixed_clock.advance(frame_clock.delta());
let mut step: u32 = 0;
while step < fixed.steps {
    fixed_update(fixed_clock.step_seconds());
    step += 1;
}
render(fixed.interpolation);
```

The maximum step count is a deliberate overload policy. If a frame would
require more work, `FixedFrame::dropped` reports the discarded duration rather
than allowing an ever-growing catch-up spiral. Track this value in development
telemetry: persistent dropped time means the fixed workload or target hardware
budget must change.

## Data parallel component updates

`WorkerPool` owns a fixed set of threads. Create it during loading and release
it after all submitted work has joined. A parallel component system remains an
ordinary function over a disjoint mutable slice:

```reimer
from arepita_engine::ecs import Component, ComponentStore, WorkerPool;
from std::job import chunk_len;

@derive(Copy, Component)
struct Motion {
    x: f32,
    velocity: f32,
}

fn integrate_chunk(values: &mut [Motion]) {
    let mut index: usize = 0;
    let length = chunk_len(values);
    while index < length {
        let mut value = values[index];
        value.x += value.velocity;
        values[index] = value;
        index += 1;
    }
}

let mut workers = WorkerPool::fixed(&allocator, 4)?;
defer workers.release();
workers.for_each_mut(&mut motions, integrate_chunk, 4_096)?;
```

`WorkerPool::automatic(&allocator)` captures the operating system's current
CPU quota once. Prefer it for normal applications; use `fixed` for reproducible
benchmarks or a platform-specific thread budget.

An ordinary function can expose the same work through a reusable schedule:

```reimer
from arepita_engine::ecs import DataParallelSchedule, WorkerPool;
from std::job import JobError;

struct Simulation {
    motions: ComponentStore<Motion>,
}

fn integrate_system(
    simulation: &mut Simulation,
    workers: &WorkerPool,
) -> Result<(), JobError> {
    workers.for_each_mut(
        &mut simulation.motions,
        integrate_chunk,
        4_096,
    )
}

let mut schedule = DataParallelSchedule::new(&allocator)?;
defer schedule.deinit();
schedule.add(integrate_system)?;
schedule.run(&mut simulation, &workers)?;
```

`run` propagates the first worker failure. A successful return is also the
barrier proving that no worker retains a component borrow.

The store is borrowed exclusively until all chunks join. Each worker receives
only its non-overlapping range, so hot component updates need no mutex and no
per-entity task allocation. The minimum chunk is a tuning parameter, not a
magic constant: small or expensive components may need different measured
thresholds. Keep short, order-dependent systems sequential.

Structural ECS changes remain deferred until a schedule barrier. Never spawn,
despawn, or change component membership from inside a packed parallel loop.
