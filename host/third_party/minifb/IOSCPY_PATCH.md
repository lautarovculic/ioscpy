# ioscpy minifb patch

This directory contains `minifb` 0.27.0 under its upstream MIT/Apache-2.0
licenses. ioscpy carries a local copy because the macOS Metal backend in 0.27.0
uses nearest-neighbor texture sampling. Once ioscpy moved final window scaling to
that backend, nearest sampling made the mirrored phone screen visibly blocky.

The ioscpy-specific change is intentionally limited to
`src/native/macosx/MacMiniFB.m`: the Metal sampler uses linear minification and
magnification filters. The rest of the crate remains the upstream 0.27.0 source
so Linux and Windows behavior stays unchanged.
