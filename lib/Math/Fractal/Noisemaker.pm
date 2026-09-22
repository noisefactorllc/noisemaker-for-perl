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
        undef, width => 32, height => 32, seed => 3);

    open my $out, '>:raw', 'noise.png' or die $!;
    print {$out} encode_png($surface) or die $!;
    close $out or die $!;

Or from the shell:

    make-noise generate synth/noise --width 32 --height 32 --seed 3

=head1 DESCRIPTION

Math::Fractal::Noisemaker renders the Noisemaker shader catalog - 205
generators, filters, and mixers written in GLSL - entirely on the CPU, in
pure Perl. The bundled kernels render offline; no GPU or JavaScript runtime
is required. Perl 5.22 or later and its core modules are required.

During development, effects are fetched as GLSL from the Noisemaker shader CDN,
transpiled to Perl by L<Math::Fractal::Noisemaker::Transpiler::Build>,
and executed per-pixel by a float32-faithful software runtime
(L<Math::Fractal::Noisemaker::Runtime>) that reproduces GPU arithmetic:
float32 register rounding, half-float render-target quantization, GLSL
uint32 wraparound, screen-space derivatives, and GL texture sampling.

=head1 PUBLIC API

This module declares the distribution version. Import rendering functions
from L<Math::Fractal::Noisemaker::Renderer>; no functions are exported here.

=over 4

=item L<Math::Fractal::Noisemaker::Renderer>

C<render_effect>, C<render_dsl>, effect metadata, and the renderer object for sinks.

=item L<Math::Fractal::Noisemaker::Surface>

RGBA buffers, dimensions, cloning, and conversion to and from packed bytes.

=item L<Math::Fractal::Noisemaker::PNG>

C<encode_png> and C<decode_png> for PNG byte strings.

=item L<Math::Fractal::Noisemaker::DSL>

Tokenize, parse, and compile shader compositions without rendering them.

=item L<Math::Fractal::Noisemaker::SinkManager>, L<Math::Fractal::Noisemaker::FrameExportQueue>

Synchronous output sinks and bounded callback delivery. The CPU adapter and
borrowed frame contract are documented in L<Math::Fractal::Noisemaker::CpuFrameExportAdapter>.

=back

The remaining runtime, sampler, drawing, arithmetic, transpiler, and generated
kernel modules are implementation details. Their interfaces can change between
releases; use the public modules above for applications.

=head1 PERFORMANCE AND LIMITATIONS

Rendering runs synchronously, pixel by pixel, in Perl. Start with 32 by 32
pixels. Complex effects and large buffers can take minutes; animation renders
each frame separately. The CLI prints progress to standard error. MP4 encoding
requires an external C<ffmpeg> executable with the C<libx264> encoder; use
C<--save-frames DIR> to retain PNG frames when FFmpeg is unavailable.

PNG input supports 8-bit, non-interlaced grayscale, RGB, palette, grayscale with
alpha, and RGBA images. JPEG, interlaced PNG, and other PNG bit depths are not
supported. The pixel limit is 16,777,216, but Perl scalar storage and temporary
buffers require substantially more memory than packed RGBA bytes.

The default parity harness compares 167 non-iterated image effects at 8 by 8,
seed 1, time 0.25, against a separately pinned JavaScript CPU reference. The
38 iterated or typed effects have focused tests but are excluded from that
sweep. This is not a claim of parity for every parameter, resolution, platform,
GPU driver, or historical Noisemaker release.

=head1 MIGRATING FROM 0.105

Version 1.000 is an intentionally incompatible major rewrite. It does not
implement the old C<Math::Fractal::Noisemaker::make(%args)> function or the
C<make-noise -type ...> command line. Existing 0.x applications must remain on
0.105 until migrated; do not upgrade them in place without updating their calls.

Replace C<make()> with C<render_effect()> or C<render_dsl()>, then encode and
write the returned C<Surface> as shown above. The return value is no longer
an C<Imager> object and filename pair. For integration with another image
library, C<< $surface->to_rgba8 >> supplies packed, top-down RGBA bytes.

Replace old CLI invocations with C<make-noise generate EFFECT> or C<make-noise run>.
Catalog IDs and parameters are different; there is no automatic mapping from
old noise types, and old seeds do not promise identical images. Inspect the
new catalog with C<meta()> as documented in the renderer. This release uses
the MIT license in the distribution's LICENSE file.

=head1 ERRORS AND SUPPORT

Public functions throw exceptions on invalid inputs or runtime failures.
Use C<eval> and inspect C<$@>. CLI usage errors exit 2; runtime failures exit 1.
Report bugs at L<https://github.com/noisefactorllc/noisemaker-for-perl/issues>
with the Perl version, effect or DSL program, parameters, dimensions, and error.

=head1 SEE ALSO

L<https://noisemaker.app> - Noisemaker

L<https://noisedeck.app> - Noisedeck, built on the same engine

=head1 LICENSE

MIT. Copyright (c) Noise Factor LLC.

=cut
