package Math::Fractal::Noisemaker::JsTrig;

# Bit-exact reimplementation of V8's Math.sin / Math.cos for float64 inputs.
#
# The noisemaker-for-cpu oracle (and the upstream engine it mirrors) evaluates
# `osc()` automation with JavaScript's Math.sin/Math.cos. V8 (14.x, the node 26
# line) implements those as the classic fdlibm `__sin`/`__cos` from
# src/base/ieee754.cc — a different algorithm from the platform libm, so the
# libc sin/cos used by plain Perl diverges by 1 ulp on some arguments and the
# automation golden fixture (captured from the oracle) pins those bits. This
# module ports the fdlibm sin/cos pipeline verbatim — __kernel_sin,
# __kernel_cos, __ieee754_rem_pio2, __kernel_rem_pio2 — using Perl NV
# arithmetic (identical IEEE-754 double semantics on this platform) and exact
# bit extraction via pack/unpack, so results are bit-identical to the JS
# oracle.
#
# Only what the automation evaluator needs is ported; arguments are expected
# finite doubles (the evaluator never feeds inf/NaN here, but the guards match
# the C code anyway). Port of the sibling noisemaker_cpu/js_trig.py.

use strict;
use warnings;
no warnings 'portable';    # 64-bit hex literals (0x100000000 masks) on quad perl
use POSIX ();
use Exporter 'import';

our @EXPORT_OK = qw(js_sin js_cos);

# 64-bit pattern of a double, and back. Both directions use an explicit
# byte order, so the mapping is host-independent.
sub _bits {
    return unpack('Q>', pack('d>', $_[0]));
}

sub _high_word {
    return _bits($_[0]) >> 32;
}

sub _low_word {
    return _bits($_[0]) & 0xFFFFFFFF;
}

sub _from_words {
    my ($high, $low) = @_;
    return unpack('d>', pack('NN', $high & 0xFFFFFFFF, $low & 0xFFFFFFFF));
}

sub _set_low {
    my ($x, $v) = @_;
    return _from_words(_bits($x) >> 32, $v);
}

sub _kernel_sin {
    # fdlibm k_sin.c: kernel sin on [-pi/4, pi/4], y is the tail of x.
    my ($x, $y, $iy) = @_;
    my $half = 5.00000000000000000000e-01;
    my $S1   = -1.66666666666666324348e-01;
    my $S2   = 8.33333333332248946124e-03;
    my $S3   = -1.98412698298579493134e-04;
    my $S4   = 2.75573137070700676789e-06;
    my $S5   = -2.50507602534068634195e-08;
    my $S6   = 1.58969099521155010221e-10;

    my $ix = _high_word($x) & 0x7FFFFFFF;
    if ($ix < 0x3E400000) {    # |x| < 2**-27
        return $x if int($x) == 0;
    }
    my $z = $x * $x;
    my $v = $z * $x;
    my $r = $S2 + $z * ($S3 + $z * ($S4 + $z * ($S5 + $z * $S6)));
    return $x + $v * ($S1 + $z * $r) if $iy == 0;
    return $x - (($z * ($half * $y - $v * $r) - $y) - $v * $S1);
}

sub _kernel_cos {
    # fdlibm k_cos.c: kernel cos on [-pi/4, pi/4], y is the tail of x.
    my ($x, $y) = @_;
    my $one = 1.00000000000000000000e+00;
    my $C1  = 4.16666666666666019037e-02;
    my $C2  = -1.38888888888741095749e-03;
    my $C3  = 2.48015872894767294178e-05;
    my $C4  = -2.75573143513906633035e-07;
    my $C5  = 2.08757232129817482790e-09;
    my $C6  = -1.13596475577881948265e-11;

    my $ix = _high_word($x) & 0x7FFFFFFF;
    if ($ix < 0x3E400000) {    # if x < 2**-27
        return $one if int($x) == 0;
    }
    my $z = $x * $x;
    my $r = $z * ($C1 + $z * ($C2 + $z * ($C3 + $z * ($C4 + $z * ($C5 + $z * $C6)))));
    if ($ix < 0x3FD33333) {    # if |x| < 0.3
        return $one - (0.5 * $z - ($z * $r - $x * $y));
    }
    my $qx;
    if ($ix > 0x3FE90000) {    # x > 0.78125
        $qx = 0.28125;
    }
    else {
        $qx = _from_words($ix - 0x00200000, 0);    # x/4
    }
    my $iz = 0.5 * $z - $qx;
    my $a  = $one - $qx;
    return $a - ($iz - ($z * $r - $x * $y));
}

