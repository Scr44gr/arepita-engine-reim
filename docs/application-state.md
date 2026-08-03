# Application states and typed events

## World resources

Register shared application state on the world instead of maintaining a
parallel service locator. `add_resource` changes only the world's compile-time
type; it does not allocate or hash a type name. `resource<T>` and
`resource_mut<T>` return `None` only after the world has been released.

Every registered type implements `ManagedResource`. Plain `Copy` values use a
no-op cleanup implementation, while owners delegate to an idempotent `release`
method. This makes shutdown explicit and keeps native handles and heap owners
out of components.

## Deferred state transitions

`StateMachine<S>` stores a user-defined `Copy + Eq` enum. A request does not
change the state immediately; `apply` commits it at an explicit schedule
barrier and returns the previous/current pair.

```reimer
from arepita_engine::app import StateMachine;

@derive(Copy, Clone, Debug, Eq)
enum GameState {
    Splash,
    Loading,
    Menu,
    World,
    Paused,
}

let mut state = StateMachine::new(GameState::Splash);
let _ = state.request(GameState::Loading);

// All systems before this barrier still observe Splash.
match state.apply() {
    Some(transition) => {
        leave(transition.previous);
        enter(transition.current);
    },
    None => {},
}
```

The latest request wins when several systems request a state before the same
barrier. Requesting the active state is a no-op and does not increment the
revision. This makes transitions deterministic without a global scene manager
or callbacks that mutate the schedule halfway through a stage.

## Double-buffered events

`Events<T>` is a fixed-capacity typed channel for `Copy + Send + Sync` values.
Emitters append to the pending buffer. `publish` swaps buffer roles, exposing
the complete batch while retiring the previously published batch.

```reimer
from arepita_engine::app import Events;

@derive(Copy)
struct DamageEvent {
    target: Entity,
    amount: f32,
}

let mut damage = Events::with_capacity(&allocator, 1_024)?;
defer damage.release();

damage.emit(event)?;
damage.publish();
{
    let batch = damage.published();
    consume_damage(batch);
}
```

Publishing performs no event copies and no allocation. The published slice is
borrowed from the channel and remains valid until the next mutable operation.
Overflow returns `EventError::CapacityExceeded`; silently dropping combat,
audio, or persistence events is never the default.

Use one channel per event type in the concrete application state. This keeps
dependencies visible in ordinary system signatures and avoids string-keyed or
type-erased global buses.
