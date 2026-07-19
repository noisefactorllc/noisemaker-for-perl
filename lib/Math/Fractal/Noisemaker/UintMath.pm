package Math::Fractal::Noisemaker::UintMath;

# GPU-accurate uint32 and half-float integer primitives.
#
# Faithful, bit-exact port of the integer/bitwise helpers in noisemaker-cpu
# src/csl/glsl-runtime.js (uint32, pcg3d, hashUint32, floatBitsToUint,
# packHalf2x16/unpackHalf2x16, glslMod) plus the uint32 arithmetic that backs
# GLSL `uint` operators in transpiled kernels. Self-contained: core Perl only.
#
# Perl notes vs the Python port (noisemaker_cpu/uintmath.py):
# - Perl IVs are signed 64-bit; 0xFFFFFFFF * 0xFFFFFFFF overflows an IV and
#   silently degrades to an NV (53-bit mantissa, wrong low bits). `umul`
#   therefore uses a 16-bit-split multiply so every intermediate fits an IV.
# - float32 bit reinterpretation uses pack/unpack ('f' <-> 'L', both native
#   byte order, so the round trip is exact on any IEEE-754 host).

use strict;
use warnings;
use POSIX ();
use Exporter 'import';

our @EXPORT_OK = qw(
    u32 umul uadd usub ushl ushr uand uor uxor
    glsl_mod pcg3d hash_uint32 hash_uint
    float_bits_to_uint uint_bits_to_float
    pack_half_2x16 unpack_half_2x16
    fdiv
);

use constant _MASK32 => 0xFFFFFFFF;

my $INF = 9**9**9;
my $NAN = $INF - $INF;

# IEEE division: n/0 -> +-Inf, 0/0 -> NaN (Perl's / dies on zero divide).
# Honors the sign of a negative-zero denominator (n / -0.0 == -Inf).
sub fdiv {
    my ($n, $d) = @_;
    if ($d == 0) {
        return $NAN if $n == 0 || $n != $n;
        my $neg_zero = (unpack('Q', pack('d', $d)) >> 63) & 1;
        my $inf = ($n > 0) == !$neg_zero ? $INF : -$INF;
        return $inf;
    }
    return $n / $d;
}

# Coerce a scalar to a plain integer for bitwise work. Floats truncate toward
# zero (JS ToInt32/ToUint32); NaN/Infinity coerce to 0 (JS `NaN >>> 0 === 0`).
#
# Above 2^53 the value lives in an NV, and Perl's NV->IV conversion can
# corrupt low bits — so reduce mod 2^32 with fmod (exact in float64) BEFORE
# converting. fmod keeps the dividend's sign; the caller's `& MASK` restores
# two's-complement semantics for negatives.
sub _int_operand {
    my ($x) = @_;
    return 0 if $x != $x;                       # NaN
    return 0 if $x == $INF || $x == -$INF;      # +-Inf
    if ($x >= 9007199254740992.0 || $x <= -9007199254740992.0) {    # beyond 2^53
        my $m = POSIX::fmod(POSIX::trunc($x), 4294967296.0);
        $m += 4294967296.0 if $m < 0;
        return int($m);
    }
    return int($x);                             # truncates toward zero
}

# JS `value >>> 0` — unsigned 32-bit with wraparound.
sub u32 { _int_operand($_[0]) & _MASK32 }

# JS `Math.imul(a, b) >>> 0` — 32-bit wrapping multiply, unsigned result.
# 16-bit split keeps every intermediate below 2^48 (IV-safe).
sub umul {
    my ($a, $b) = @_;
    $a = u32($a);
    $b = u32($b);
    my $lo = ($a & 0xFFFF) * $b;
    my $hi = (($a >> 16) & 0xFFFF) * $b;
    return ($lo + (($hi & 0xFFFF) << 16)) & _MASK32;
}

sub uadd { (u32($_[0]) + u32($_[1])) & _MASK32 }
sub usub { (u32($_[0]) - u32($_[1])) & _MASK32 }
sub ushl { (u32($_[0]) << (u32($_[1]) & 0x1F)) & _MASK32 }
sub ushr { (u32($_[0]) >> (u32($_[1]) & 0x1F)) & _MASK32 }
sub uand { u32($_[0]) & u32($_[1]) }
sub uor  { u32($_[0]) | u32($_[1]) }
sub uxor { u32($_[0]) ^ u32($_[1]) }

# Floored modulo — GLSL/JS `x - y * floor(x / y)` (NOT Perl's %). Non-finite
# quotients (y == 0) propagate Inf/NaN like JS instead of dying.
sub glsl_mod {
    my ($x, $y) = @_;
    my $q = fdiv($x, $y);
    return $NAN if $q != $q;
    return $x - $y * POSIX::floor($q);
}

