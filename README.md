<!-- repo-hero -->
<a href="https://noisemaker.app/"><img src="docs/hero.jpg" alt="Noisemaker for CPU (Perl)" width="100%"></a>

<sub>Open source from <a href="https://noisefactor.io">Noise Factor</a> &middot; <a href="https://github.com/noisefactorllc">more projects</a></sub>

# noisemaker-for-perl

Current measured support: [compatibility report](https://github.com/noisefactorllc/noisemaker-for-perl/blob/main/docs/COMPATIBILITY.md).

Current qualification limits: [completion gaps](https://github.com/noisefactorllc/noisemaker-for-perl/blob/main/docs/COMPLETION_GAPS.md).

> This package supports the "Export Shader Pipeline" feature in Noisedeck.app. The feature runs shader compositions on other platforms. Noise Factor derives this package from the upstream Noisemaker Engine project and tests it for pixel-level parity.

**Math::Fractal::Noisemaker v1.000** — a software runtime for shaders, in pure Perl.

This is the Perl home of the [Noisemaker](https://noisemaker.app) rendering engine. It runs a bundled catalog of 205 generators, filters, mixers, and typed effects entirely on the CPU. The parity evidence and its limits are described below.
Rendering works offline. During development, a pure-Perl GLSL ES 3.00 front end transpiles source from the Noisemaker shader CDN into the bundled kernels. The runtime implements:

- Float32 register rounding.
- Half-float render-target quantization.
- GLSL uint32 wraparound.
- Screen-space derivatives.
- GL texture sampling.

Version 1.000 is incompatible with the historical 0.105 API. Read the migration
section before upgrading existing programs.

## Install

Perl 5.22 or later and core modules are required. Rendering requires neither
JavaScript nor a GPU. MP4 encoding additionally requires FFmpeg with libx264.

    perl Makefile.PL
    make
    make test
    make install

## Use

    make-noise generate synth/noise --width 32 --height 32 --seed 3
    make-noise generate random --width 32 --height 32
    make-noise apply filter/crt art.png
    make-noise animate synth/curl --width 16 --height 16 --frame-count 3 --filename curl.mp4
    echo 'search synth, filter
    noise(seed: 3, ridges: true).vignette().write(o0)
    render(o0)' | make-noise run --width 32 --height 32

Start small: rendering is synchronous, pixel by pixel, and complex effects at
large resolutions can take minutes. The CLI reports progress on standard error.
Its historical defaults remain 1024×1024 for `generate` and 512×512 for `run` and
`animate`; the explicit small sizes above make better first experiments.
Without FFmpeg, `animate --save-frames DIR` can still produce PNG frames.

Or from Perl:

    use Math::Fractal::Noisemaker::Renderer qw(render_effect);
    use Math::Fractal::Noisemaker::PNG qw(encode_png);

    my $surface = render_effect('synth/noise', { seed => 3 },
        undef, width => 32, height => 32, seed => 3);
    open my $out, '>:raw', 'noise.png' or die $!;
    print {$out} encode_png($surface) or die $!;
    close $out or die $!;

## API and effect discovery

Installed documentation is available with `perldoc Math::Fractal::Noisemaker`
and `perldoc Math::Fractal::Noisemaker::Renderer`. The renderer reference covers
parameters, textures, return values, DSL programs, output sinks, and errors.
`Surface`, `PNG`, `DSL`, `SinkManager`, `FrameExportQueue`, and
`CpuFrameExportAdapter` also have their own POD references.

List the installed effects without rendering:

    perl -MMath::Fractal::Noisemaker::Renderer=meta -e 'print "$_\n" for sort keys %{meta()->{effects}}'

Inspect an effect's parameter types, defaults, named choices, and UI ranges:

    perl -MJSON::PP -MMath::Fractal::Noisemaker::Renderer=meta -e 'print JSON::PP->new->pretty->canonical->encode(meta()->{effects}{"synth/noise"}{params})'

Pass values using `--param NAME=VALUE`, or a parameter hash in Perl. Unknown
names and malformed values are errors. UI ranges are hints: finite numeric
values outside sliders remain supported. Surface inputs go in the renderer's
inputs hash; the CLI accepts PNG inputs. PNG support is limited to 8-bit,
non-interlaced images; JPEG and interlaced PNG are unsupported.

## Migration from 0.105

This is a breaking major release. It does not preserve `Math::Fractal::Noisemaker::make()`
or `make-noise -type ...`. Keep existing applications on 0.105 until their calls
are migrated; do not upgrade them in place without testing.

Use `render_effect` or `render_dsl`, then `encode_png` and an explicit file write.
The result is a `Surface`, not the old `Imager` object and filename pair.
`$surface->to_rgba8` supplies packed RGBA bytes for integration with other image
libraries. Replace old CLI recipes with `generate EFFECT` or a DSL composition.
Effect names and parameters differ, there is no automatic old-to-new noise-type
mapping, and old seeds do not promise identical output. The new implementation
is distributed under the MIT license in `LICENSE`.

## Parity

`scripts/parity.pl` compares all 167 non-iterated image effects with the
reference JS CPU engine at 8×8, seed 1, time 0.25, with default parameters.
It requires exact RGBA8 bytes and fails on differences or errors. The 38 iterated
and typed effects are excluded from this sweep and have focused DSL/runtime tests.
Those tests do not establish parity for all parameter combinations, resolutions,
platforms, or GPU drivers. A passing default sweep is not full-catalog parity.

The exact reference commit and runtime digest are recorded in
`scripts/oracle-lock.json`. Check out that commit of `noisemaker-for-cpu` and set
`NOISEMAKER_CPU_DIR` to its absolute path; Node.js 22 or later is required.
The harness hashes the reference's `bin/`, `src/`, `package.json`, and upstream
source-lock file before rendering, so local reference edits fail verification.

    RELEASE_TESTING=1 NOISEMAKER_CPU_DIR=/path/to/pinned-reference prove -l t/05-parity.t
    NOISEMAKER_CPU_DIR=/path/to/pinned-reference perl scripts/parity.pl

Normal installation tests skip the external reference when unavailable.
`RELEASE_TESTING=1` makes a missing reference a failure. CI tests the source and
`make disttest` distribution on Linux Perl 5.22/5.42 and macOS Perl 5.42, and
runs the pinned parity checks before dispatching export-kit publication.
Windows, 32-bit Perl, and alternative floating-point configurations are not
currently covered by this release matrix.

## Regenerating the bundle

    perl scripts/build-bundle.pl --all

This maintainer command fetches GLSL and metadata and stages a replacement for
`lib/Math/Fractal/Noisemaker/bundle/`. Fetch, compilation, or source-drift failures
leave the previous bundle unchanged. Inputs are cached and SHA-256 recorded in
`bundle-lock.json`; `--update-lock` explicitly accepts changed source. Review
the diff and rerun parity after regeneration. Do not rebuild during installation
or concurrently with rendering. See `perldoc Math::Fractal::Noisemaker::Transpiler::Build`.

## Support

Report issues at [the issue tracker](https://github.com/noisefactorllc/noisemaker-for-perl/issues)
with your Perl version, effect or DSL program, parameters, dimensions, and error.

## License

MIT. Copyright (c) Noise Factor LLC.
