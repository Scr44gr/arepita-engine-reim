# ECS Ergonomics and Game Architecture Refactor

This document records the accepted direction for Arepita's ECS API and for
games built on it. It is both a design decision and a migration checklist.

## Outcome

Ordinary game code should read like a declaration of intent:

```reimer
fn movement_system(
    frame: &SimulationFrame,
    actors: &mut QueryMut<Transform, Motion>,
) {
    actors.for_each_mut(update_motion);
}

fn gameplay_plugin(world: &mut GameplayWorld) -> Result<(), WorldError> {
    world.add_system_to(SystemPipeline::Input, input_system)?;
    world.add_system(movement_system)?;
    world.add_system_to(SystemPipeline::Physics, collision_system)?;
    Ok(())
}

world.add_plugin(gameplay_plugin)?;
```

The system signature declares data access. A plugin owns registration for one
cohesive feature or application composition. The game never fetches an ECS
registry, manually dispatches engine pipelines, or passes system identifiers
between unrelated modules.

## Research summary

Bevy's strongest ergonomic property is not a particular folder layout. It is
the `SystemParam` model: an ordinary function requests `Query`, `Res`,
`ResMut`, `Commands`, events, or local state through its parameters. The
scheduler uses those declared accesses to validate conflicts and decide which
systems may run in parallel. `Plugin` groups cohesive behavior, while schedules,
sets, and explicit `.before`/`.after` constraints express order only where a
real dependency exists.

The reviewed production-sized projects reinforce a few practical rules:

- Jumpy keeps application composition centralized and installs cohesive game
  domains through small entry points.
- Emergence uses vertical domain modules such as terrain, water, units, UI,
  crafting, and construction instead of global component/system buckets.
- Avian splits a large subsystem into focused plugins and named schedule sets;
  ordering is part of the subsystem contract instead of scattered call-site
  knowledge.

Arepita should adopt those properties without copying Rust-specific syntax or
Bevy's dynamic archetype implementation. Reimer's static registries,
allocation-aware resources, and variadic component packs remain deliberate
differences.

## Accepted API rules

### Systems

Systems are ordinary functions. Their parameters are the complete declaration
of ECS access. Application systems must not call `World::query`,
`World::resource_query`, or `World::run_pipeline`.

Use one system for one generic operation across all matching entities. For
example, use one `movement_system` over `Transform` and `Motion`, not separate
player and creature movement systems. Feature-specific policy remains separate:
an input system writes an intent, an AI system writes the same intent, and the
generic movement system consumes the resulting motion state.

Names describe the operation and end in `_system`. Avoid names tied to one
concrete content item such as `slime_movement_system`.

### Components

Shared components describe reusable capabilities or state:

- `Transform`
- `Motion`
- `CollisionBody`
- `ActorPresentation`
- `Health`

Feature-local components are valid when the data expresses feature policy:
`PlayerControl`, `CreatureBehavior`, or `TerrainSurface` should not be made
artificially generic. The rule is locality, not universal genericity: a
feature-specific type stays inside its slice and does not leak into Arepita's
public API.

Large aggregate components are split only when the fields have different
access patterns, lifetimes, or owners. Splitting every field into a component
creates join overhead and makes invariants harder to maintain.

### Commands

Deferred structural changes and cross-feature requests use typed commands.
Commands contain intent, not implementation details. The feature that owns the
operation consumes the command. A global command enum may route independent
feature commands, but it must not become a collection of arbitrary callbacks.

### Plugins

An ordinary plugin function is the public composition boundary. It receives
the application's statically typed world and returns `Result<(), WorldError>`.
`World::add_plugin` keeps the world
mutable in place and returns the first recoverable registration error.

The application composition plugin is allowed to order systems from several
features when gameplay truly depends on that sequence. Feature plugins should
not silently impose ordering on unrelated features.

### Scheduling

The native Arepita runner owns pipeline dispatch. Game code chooses a pipeline
when registering a system but never calls pipelines from its frame loop.