my @_TWO_OVER_PI = (
    0xA2F983, 0x6E4E44, 0x1529FC, 0x2757D1, 0xF534DD, 0xC0DB62, 0x95993C,
    0x439041, 0xFE5163, 0xABDEBB, 0xC561B7, 0x246E3A, 0x424DD2, 0xE00649,
    0x2EEA09, 0xD1921C, 0xFE1DEB, 0x1CB129, 0xA73EE8, 0x8235F5, 0x2EBB44,
    0x84E99C, 0x7026B4, 0x5F7E41, 0x3991D6, 0x398353, 0x39F49C, 0x845F8B,
    0xBDF928, 0x3B1FF8, 0x97FFDE, 0x05980F, 0xEF2F11, 0x8B5A0A, 0x6D1F6D,
    0x367ECF, 0x27CB09, 0xB74F46, 0x3F669E, 0x5FEA2D, 0x7527BA, 0xC7EBE5,
    0xF17B3D, 0x0739F7, 0x8A5292, 0xEA6BFB, 0x5FB11F, 0x8D5D08, 0x560330,
    0x46FC7B, 0x6BABF0, 0xCFBC20, 0x9AF436, 0x1DA9E3, 0x91615E, 0xE61B08,
    0x659985, 0x5F14A0, 0x68408D, 0xFFD880, 0x4D7327, 0x310606, 0x1556CA,
    0x73A8C9, 0x60E27B, 0xC08C6B,
);

my @_NPIO2_HW = (
    0x3FF921FB, 0x400921FB, 0x4012D97C, 0x401921FB, 0x401F6A7A, 0x4022D97C,
    0x4025FDBB, 0x402921FB, 0x402C463A, 0x402F6A7A, 0x4031475C, 0x4032D97C,
    0x40346B9C, 0x4035FDBB, 0x40378FDB, 0x403921FB, 0x403AB41B, 0x403C463A,
    0x403DD85A, 0x403F6A7A, 0x40407E4C, 0x4041475C, 0x4042106C, 0x4042D97C,
    0x4043A28C, 0x40446B9C, 0x404534AC, 0x4045FDBB, 0x4046C6CB, 0x40478FDB,
    0x404858EB, 0x404921FB,
);

my $_INVPIO2 = 6.36619772367581382433e-01;
my $_PIO2_1  = 1.57079632673412561417e+00;
my $_PIO2_1T = 6.07710050650619224932e-11;
my $_PIO2_2  = 6.07710050630396597660e-11;
my $_PIO2_2T = 2.02226624879595063154e-21;
my $_PIO2_3  = 2.02226624871116645580e-21;
my $_PIO2_3T = 8.47842766036889956997e-32;

my $_TWO24  = 1.67772160000000000000e+07;
my $_TWON24 = 5.96046447753906250000e-08;

