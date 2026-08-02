# Audio clips and mixing

The current audio layer uses SDL3 AudioStreams behind a safe, main-thread
owner. Application code works with decoded interleaved `f32` samples and never
touches native handles.

## Clips

`AudioClip` validates its sample rate, channel count, interleaved frame shape,
and every sample's finiteness before copying into allocator-owned storage.
Rejecting NaN and infinity at the boundary keeps invalid values out of the
mixer. Clips are non-`Copy` assets and belong in an `AssetStore<AudioClip>`.

```reimer
let clip = AudioClip::from_samples(
    &allocator,
    48_000,
    2,
    decoded_samples,
)?;
let handle = clips.insert(clip)?;
```

Insertion transfers ownership at the call boundary. If insertion fails, the
store releases the clip before returning the error.

## Fixed-capacity mixer

`AudioMixer` reserves its voice list and mixing block during creation. Mixing,
voice compaction, and SDL queue submission do not allocate:

```reimer
let mut mixer = AudioMixer::create(
    &allocator,
    48_000,
    2,
    1_024,
    32,
)?;
defer mixer.release();

mixer.play(&clips, handle, 0.8, false)?;
mixer.maintain(&clips, 4_800)?;
```

Long-lived sounds can retain a `VoiceHandle` and stop or restart only that
voice. The mixer finds tracked voices in its prepared bounded array, so voice
control does not allocate and never invalidates unrelated sounds:

```reimer
let voice = mixer.play_tracked(&clips, handle, 0.58, true)?;
assert(mixer.is_playing(voice));
let _ = mixer.stop(voice)?;
```

`play_with_settings` adds bounded playback-rate control for deterministic pitch
variation. The mixer advances a fractional `f64` source cursor and linearly
interpolates adjacent frames, including a seamless last-to-first interpolation
for loops:

```reimer
let settings = VoiceSettings::new(0.72, 1.08, false);
let voice = mixer.play_with_settings(&clips, handle, settings)?;
```

Playback rates outside `0.01` through `8.0`, negative volume, and non-finite
values are rejected before a voice slot is consumed.

A handle becomes inert as soon as its sound finishes or is stopped. Mixer
release invalidates every outstanding handle and remains idempotent.

All active clips must match the mixer's sample rate and channel count. Volume
must be finite and non-negative. The offline asset cooker performs decoding,
resampling, channel mapping, and a second finite-sample check; keeping those
operations outside the frame loop avoids decoder state and unbounded temporary
allocations in the game runtime.

`maintain` fills only up to the requested queued-frame target and rejects
targets above eight prepared blocks. This cap prevents a mistaken value from
queuing unbounded native audio memory. The process can sleep normally between
frames; SDL's audio device consumes the queue without a busy loop. See
`examples/audio-tone` for a complete generated-tone example.

Primary SDL references:

- [SDL3 audio overview](https://wiki.libsdl.org/SDL3/CategoryAudio)
- [Queueing AudioStream data](https://wiki.libsdl.org/SDL3/SDL_PutAudioStreamData)
