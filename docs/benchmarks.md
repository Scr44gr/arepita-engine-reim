# Performance gates

Benchmarks are correctness-checked release programs, not unit-test timings.
They print a checksum and return a non-zero code when comparable paths disagree.
Run them on an otherwise idle machine and retain several samples; laptop power
management and background compilation can produce large outliers.

## Static collision grid

```powershell
.\tools\dev.ps1 collision-bench
```

The scenario creates 50,000 static 20×20 colliders in an 8,192×8,192 world,
uses 64-unit cells, rebuilds the complete index, and performs 96×96 overlap
queries. It validates a 2,000-query window against an exact 100-million-pair
linear scan, then also measures a 200,000-query throughput run.

Five-sample reference measurements from 2026-08-01 on Windows 11 Pro, an Intel
Core 5 120U (10 cores, 12 logical processors), and a release build:

| Measurement | Observed range | Median |
|---|---:|---:|
| Complete 50,000-shape rebuild | 6.59–8.88 ms | 7.78 ms |
| 200,000 prepared grid queries | 197.51–297.09 ms | 241.39 ms |
| 2,000 prepared grid queries | 1.99–3.25 ms | 2.34 ms |
| 2,000 exact linear queries | 325.51–495.59 ms | 348.82 ms |

The equal checksum was 20,834 matches for both 2,000-query paths. On the median
sample the grid comparison window was about 149× faster than the exact linear
scan. The broad range is recorded rather than hidden; future regressions should
be investigated with a dedicated benchmark runner and fixed power profile.

The program reports collision-index, reusable-query, and baseline-array memory
separately. The Python-style linear baseline copy is not part of the engine's
runtime budget.

The reference capacities reserve 4,174,288 bytes for the collision world and
202,048 bytes for reusable query scratch. The extra 800,000-byte bounds array
exists only to run the exact linear baseline.

## ECS

```powershell
.\tools\dev.ps1 bench
```

The ECS scenario covers 200,000 entity/component insertions and 120 packed
updates in sequential and four-worker modes. Both paths operate on the same
dense component storage and report tracked payload allocation. Parallel speedup
depends on worker count, minimum chunk, and current CPU load; a parallel result
is not accepted without matching component outcomes in the benchmark or tests.

Five-sample measurements from the same system and release profile:

| Measurement | Observed range | Median |
|---|---:|---:|
| Create and insert 200,000 entities | 17.70–24.32 ms | 18.80 ms |
| 120 packed sequential updates | 156.49–199.97 ms | 180.49 ms |
| 120 packed four-worker updates | 59.49–88.37 ms | 67.46 ms |

The median parallel path was 2.68× faster than the sequential path. Both paths
reported the same 9,699,328 tracked bytes throughout every measured update.

## Navigation

```powershell
.\tools\dev.ps1 navigation-bench
```

The navigation scenario builds a 128×128 weighted grid with staggered walls
and narrow deterministic gaps, warms the finder, then performs 2,000 varied A*
searches. It combines path length, visited cells, and path cost into a checksum
and verifies that reusable scratch allocation is unchanged after every search.

Reference measurements from 2026-08-01 on the same Core 5 120U system:

| Measurement | Observed range | Median |
|---|---:|---:|
| 2,000 prepared A* searches | 1.447–1.935 s | 1.675 s |

The stable checksum was 2,183,721. The 128×128 grid reserved 65,536 bytes and
the indexed heap, generations, scores, parents, and output path reserved
655,360 bytes in total, unchanged after the measured searches.

These are the measurements repeated after the ownership hardening pass, the
persistence subsystem, and the standard-library synchronization helpers.
Collision checksums, navigation checksums, ECS outcomes, and all tracked-memory
totals remained identical. Relative to the immediately preceding five-sample
series, collision rebuild and throughput medians improved, navigation improved
slightly, ECS creation improved slightly, and the packed update medians moved
within the run-to-run variance already visible on this laptop. The timed packed
update loop did not acquire a release-state branch. No result justified adding
complexity to a hot path.

The five-sample verification on 2026-08-02, after tracked audio voices,
fractional pitch interpolation, and spatial gameplay audio were added, produced
these medians on the same machine:

| Measurement | Median |
|---|---:|
| ECS create and insert | 20.825 ms |
| ECS sequential updates | 137.608 ms |
| ECS four-worker updates | 54.646 ms |
| Collision rebuild | 7.380 ms |
| 200,000 grid queries | 193.984 ms |
| 2,000 grid queries | 2.449 ms |
| 2,000 exact linear queries | 360.321 ms |
| 2,000 prepared A* searches | 1.732 s |

Every checksum and tracked allocation remained exact: ECS `9,699,328` bytes,
collision world `4,174,288` bytes, collision scratch `202,048` bytes,
navigation grid `65,536` bytes, and navigation scratch `655,360` bytes. The
grid and update medians improved while the remaining movements stayed inside
the previously recorded laptop variance, so the audio work did not justify any
change to unrelated hot paths.

## BunnyMark

```powershell
.\tools\dev.ps1 bunnymark
```

The renderer scenario follows Arepy's uncapped BunnyMark at 50,000 entities,
640 x 480 physical pixels, a 32 x 32 bunny atlas region, and one complete batch
submission per frame. It performs 60 warm-up frames and 600 measured frames.
The source workload is pinned to Arepy commit
[`777d33c`](https://github.com/Scr44gr/arepy/blob/777d33cf78b34b95c6bf8fa2fab5b651f3cae8b8/examples/bunnymark.py).

Both measurements request uncapped presentation: Arepy uses Raylib with a
target rate of zero, while Arepita requests `PresentationMode::Immediate` and
fails when the platform does not support it. Normal engine applications remain
tear-free FIFO by default.

Five Arepita samples on the reference Core 5 120U system produced 185, 215,
216, 232, and 258 FPS, for a median of 216 FPS and a median frame time of
4.62 ms. Two instrumented runs of the source Arepy workload produced 161 and
170 FPS. The observed Arepita median is about 30% above the midpoint of those
Arepy samples, but the small Arepy sample count and laptop power variability
must remain visible with the result.

The optimized sprite path precomputes the rotation basis once per instance,
uses a four-vertex triangle strip, and discards only texels whose sampled alpha
is exactly zero. It retains the 64-byte instance width, one 3.2 MB upload, and
one draw call per frame. The bundled bunny contains 536 fully transparent and
488 fully opaque texels, so the exact-zero discard preserves every visible
texel while avoiding blend work for 52.3% of its source area.

Across the same five Arepita samples, the median pure parallel movement rate
was 394.7 million entity updates per second. Tracked memory remained exactly
5,628,928 CPU bytes and 3,204,096 GPU bytes in every sample, and the final
position checksum remained 27,187,338.