sub _rem_pio2 {
    # fdlibm e_rem_pio2.c: return (n, [y0, y1]) with x = n*pi/2 + y0 + y1.
    my ($x) = @_;
    my $hx        = _high_word($x);
    my $hx_signed = $hx >= 0x80000000 ? $hx - 0x100000000 : $hx;    # C int32_t view
    my $ix        = $hx & 0x7FFFFFFF;
    if ($ix <= 0x3FE921FB) {    # |x| ~<= pi/4, no need for reduction
        return (0, [$x, 0.0]);
    }
    if ($ix < 0x4002D97C) {     # |x| < 3pi/4, special case with n=+-1
        if ($hx_signed > 0) {
            my $z = $x - $_PIO2_1;
            my ($y0, $y1);
            if ($ix != 0x3FF921FB) {    # 33+53 bit pi is good enough
                $y0 = $z - $_PIO2_1T;
                $y1 = ($z - $y0) - $_PIO2_1T;
            }
            else {                      # near pi/2, use 33+33+53 bit pi
                $z -= $_PIO2_2;
                $y0 = $z - $_PIO2_2T;
                $y1 = ($z - $y0) - $_PIO2_2T;
            }
            return (1, [$y0, $y1]);
        }
        my $z = $x + $_PIO2_1;
        my ($y0, $y1);
        if ($ix != 0x3FF921FB) {
            $y0 = $z + $_PIO2_1T;
            $y1 = ($z - $y0) + $_PIO2_1T;
        }
        else {
            $z += $_PIO2_2;
            $y0 = $z + $_PIO2_2T;
            $y1 = ($z - $y0) + $_PIO2_2T;
        }
        return (-1, [$y0, $y1]);
    }
    if ($ix <= 0x413921FB) {    # |x| ~<= 2^19*(pi/2), medium size
        my $t = abs($x);
        my $n  = int($t * $_INVPIO2 + 0.5);    # C int32 cast: truncate toward zero
        my $fn = 0.0 + $n;
        my $r  = $t - $fn * $_PIO2_1;
        my $w  = $fn * $_PIO2_1T;              # 1st round good to 85 bit
        my $y0;
        if ($n < 32 && $ix != $_NPIO2_HW[ $n - 1 ]) {
            $y0 = $r - $w;                     # quick check no cancellation
        }
        else {
            my $j = $ix >> 20;
            $y0 = $r - $w;
            my $i = $j - ((_high_word($y0) >> 20) & 0x7FF);
            if ($i > 16) {                     # 2nd iteration needed, good to 118
                $t = $r;
                $w = $fn * $_PIO2_2;
                $r = $t - $w;
                $w = $fn * $_PIO2_2T - (($t - $r) - $w);
                $y0 = $r - $w;
                $i = $j - ((_high_word($y0) >> 20) & 0x7FF);
                if ($i > 49) {                 # 3rd iteration need, 151 bits acc
                    $t = $r;                   # will cover all possible cases
                    $w = $fn * $_PIO2_3;
                    $r = $t - $w;
                    $w = $fn * $_PIO2_3T - (($t - $r) - $w);
                    $y0 = $r - $w;
                }
            }
        }
        my $y1 = ($r - $y0) - $w;
        return (-$n, [-$y0, -$y1]) if $hx_signed < 0;
        return ($n, [$y0, $y1]);
    }
    # all other (large) arguments
    if ($ix >= 0x7FF00000) {    # x is inf or NaN
        my $nan = $x - $x;
        return (0, [$nan, $nan]);
    }
    # set z = scalbn(|x|, ilogb(x)-23)
    my $z  = _set_low(abs($x), _low_word($x));
    my $e0 = ($ix >> 20) - 1046;    # e0 = ilogb(z)-23
    # SET_HIGH_WORD(z, ix - (int32_t)((uint32_t)e0 << 20))
    my $shifted        = ($e0 << 20) & 0xFFFFFFFF;
    my $shifted_signed = $shifted >= 0x80000000 ? $shifted - 0x100000000 : $shifted;
    $z = _from_words(($ix - $shifted_signed) & 0xFFFFFFFF, _low_word($z));
    my @tx = (0.0, 0.0, 0.0);
    for my $i (0 .. 1) {
        $tx[$i] = 0.0 + int($z);    # C int32 cast: truncate toward zero
        $z = ($z - $tx[$i]) * $_TWO24;
    }
    $tx[2] = $z;
    my $nx = 3;
    $nx-- while $tx[ $nx - 1 ] == 0.0;
    my ($n, $y) = _kernel_rem_pio2([ @tx[ 0 .. $nx - 1 ] ], $e0, 2);
    return (-$n, [-$y->[0], -$y->[1]]) if $hx >= 0x80000000;
    return ($n, $y);
}

my @_PIO2_CHUNKS = (
    1.57079625129699707031e+00,
    7.54978941586159635335e-08,
    5.39030252995776476554e-15,
    3.28200341580791294123e-22,
    1.27065575308067607349e-29,
    1.22933308981111328932e-36,
    2.73370053816464559624e-44,
    2.16741683877804819444e-51,
);

my @_INIT_JK = (2, 3, 4, 6);