Registration order remains deterministic in the current implementation. Named
system sets and dependency edges are the next scheduling improvement. They
should replace fragile global ordering only after the API can detect missing or
cyclic constraints; integer priorities are not an acceptable public API.

### Errors

Use `?` for propagation and `expect` only at an intentional application
boundary where failure cannot be recovered locally. Avoid `match` blocks that
only translate `Ok(value)` to `value` and immediately return the same error.

## Source layout

Games use vertical feature slices below `src/core`:

```text
assets/
src/
  main.reim
  core/
    package.reim
    app/
    shared/
      components/
      commands/
    entities/
      player/
        components/
        commands/
        systems/
        presentation/
      creatures/
        components/
        commands/
        systems/
        presentation/
    world/
      components/
      commands/
      systems/
      presentation/
    combat/
      commands/
      systems/
    effects/
      components/
      systems/
      presentation/
    infrastructure/
      assets/
      audio/
      persistence/
      rendering/
```

The directories `components`, `commands`, and `systems` are real package
boundaries inside each slice, not suffixes added to unrelated files.
Presentation code may depend on feature state; gameplay state must not depend
on a renderer. Native services and file formats live under `infrastructure`
because they are adapters around the domain.

There is no `utilities` directory. A helper stays beside its only consumer. A
shared abstraction is introduced only when it has a semantic name, stable
invariants, and multiple consumers. Examples include `geometry`, `color`, or
`projection`; `helpers` and `misc` are not module names.

## Arepita implementation plan

1. **Implemented:** add statically typed plugin functions,
   `World::add_plugin`, and allocation-free ordered `World::add_plugins`.
2. **Implemented:** document plugins as the normal feature-composition API.
3. Keep direct `World` queries as an advanced storage/testing API.
4. Preserve typed system-parameter injection and allocation-free query setup.
5. Add compile-time/runtime tests for plugin registration, ordering, errors,
   and world-local system IDs.
6. Design named sets and dependency edges separately; do not hide registration
   order behind an incomplete abstraction.
7. Replace the internal hand-written system-parameter implementation matrix
   when Reimer can derive a variadic parameter pack over heterogeneous function
   arguments. This internal cleanup must not weaken static access validation.

## Slot Island migration gates

- The native runner still owns input snapshots, timing, fixed updates,
  rendering, audio application, and debug UI boundaries.
- One application plugin owns the existing gameplay order during migration.
- Movement and collision remain generic shared systems.
- Player input and creature AI produce state consumed by shared mechanics.
- Creature code never depends on a concrete species name.
- Rendering reads domain snapshots but domain systems never call renderer APIs.
- Each moved package has a narrow facade; callers do not import deep private
  implementation files.
- The asset pack, save format, stress mode, and deterministic tests retain their
  behavior.

The initial migration is complete: Slot Island uses `src/core` feature slices,
installs its gameplay composition through `World::add_plugin`, keeps one shared
movement system and one shared collision system, and passes the original
deterministic suite after the move.

## Validation

Every refactor must pass formatting, type checking, unit tests, the release
build, and the existing performance gates. Architectural cleanup is not allowed
to add per-frame allocation, virtual dispatch, string-based component lookup,
or unsafe access to game code.

## References

- [Bevy ECS agent skill](https://www.skills.sh/gamedev-skills/awesome-gamedev-agent-skills/bevy-ecs)
- [Bevy `System`](https://docs.rs/bevy/latest/bevy/prelude/trait.System.html)
- [Bevy `Query`](https://docs.rs/bevy/latest/bevy/prelude/struct.Query.html)
- [Bevy `App`](https://docs.rs/bevy/latest/bevy/prelude/struct.App.html)
- [Jumpy](https://github.com/fishfolk/jumpy)
- [Emergence](https://github.com/Leafwing-Studios/Emergence)
- [Avian](https://github.com/avianphysics/avian)
