package Math::Fractal::Noisemaker::Sampler;

# Texture samplers — nearest, bottom-left-flipped nearest, and bilinear.
#
# Faithful port of noisemaker-cpu src/runtime/sampler.js. Every sampler
# clamps to the edge texel for out-of-range u/v (no wraparound).
#
# GLSL samplers address rows from the bottom, but Surface storage stays
# top-down (for fast PNG handoff). sample_nearest addresses storage rows
# directly (no flip). sample_nearest_bottom_left and sample_bilinear flip
# the INTEGER texel row (y = height - 1 - shader_y) rather than the
# normalized coordinate (1 - v) — `1 - v` is wrong exactly on texel
# boundaries. The flip is only observable on a non-uniform texture (a solid
# input renders identically either way), which is why it must match the GL
# bottom-left convention that texelFetch uses.
#
# sample_bilinear mirrors the JS precision behavior: the four taps are read
# at full (float64) precision and blended, and only the final per-channel
# result is rounded to float32 (Math.fround), matching JS's implicit float64
# widening of Float32Array reads.

use strict;
use warnings;
use POSIX ();
use Exporter 'import';

our @EXPORT_OK = qw(sample_nearest sample_nearest_bottom_left sample_bilinear);

sub _f32 { unpack('f', pack('f', $_[0])) }

sub _clamp {
    my ($value, $lo, $hi) = @_;
    return $lo if $value < $lo;
    return $hi if $value > $hi;
    return $value;
}

# Nearest-neighbor sample, addressing storage rows top-down (no flip).
sub sample_nearest {
    my ($surface, $u, $v) = @_;
    my $width  = $surface->width;
    my $height = $surface->height;
    my $x = _clamp(POSIX::floor($u * $width),  0, $width - 1);
    my $y = _clamp(POSIX::floor($v * $height), 0, $height - 1);
    my $source = ($y * $width + $x) * 4;
    my $d = $surface->data;
    return [@{$d}[$source .. $source + 3]];
}

# Nearest-neighbor sample with GLSL bottom-left row addressing (flips the
# integer texel row, not the normalized v).
sub sample_nearest_bottom_left {
    my ($surface, $u, $v) = @_;
    my $width  = $surface->width;
    my $height = $surface->height;
    my $x        = _clamp(POSIX::floor($u * $width),  0, $width - 1);
    my $shader_y = _clamp(POSIX::floor($v * $height), 0, $height - 1);
    my $y      = $height - 1 - $shader_y;
    my $source = ($y * $width + $x) * 4;
    my $d = $surface->data;
    return [@{$d}[$source .. $source + 3]];
}

# Bilinear sample, half-texel-centered, clamped to edge, GL bottom-left row
# addressing (flips the integer texel row, like sample_nearest_bottom_left).
sub sample_bilinear {
    my ($surface, $u, $v) = @_;
    my $width  = $surface->width;
    my $height = $surface->height;
    my $d      = $surface->data;

    my $px = _clamp($u * $width - 0.5,  0, $width - 1);
    my $py = _clamp($v * $height - 0.5, 0, $height - 1);
    my $x0 = POSIX::floor($px);
    my $y0 = POSIX::floor($py);
    my $x1 = $x0 + 1 < $width - 1  ? $x0 + 1 : $width - 1;
    my $y1 = $y0 + 1 < $height - 1 ? $y0 + 1 : $height - 1;
    my $tx = $px - $x0;
    my $ty = $py - $y0;

    my $row0 = ($height - 1 - $y0) * $width * 4;
    my $row1 = ($height - 1 - $y1) * $width * 4;
    my $p00  = $row0 + $x0 * 4;
    my $p10  = $row0 + $x1 * 4;
    my $p01  = $row1 + $x0 * 4;
    my $p11  = $row1 + $x1 * 4;

    my @out;
    for my $c (0 .. 3) {
        my $c00 = $d->[$p00 + $c];
        my $c10 = $d->[$p10 + $c];
        my $c01 = $d->[$p01 + $c];
        my $c11 = $d->[$p11 + $c];
        my $top    = $c00 + ($c10 - $c00) * $tx;
        my $bottom = $c01 + ($c11 - $c01) * $tx;
        # Math.fround happens once, at the very end, in the JS source.
        push @out, _f32($top + ($bottom - $top) * $ty);
    }
    return \@out;
}

1;