sub _kernel_rem_pio2 {
    # fdlibm k_rem_pio2.c: return (n mod 8, [y0, y1]) for positive x given as
    # nx 24-bit chunks with scaled exponent e0.
    my ($x_in, $e0, $prec) = @_;
    my @x  = @$x_in;
    my $nx = scalar @x;
    my $jk = $_INIT_JK[$prec];
    my $jp = $jk;

    my $jx = $nx - 1;
    # C int division truncates toward zero; e0 >= -22 here so both floor and
    # truncation agree once jv is clamped at zero.
    my $jv = int(($e0 - 3) / 24);
    $jv = 0 if $jv < 0;
    my $q0 = $e0 - 24 * ($jv + 1);

    # set up f[0]..f[jx+jk] where f[jx+jk] = ipio2[jv+jk]
    my $j = $jv - $jx;
    my $m = $jx + $jk;
    my @f = (0.0) x ($m + 1);
    for my $i (0 .. $m) {
        $f[$i] = $j < 0 ? 0.0 : 0.0 + $_TWO_OVER_PI[$j];
        $j++;
    }

    # compute q[0]..q[jk]
    my @q = (0.0) x ($jk + 1);
    for my $i (0 .. $jk) {
        my $fw = 0.0;
        for my $jj (0 .. $jx) {
            $fw += $x[$jj] * $f[ $jx + $i - $jj ];
        }
        $q[$i] = $fw;
    }

    my $jz = $jk;
    my @iq = (0) x 20;
    my @fq = (0.0) x 20;
    my ($n, $z, $ih);
  RECOMPUTE:
    while (1) {
        # distill q[] into iq[] reversingly
        $z = $q[$jz];
        my $i = 0;
        my $jj = $jz;
        while ($jj > 0) {
            my $fw = 0.0 + int($_TWON24 * $z);    # C int32 cast: truncate toward zero
            $iq[$i] = int($z - $_TWO24 * $fw);
            $z = $q[ $jj - 1 ] + $fw;
            $i++;
            $jj--;
        }

        # compute n
        $z = POSIX::ldexp($z, $q0);               # actual value of z
        $z -= 8.0 * POSIX::floor($z * 0.125);     # trim off integer >= 8
        $n = int($z);                             # C int32 cast
        $z -= 0.0 + $n;
        $ih = 0;
        if ($q0 > 0) {                            # need iq[jz-1] to determine n
            my $i = $iq[ $jz - 1 ] >> (24 - $q0);
            $n += $i;
            $iq[ $jz - 1 ] -= $i << (24 - $q0);
            $ih = $iq[ $jz - 1 ] >> (23 - $q0);
        }
        elsif ($q0 == 0) {
            $ih = $iq[ $jz - 1 ] >> 23;
        }
        elsif ($z >= 0.5) {
            $ih = 2;
        }

        if ($ih > 0) {                            # q > 0.5
            $n += 1;
            my $carry = 0;
            for my $i (0 .. $jz - 1) {              # compute 1-q
                my $jj = $iq[$i];
                if ($carry == 0) {
                    if ($jj != 0) {
                        $carry = 1;
                        $iq[$i] = 0x1000000 - $jj;
                    }
                }
                else {
                    $iq[$i] = 0xFFFFFF - $jj;
                }
            }
            if ($q0 > 0) {                          # rare case: chance is 1 in 12
                if ($q0 == 1) {
                    $iq[ $jz - 1 ] &= 0x7FFFFF;
                }
                elsif ($q0 == 2) {
                    $iq[ $jz - 1 ] &= 0x3FFFFF;
                }
            }
            if ($ih == 2) {
                $z = 1.0 - $z;
                $z -= POSIX::ldexp(1.0, $q0) if $carry != 0;
            }
        }

        # check if recomputation is needed
        if ($z == 0.0) {
            my $jflag = 0;
            for my $i (reverse $jk .. $jz - 1) {
                $jflag |= $iq[$i];
            }
            if ($jflag == 0) {                      # need recomputation
                my $k = 1;
                $k++ while $jk >= $k && $iq[ $jk - $k ] == 0;    # no. of terms needed

                for my $i ($jz + 1 .. $jz + $k) {                # add q[jz+1]..q[jz+k]
                    $f[ $jx + $i ] = 0.0 + $_TWO_OVER_PI[ $jv + $i ];
                    my $fw = 0.0;
                    for my $jj (0 .. $jx) {
                        $fw += $x[$jj] * $f[ $jx + $i - $jj ];
                    }
                    $q[$i] = $fw;
                }
                $jz += $k;
                next RECOMPUTE;                                  # goto recompute
            }
        }

        # chop off zero terms
        if ($z == 0.0) {
            $jz -= 1;
            $q0 -= 24;
            $jz -= 1, $q0 -= 24 while $iq[$jz] == 0;
        }
        else {    # break z into 24-bit if necessary
            $z = POSIX::ldexp($z, -$q0);
            if ($z >= $_TWO24) {
                my $fw = 0.0 + int($_TWON24 * $z);
                $iq[$jz] = int($z - $_TWO24 * $fw);
                $jz += 1;
                $q0 += 24;
                $iq[$jz] = int($fw);
            }
            else {
                $iq[$jz] = int($z);
            }
        }

        # convert integer "bit" chunk to floating-point value
        my $fw = POSIX::ldexp(1.0, $q0);
        for my $i (reverse 0 .. $jz) {
            $q[$i] = $fw * $iq[$i];
            $fw *= $_TWON24;
        }

        # compute PIo2[0..jp]*q[jz..0]
        for my $i (reverse 0 .. $jz) {
            $fw = 0.0;
            my $limit = $jp < $jz - $i ? $jp : $jz - $i;
            for my $k (0 .. $limit) {
                $fw += $_PIO2_CHUNKS[$k] * $q[ $i + $k ];
            }
            $fq[ $jz - $i ] = $fw;
        }

        # compress fq[] into y[] (prec is 1 or 2 here: two-double result)
        $fw = 0.0;
        for my $i (reverse 0 .. $jz) {
            $fw += $fq[$i];
        }
        my $y0 = $ih == 0 ? $fw : -$fw;
        $fw = $fq[0] - $fw;
        for my $i (1 .. $jz) {
            $fw += $fq[$i];
        }
        my $y1 = $ih == 0 ? $fw : -$fw;
        return ($n & 7, [$y0, $y1]);
    }
}

