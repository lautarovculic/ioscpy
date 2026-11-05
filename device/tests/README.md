# Capture probe (optional, physical iPhone)

Build on a Theos host with an iPhone SDK:

```sh
make -C device/tests THEOS_PACKAGE_SCHEME=rootless FINALPACKAGE=1
```

Copy `device/tests/.theos/obj/capture-probe` to a temporary directory on a
jailbroken test device and run it there. It is a separate executable: no tweak
installation, SpringBoard injection/restart, daemon connection, or UI input.
The test-only entitlements permit IOSurface allocation and display capture.
Do not apply these entitlements to the production daemon.

Arguments: `maxDimension frames fps fault [PNG] [encode] [H264]`.

```sh
./capture-probe 1600 900 30 none
for fault in symbol constant render lock unlock; do
    ./capture-probe 1600 3 30 "$fault"
done
./capture-probe 1600 120 30 none /tmp/frame.png encode /tmp/stream.h264
```

The harness includes the real `Capture.mm`; only its private-symbol resolver
and IOSurface synchronization calls are wrapped for counting/fault injection.
The encoder smoke test links the unchanged production `Encoder.mm`.

With Snapshot available, three frames should produce:

| Fault | Snapshot calls | Legacy calls | Failed frames |
|---|---:|---:|---:|
| none | 3 | 0 | 0 |
| symbol / constant missing | 0 | 3 | 0 |
| render returns false | 3 | 3 | 0 |
| one lock / unlock failure | 3 | 1 | 0 |

The unlock fault performs the actual unlock before returning an injected error.
It does not leave an IOSurface locked. Each process gets a fresh resolver cache.
Run the normal case first: on an OS without Snapshot the baseline path is
expected, and the Snapshot-specific counters above do not apply.

To compare against an older revision, build this same harness with that
revision's `device/tweak/Capture.mm` and `Capture.h`. Use the same device,
screen content, size, FPS and warm-up, and counterbalance run order (BAAB).
Each run excludes ten warm-up frames. JSON contains capture elapsed time and
process CPU time. It does **not** measure render-server CPU, whole-device CPU,
power, temperature or network latency. With `encode`, CPU also includes the
encoder; `mean_ms` still measures capture only.

PNG/H.264 files contain screen content. Keep them private unless the screen is
a deliberately public test scene. The harness writes no images by default.

## Observed validation, 2026-11-05

Baseline: `1b7695d17632316ce5d5c22f346a19f2b686e427`.
iPhone X (`iPhone10,6`), iOS 16.7.12, native 1125×2436, nativeScale 3.
Static Home screen; separate process over USB SSH; installed streamer untouched.

| BAAB run | Frames | Mean capture (ms) | p95 (ms) | Process CPU (ms) |
|---|---:|---:|---:|---:|
| Snapshot B1 | 900 | 13.337 | 15.013 | 342.482 |
| Upstream A1 | 900 | 21.960 | 22.453 | 11315.560 |
| Upstream A2 | 900 | 22.180 | 22.793 | 11327.367 |
| Snapshot B2 | 900 | 13.342 | 14.534 | 344.529 |

All runs: cap 1600, output 738×1600, target 30 FPS, about 30 seconds,
zero failed captures. Average capture elapsed time decreased about 39.6% in
this workload. The process CPU reduction excludes work moved to the render
server and must not be presented as whole-device CPU or battery savings.

All five fault cases passed the counters above. Native cap, 720 and 1600
produced 1124×2436, 332×720 and 738×1600; baseline/candidate images were
inspected for scale, orientation and full-screen coverage. The unchanged
VideoToolbox encoder produced 120/120 nonempty frames, one keyframe and
163404 AVCC bytes from Snapshot surfaces at 30 FPS. After conversion to Annex B,
FFmpeg decoded all 120 H.264 frames at 738×1600 without errors.

Theos compilation passed for arm64 and arm64e. The local older toolchain emits
arm64e ABI warnings; only arm64 was executed. Other devices/OS versions,
landscape UI, moving video and a full desktop streaming session remain untested.
