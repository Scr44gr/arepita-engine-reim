# BunnyMark

This benchmark mirrors Arepy's BunnyMark workload:

- 50,000 bunny entities
- a 640 x 480 window
- four floating-point motion values per entity
- boundary reflection at the same 16-pixel margins
- one atlas texture, one packed instance upload, and one draw call per frame

It reports packed sequential and worker-pool simulation throughput before
opening the measured render loop. This benchmark explicitly requests immediate
presentation so its visible throughput is comparable to Arepy's uncapped
Raylib example. Normal engine applications still default to tear-free FIFO.
Creation fails clearly when immediate presentation is unavailable instead of
silently changing the workload.

Motion uses a deterministic fixed step so repeated runs execute the same
arithmetic and boundary transitions. The hot component intentionally fuses
position and velocity into one packed 16-byte record; this is the native data
layout used to test the optimization opportunity that is unavailable to the
Python/NumPy version without changing its public component model.

Run the benchmark from the engine repository root:

```powershell
reimer run .\benches\bunnymark --release
```

The project receives SDL3, wgpu-native, and the media codecs through transitive
manifest dependencies. Reimer resolves those native files without manual
`PATH` or `LIB` configuration. Other platforms require matching native target
entries and artifacts in the vendor manifests.

Press Escape or close the window to stop early. A normal run performs 60
warm-up frames followed by 600 measured frames.

The bunny image is copied from Arepy's MIT-licensed BunnyMark example:
<https://github.com/Scr44gr/arepy/blob/main/examples/assets/bunny.png>.