sub js_sin {
    # V8 Math.sin (fdlibm __sin) for a finite double.
    my ($x) = @_;
    $x = 0.0 + $x;
    my $ix = _high_word($x) & 0x7FFFFFFF;
    return _kernel_sin($x, 0.0, 0) if $ix <= 0x3FE921FB;    # |x| ~< pi/4
    return $x - $x if $ix >= 0x7FF00000;                    # sin(Inf or NaN) is NaN
    my ($n, $y) = _rem_pio2($x);
    my $quadrant = $n & 3;
    return _kernel_sin($y->[0], $y->[1], 1) if $quadrant == 0;
    return _kernel_cos($y->[0], $y->[1])    if $quadrant == 1;
    return -_kernel_sin($y->[0], $y->[1], 1) if $quadrant == 2;
    return -_kernel_cos($y->[0], $y->[1]);
}

sub js_cos {
    # V8 Math.cos (fdlibm __cos) for a finite double.
    my ($x) = @_;
    $x = 0.0 + $x;
    my $ix = _high_word($x) & 0x7FFFFFFF;
    return _kernel_cos($x, 0.0) if $ix <= 0x3FE921FB;       # |x| ~< pi/4
    return $x - $x if $ix >= 0x7FF00000;                    # cos(Inf or NaN) is NaN
    my ($n, $y) = _rem_pio2($x);
    my $quadrant = $n & 3;
    return _kernel_cos($y->[0], $y->[1])     if $quadrant == 0;
    return -_kernel_sin($y->[0], $y->[1], 1) if $quadrant == 1;
    return -_kernel_cos($y->[0], $y->[1])    if $quadrant == 2;
    return _kernel_sin($y->[0], $y->[1], 1);
}

1;

__END__

=head1 NAME

Math::Fractal::Noisemaker::JsTrig - bit-exact V8 Math.sin/Math.cos for the automation evaluator

=head1 SYNOPSIS

    use Math::Fractal::Noisemaker::JsTrig qw(js_sin js_cos);
    my $s = js_sin(0.5);    # bit-identical to JavaScript Math.sin(0.5)

=head1 DESCRIPTION

Ports V8's fdlibm C<__sin>/C<__cos> (including C<__ieee754_rem_pio2> and
C<__kernel_rem_pio2>) on Perl NV arithmetic with exact bit manipulation.
Plain Perl C<sin>/C<cos> call the platform libm, which diverges from V8 by
1 ulp on some arguments; the upstream oscillator evaluator's golden fixture
pins those bits. C<js_sin> and C<js_cos> accept finite doubles.

=cut
