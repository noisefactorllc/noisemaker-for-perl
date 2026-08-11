package Math::Fractal::Noisemaker;

use strict;
use warnings;

our $VERSION = '1.000';

1;

__END__

=head1 NAME

Math::Fractal::Noisemaker - a software runtime for shaders

=head1 SYNOPSIS

    use Math::Fractal::Noisemaker::Renderer qw(render_effect);
    use Math::Fractal::Noisemaker::PNG qw(encode_png);

    my $surface = render_effect('synth/noise', { seed => 3 },
        undef, width => 512, height => 512, seed => 3);

    open my $out, '>:raw', 'noise.png' or die $!;
    print {$out} encode_png($surface);

Or from the shell:

    make-noise generate synth/noise --width 512 --height 512 --seed 3

=head1 DESCRIPTION

Math::Fractal::Noisemaker renders the Noisemaker shader catalog - 205
generators, filters, and mixers written in GLSL - entirely on the CPU, in
pure Perl, with byte-parity against the reference Noisemaker engine.

Effects are fetched as GLSL from the Noisemaker shader CDN, transpiled to
Perl by a pure-Perl GLSL front end (L<Math::Fractal::Noisemaker::Transpiler>),
and executed per-pixel by a float32-faithful software runtime
(L<Math::Fractal::Noisemaker::Runtime>) that reproduces GPU arithmetic:
float32 register rounding, half-float render-target quantization, GLSL
uint32 wraparound, screen-space derivatives, and GL texture sampling.

This is version 1.000 of Math::Fractal::Noisemaker: a ground-up
reimagining of the module as the Perl home of the Noisemaker rendering
engine. The classic slow-noise-in-a-loop module this name once described
has grown up into a shader runtime; it still makes noise.

=head1 SEE ALSO

L<https://noisemaker.app> - Noisemaker

L<https://noisedeck.app> - Noisedeck, built on the same engine

=head1 LICENSE

MIT. Copyright (c) Noise Factor LLC.

=cut
