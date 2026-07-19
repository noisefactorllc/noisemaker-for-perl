package Math::Fractal::Noisemaker::DrawOps;

# CPU-only draw operations for drawMode passes (no GLSL kernel).
#
# wormhole deposit: port of noisemaker-cpu src/effects/cpu/wormhole.js
# (runWormholeDeposit) via the Python port — scatter each source pixel into a
# lightness-driven offset destination, accumulating weighted color with
# float16 truncation (matching the GPU rgba16f attachment).

use strict;
use warnings;
use POSIX ();

use Math::Fractal::Noisemaker::TextureFormat qw(float16_truncate);

my %DRAW_OPS;    # "effect_id:program" -> sub { my ($src, $dest, $uniforms) = @_; }

sub register {
    my ($effect_id, $program, $op) = @_;
    $DRAW_OPS{"$effect_id:$program"} = $op;
}

sub get_draw_op {
    my ($effect_id, $program) = @_;
    return $DRAW_OPS{"$effect_id:$program"};
}

my $TAU = 6.28318530717959;
my $PI  = 3.141592653589793;

sub _f32 { unpack('f', pack('f', $_[0])) }
sub _add { _f32($_[0] + $_[1]) }
sub _mul { _f32($_[0] * $_[1]) }
sub _div { _f32($_[0] / $_[1]) }

sub _oklab_lightness {
    my ($red, $green, $blue) = @_;
    my $r = $red < 0   ? 0 : $red > 1   ? 1 : $red;
    my $g = $green < 0 ? 0 : $green > 1 ? 1 : $green;
    my $b = $blue < 0  ? 0 : $blue > 1  ? 1 : $blue;
    my $l = _add(_add(_mul(_f32(0.4122214708), $r), _mul(_f32(0.5363325363), $g)), _mul(_f32(0.0514459929), $b));
    my $m = _add(_add(_mul(_f32(0.2119034982), $r), _mul(_f32(0.6806995451), $g)), _mul(_f32(0.1073969566), $b));
    my $s = _add(_add(_mul(_f32(0.0883024619), $r), _mul(_f32(0.2817188376), $g)), _mul(_f32(0.6299787005), $b));
    my $exponent = _div(1, 3);
    my $lr = _f32(($l > 0 ? $l : 0)**$exponent);
    my $mr = _f32(($m > 0 ? $m : 0)**$exponent);
    my $sr = _f32(($s > 0 ? $s : 0)**$exponent);
    return _add(_add(_mul(_f32(0.2104542553), $lr), _mul(_f32(0.793617785), $mr)), _mul(_f32(-0.0040720468), $sr));
}

sub _wrap_repeat {
    my ($value, $size) = @_;
    return (($value % $size) + $size) % $size;
}

sub _wrap_mirror {
    my ($value, $size) = @_;
    my $mirrored = _wrap_repeat($value, $size * 2);
    return $size - 1 - abs($mirrored - $size + 1);
}

sub wormhole_deposit {
    my ($input, $dest, $uniforms) = @_;
    my ($width, $height) = ($input->width, $input->height);
    die "wormhole deposit requires matching source/destination dimensions\n"
        if $width != $dest->width || $height != $dest->height;
    my $idata = $input->data;
    my $odata = $dest->data;
    my $kink  = 0.0 + (defined $uniforms->{kink} ? $uniforms->{kink} : 0);
    my $pixel_stride = 1024 * (defined $uniforms->{stride} ? $uniforms->{stride} : 0);
    my $rotation = _div(_mul(_f32(defined $uniforms->{rotation} ? $uniforms->{rotation} : 0), _f32($PI)), 180);
    my $wrap = int(defined $uniforms->{wrap} ? $uniforms->{wrap} : 0);
    # Vertex IDs enumerate GL texels bottom-up. Surface storage is top-down.
    for my $source_y (0 .. $height - 1) {
        for my $source_x (0 .. $width - 1) {
            my $source_row = $height - 1 - $source_y;
            my $so = ($source_row * $width + $source_x) * 4;
            my $lightness = _oklab_lightness($idata->[$so], $idata->[ $so + 1 ], $idata->[ $so + 2 ]);
            my $angle    = _add(_mul(_mul($lightness, _f32($TAU)), _f32($kink)), $rotation);
            my $offset_x = _mul(_add(_f32(cos $angle), 1), _f32($pixel_stride));
            my $offset_y = _mul(_add(_f32(sin $angle), 1), _f32($pixel_stride));
            my $dest_x = POSIX::floor(_add($source_x, $offset_x));
            my $dest_y = POSIX::floor(_add($source_y, $offset_y));
            if ($wrap == 0) {
                $dest_x = _wrap_mirror($dest_x, $width);
                $dest_y = _wrap_mirror($dest_y, $height);
            }
            elsif ($wrap == 2) {
                $dest_x = $dest_x < 0 ? 0 : $dest_x > $width - 1  ? $width - 1  : $dest_x;
                $dest_y = $dest_y < 0 ? 0 : $dest_y > $height - 1 ? $height - 1 : $dest_y;
            }
            else {
                $dest_x = _wrap_repeat($dest_x, $width);
                $dest_y = _wrap_repeat($dest_y, $height);
            }
            my $dest_row = $height - 1 - $dest_y;
            my $do     = ($dest_row * $width + $dest_x) * 4;
            my $weight = _mul($lightness, $lightness);
            $odata->[$do]     = float16_truncate(_add($odata->[$do],     _mul($idata->[$so],     $weight)));
            $odata->[$do + 1] = float16_truncate(_add($odata->[$do + 1], _mul($idata->[$so + 1], $weight)));
            $odata->[$do + 2] = float16_truncate(_add($odata->[$do + 2], _mul($idata->[$so + 2], $weight)));
        }
    }
}

register('filter/wormhole', 'deposit', \&wormhole_deposit);

1;
