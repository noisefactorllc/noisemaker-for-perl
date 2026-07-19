package Math::Fractal::Noisemaker::TextureFormat;

# Per-pass texture-format quantization.
#
# Faithful port of noisemaker-cpu src/runtime/texture-format.js. After each
# render pass the reference engine quantizes the destination surface to that
# attachment's declared format (rgba16f by default, rgba8unorm for some
# intermediates). Skipping this leaves the port at full float32 and diverges
# from the GPU pipeline wherever an intermediate is stored at reduced
# precision.
#
# - rgba16f / rgba16float: round-TOWARD-ZERO truncation to IEEE 754 half
#   (truncate the low mantissa bits, do NOT round to nearest).
# - rgba8 / rgba8unorm: clamp to [0,1], round to 8-bit (JS Math.round =
#   floor(x + 0.5)), and scale back.

use strict;
use warnings;
use POSIX ();
use Exporter 'import';

our @EXPORT_OK = qw(float16_truncate quantize_texture);

my $INF = 9**9**9;
my $NAN = $INF - $INF;

# Truncate one float to rgba16f storage and decode back to float32.
sub float16_truncate {
    my ($value) = @_;
    my $bits    = unpack('L', pack('f', $value));
    my $sign    = ($bits >> 16) & 0x8000;
    my $src_exp = ($bits >> 23) & 0xFF;
    my $frac    = $bits & 0x7FFFFF;
    my $half;
    if ($src_exp == 0xFF) {    # inf preserves sign; nan -> canonical nan bits
        $half = $frac == 0 ? ($sign | 0x7C00) : 0x7E00;
    }
    else {
        my $exp = $src_exp - 127 + 15;
        if ($exp >= 0x1F) {    # overflow -> largest finite half (NOT inf)
            $half = $sign | 0x7BFF;
        }
        elsif ($exp <= 0) {    # subnormal / underflow
            if ($exp < -10) {
                $half = $sign;    # flush to signed zero
            }
            else {
                my $mant = $frac | 0x800000;
                $half = $sign | (($mant >> (1 - $exp)) >> 13);
            }
        }
        else {
            $half = $sign | ($exp << 10) | ($frac >> 13);
        }
    }
    return Math::Fractal::Noisemaker::UintMath::_half_to_float($half);
}

use Math::Fractal::Noisemaker::UintMath ();

# Quantize surface data in place to fmt; returns the surface.
sub quantize_texture {
    my ($surface, $fmt) = @_;
    $fmt = 'rgba16f' unless defined $fmt;
    my $d = $surface->data;
    if ($fmt eq 'rgba16f' || $fmt eq 'rgba16float') {
        $_ = float16_truncate($_) for @$d;
    }
    elsif ($fmt eq 'rgba8' || $fmt eq 'rgba8unorm') {
        # Mirror the reference exactly: value <= 0 ? 0 : value >= 1 ? 1 :
        # round(value*255)/255. NaN fails both comparisons and PROPAGATES
        # (floor(NaN) is NaN, no die) — the oracle and Python keep NaN too.
        for (@$d) {
            my $x = $_;
            $_ =
                  $x <= 0.0 ? 0.0
                : $x >= 1.0 ? 1.0
                : unpack('f', pack('f', POSIX::floor($x * 255.0 + 0.5) / 255.0));
        }
    }
    return $surface;
}

1;
