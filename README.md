# noisemaker-for-perl

**Math::Fractal::Noisemaker v1.000** — a software runtime for shaders, in pure Perl.

This is the Perl home of the [Noisemaker](https://noisemaker.app) rendering
engine: the 167-effect shader catalog behind [Noisedeck](https://noisedeck.app),
rendered entirely on the CPU with byte-parity against the reference engine.
GLSL is fetched from the Noisemaker shader CDN, transpiled to Perl by a
pure-Perl GLSL ES 3.00 front end, and executed per-pixel by a float32-faithful
runtime that reproduces GPU arithmetic: float32 register rounding, half-float
render-target quantization, GLSL uint32 wraparound, screen-space derivatives,
and GL texture sampling.

The classic `Math::Fractal::Noisemaker` made noise in a loop. It still makes
noise — it just learned every other trick in the deck too.

## Install

Core modules only — no CPAN dependencies.

    perl Makefile.PL
    make
    make test
    make install

## Use

    make-noise generate synth/noise --width 512 --height 512 --seed 3
    make-noise generate random
    make-noise apply filter/crt art.png
    make-noise animate synth/curl --frame-count 50 --filename curl.mp4
    echo 'search synth, filter
    noise(seed: 3, ridges: true).vignette().write(o0)
    render(o0)' | make-noise run --width 512 --height 512

Or from Perl:

    use Math::Fractal::Noisemaker::Renderer qw(render_effect);
    use Math::Fractal::Noisemaker::PNG qw(encode_png);

    my $surface = render_effect('synth/noise', { seed => 3 },
        undef, width => 512, height => 512, seed => 3);
    open my $out, '>:raw', 'noise.png' or die $!;
    print {$out} encode_png($surface);

## Parity

`scripts/parity.pl` renders every bundled effect in Perl and in the reference
JS engine (a sibling `noisemaker-cpu` checkout) and compares bytes.

## Regenerating the bundle

    perl scripts/build-bundle.pl --all

Fetches per-effect GLSL + metadata from the shader CDN (cached, sha256-locked
in `bundle-lock.json`) and transpiles it into
`lib/Math/Fractal/Noisemaker/bundle/`.

## License

MIT. Copyright (c) Noise Factor LLC.