# 3-lane PCG hash (uvec3 -> uvec3). Sequential in-place lane updates: later
# lanes read the already-updated earlier lanes, exactly matching the JS
# statement order. A "parallel" translation gives the wrong answer.
sub pcg3d {
    my ($v3) = @_;
    my $x = u32($v3->[0]);
    my $y = u32($v3->[1]);
    my $z = u32($v3->[2]);

    $x = uadd(umul($x, 1664525), 1013904223);
    $y = uadd(umul($y, 1664525), 1013904223);
    $z = uadd(umul($z, 1664525), 1013904223);

    $x = uadd($x, umul($y, $z));
    $y = uadd($y, umul($z, $x));
    $z = uadd($z, umul($x, $y));

    $x = uxor($x, ushr($x, 16));
    $y = uxor($y, ushr($y, 16));
    $z = uxor($z, ushr($z, 16));

    $x = uadd($x, umul($y, $z));
    $y = uadd($y, umul($z, $x));
    $z = uadd($z, umul($x, $y));

    return [$x, $y, $z];
}

# Murmur-style uint32 finalizer (hashUint32 in glsl-runtime.js).
sub hash_uint32 {
    my ($x) = @_;
    my $r = u32($x);
    $r = uxor($r, ushr($r, 16));
    $r = umul($r, 0x7FEB352D);
    $r = uxor($r, ushr($r, 15));
    $r = umul($r, 0x846CA68B);
    $r = uxor($r, ushr($r, 16));
    return $r;
}

# stdlib.hashUint is a bare alias for hashUint32 in glsl-runtime.js.
*hash_uint = \&hash_uint32;

# Reinterpret a float32's bits as a uint32 (GLSL floatBitsToUint). The value
# is first rounded to float32 by pack('f'), matching JS Float32Array[0] = f.
sub float_bits_to_uint { unpack('L', pack('f', $_[0])) }

# Inverse reinterpretation (GLSL uintBitsToFloat).
sub uint_bits_to_float { unpack('f', pack('L', u32($_[0]))) }

# Decode one IEEE-754 binary16 to a float (halfToFloat in glsl-runtime.js).
sub _half_to_float {
    my ($bits) = @_;
    $bits &= 0xFFFF;
    my $sign     = ($bits & 0x8000) ? -1 : 1;
    my $exponent = ($bits >> 10) & 0x1F;
    my $fraction = $bits & 0x3FF;
    if ($exponent == 0) {
        return $sign * (2**-14) * ($fraction / 1024);
    }
    if ($exponent == 0x1F) {
        return $fraction ? $NAN : $sign * $INF;
    }
    return $sign * (2**($exponent - 15)) * (1 + $fraction / 1024);
}

# Encode a float to one binary16 (round-to-nearest, denormals, saturating
# overflow) — floatToHalf in glsl-runtime.js.
sub _float_to_half {
    my ($value) = @_;
    return 0x7E00 if $value != $value;
    return 0x7C00 if $value == $INF;
    return 0xFC00 if $value == -$INF;
    my $bits     = unpack('L', pack('f', $value));
    my $sign     = ($bits >> 16) & 0x8000;
    my $exponent = (($bits >> 23) & 0xFF) - 127 + 15;
    my $fraction = $bits & 0x7FFFFF;
    if ($exponent <= 0) {
        return $sign if $exponent < -10;
        $fraction = ($fraction | 0x800000) >> (1 - $exponent);
        return $sign | (($fraction + 0x1000) >> 13);
    }
    return $sign | 0x7C00 if $exponent >= 31;
    $fraction += 0x1000;
    if ($fraction & 0x800000) {
        $fraction = 0;
        $exponent += 1;
        return $sign | 0x7C00 if $exponent >= 31;
    }
    return $sign | ($exponent << 10) | ($fraction >> 13);
}

# GLSL packHalf2x16: v[0] low 16 bits, v[1] high 16.
sub pack_half_2x16 {
    my ($v2) = @_;
    my $lo = _float_to_half($v2->[0]);
    my $hi = _float_to_half($v2->[1]);
    return ($lo | ($hi << 16)) & _MASK32;
}

# GLSL unpackHalf2x16 — inverse of pack_half_2x16.
sub unpack_half_2x16 {
    my ($u) = @_;
    my $uu = u32($u);
    return [_half_to_float($uu & 0xFFFF), _half_to_float(($uu >> 16) & 0xFFFF)];
}

1;
