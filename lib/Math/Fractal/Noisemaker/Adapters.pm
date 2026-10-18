package Math::Fractal::Noisemaker::Adapters;

# CPU adapter registry — the reference engine renders a handful of effects
# through hand-written CPU adapters (canonicalAdapterFactories) instead of
# the transpiled GLSL kernel. For byte-parity we run the same adapters:
#
#   filter/crt:crt        — handwritten Metal M2 float32 implementation.
#   filter/snow:snow      — full reimplementation (TV static), bit-faithful
#                           to snow.js's exact f32-rounding points.
#   filter/median:median — active sample count and exact packed unsigned keys.
#   filter/palette:palette— full reimplementation (cosine palette + HSV/OKLAB
#                           modes) over the vendored 55-entry table.
#
# An adapter factory is factory($rt, $compiled) -> kernel coderef; it may
# wrap the transpiled kernel or replace it entirely.

use strict;
use warnings;
use POSIX ();

use Math::Fractal::Noisemaker::Sampler qw(sample_bilinear sample_nearest_bottom_left);
use Math::Fractal::Noisemaker::PaletteData ();

my %ADAPTERS;

sub register {
    my ($effect_id, $program, $adapter) = @_;
    $ADAPTERS{"$effect_id:$program"} = $adapter;
}

sub get_adapter {
    my ($effect_id, $program) = @_;
    return $ADAPTERS{"$effect_id:$program"};
}

sub _f32 { unpack('f', pack('f', $_[0])) }

my $TAU     = 6.283185307179586;
my $TAU32   = _f32(6.283185307179586);
my $INV_TAU = _f32(1.0 / 6.283185307179586);

# ---- filter/crt: direct Metal M2 float32 implementation ----

sub _cmin {
    my ($a, $b) = @_;
    return POSIX::nan(0) if POSIX::isnan($a) || POSIX::isnan($b);
    return POSIX::copysign(0.0, -1.0) if $a == 0 && $b == 0 && (POSIX::signbit($a) || POSIX::signbit($b));
    return $a < $b ? $a : $b;
}
sub _cmax {
    my ($a, $b) = @_;
    return POSIX::nan(0) if POSIX::isnan($a) || POSIX::isnan($b);
    return 0.0 if $a == 0 && $b == 0 && (!POSIX::signbit($a) || !POSIX::signbit($b));
    return $a > $b ? $a : $b;
}
sub _cint32 {
    my ($value) = @_;
    return 0 unless POSIX::isfinite($value) && $value != 0;
    my $bits = POSIX::fmod(POSIX::trunc($value), 4294967296.0);
    $bits += 4294967296.0 if $bits < 0;
    return $bits >= 2147483648 ? $bits - 4294967296 : $bits;
}

# TwoSum retains the exact addition error to resolve float32 midpoint ties.
# Force IEEE doubles: Perl otherwise keeps some integral sums as 64-bit IVs.
sub _cf64 { unpack('d', pack('d', $_[0])) }
sub _cfma32 {
    my ($a, $b, $c) = @_;
    my $product = _cf64($a * $b);
    # Perl's integer arithmetic fast path can erase a floating negative zero.
    $product = POSIX::copysign(0.0, POSIX::signbit($a) != POSIX::signbit($b) ? -1.0 : 1.0)
        if $product == 0;
    my $sum = _cf64($product + $c);
    $sum = POSIX::copysign(0.0, -1.0)
        if $product == 0 && $c == 0 && POSIX::signbit($product) && POSIX::signbit($c);
    my $back = _cf64($sum - $product);
    my $error = _cf64(_cf64($product - _cf64($sum - $back)) + _cf64($c - $back));
    my $rounded = _f32($sum);
    return $rounded if $error == 0 || $rounded == $sum;
    my $toward_sum = $sum > $rounded ? 1 : -1;
    my $neighbor;
    if ($rounded == 0) {
        $neighbor = $toward_sum * unpack('f<', pack('L<', 1));
    } else {
        my $bits = unpack('L<', pack('f<', $rounded));
        $bits += (($rounded > 0) == ($toward_sum > 0)) ? 1 : -1;
        $neighbor = unpack('f<', pack('L<', $bits));
    }
    return $rounded unless ($rounded + $neighbor) / 2 == $sum;
    return $error > 0 ? _cmax($rounded, $neighbor) : _cmin($rounded, $neighbor);
}
sub _cadd {
    return POSIX::copysign(0.0, -1.0)
        if $_[0] == 0 && $_[1] == 0 && POSIX::signbit($_[0]) && POSIX::signbit($_[1]);
    return _f32($_[0] + $_[1]);
}
sub _csub {
    return POSIX::copysign(0.0, -1.0)
        if $_[0] == 0 && $_[1] == 0 && POSIX::signbit($_[0]) && !POSIX::signbit($_[1]);
    return _f32($_[0] - $_[1]);
}
sub _cmul {
    my ($a, $b) = @_;
    my $product = $a * $b;
    return POSIX::copysign(0.0, POSIX::signbit($a) != POSIX::signbit($b) ? -1.0 : 1.0) if $product == 0;
    return _f32($product);
}
# This adapter's M2 compile uses a rounded reciprocal, not generic M4 division.
sub _cdiv {
    my ($a, $b) = @_;
    my $reciprocal = $b == 0 ? POSIX::copysign(POSIX::HUGE_VAL(), $b) : 1.0 / $b;
    return _cmul($a, _f32($reciprocal));
}
sub _cfract { _f32($_[0] - POSIX::floor($_[0])) }
sub _cclamp { _cmin(_cmax($_[0], $_[1]), $_[2]) }
sub _cclamp01 { _cclamp($_[0], 0, 1) }
sub _csqrt { _f32(sqrt($_[0])) }
sub _cmix { _cfma32($_[2], _csub($_[1], $_[0]), $_[0]) }
sub _clength2 { _csqrt(_cfma32($_[1], $_[1], _cmul($_[0], $_[0]))) }
sub _cdot3 { _cfma32($_[2], $_[5], _cfma32($_[1], $_[4], _cmul($_[0], $_[3]))) }

my $C_INV_TAU = _f32(1 / (2 * atan2(0, -1)));
my $C_INV_THREE = _f32(1 / 3);
my $C_HASH = _f32(43758.5453123);
my $C_HASH3 = _f32(43758.5453);
sub _cquadrant_sine {
    my ($r) = @_;
    my $n = POSIX::floor($r);
    my $fraction = $r - $n;
    my $y = (_cint32($n) & 1) ? 1 - $fraction : $fraction;
    return $n >= 2 ? POSIX::copysign(0.0, -1.0) : 0.0 if $y == 0;
    my $z = 2 * $y * $y - 1;
    my $quotient = sin($y * atan2(0, -1) / 2) / $y;
    my $p = _f32($quotient - 2**-23 * (0.783734 + 0.010102 * $z + 0.052674 * (2 * $z * $z - 1)));
    my $value = _f32($y * $p);
    return $n >= 2 ? -$value : $value;
}
sub _cquadrant_of_turns { _f32(4 * ($_[0] - POSIX::floor($_[0]))) }
sub _csin { _cquadrant_sine(_cquadrant_of_turns(_f32($_[0] * $C_INV_TAU))) }
sub _csin_turns { _cquadrant_sine(_cquadrant_of_turns($_[0])) }
sub _ccos_turns { _cquadrant_sine(_cquadrant_of_turns(_cadd($_[0], 0.25))) }
sub _ccos_half_turns { _cquadrant_sine(_cquadrant_of_turns(_cfma32($_[0], 0.5, 0.25))) }
sub _cperiodic_value { _cfma32(_csin_turns(_csub($_[0], $_[1])), 0.5, 0.5) }

my $C289 = _f32(1 / 289);
my $C_TAYLOR_A = _f32(1.79284291400159);
my $C_TAYLOR_B = _f32(0.85373472095314);
my $C_X = _f32(1 / 6);
my $C_Y = _f32(1 / 3);
my $C_N = _f32(0.14285714285714285);
my $C_NS_X = _cmul($C_N, 2);
my $C_NS_Y = _csub(_cmul($C_N, 0.5), 1);
my $C_M0 = _f32(0.6);
sub _cmod289 { _csub($_[0], _cmul(POSIX::floor(_cmul($_[0], $C289)), 289)) }
sub _cpermute { _cmod289(_cmul(_cfma32($_[0], 34, 1), $_[0])) }
sub _csimplex_noise {
    my ($vx, $vy, $vz) = @_;
    my $dv = _cdot3($vx, $vy, $vz, $C_Y, $C_Y, $C_Y);
    my ($i0x, $i0y, $i0z) = map { POSIX::floor(_cadd($_, $dv)) } ($vx, $vy, $vz);
    my $di = _cdot3($i0x, $i0y, $i0z, $C_X, $C_X, $C_X);
    my ($x0x, $x0y, $x0z) = (_cadd(_csub($vx, $i0x), $di), _cadd(_csub($vy, $i0y), $di), _cadd(_csub($vz, $i0z), $di));
    my ($s1x, $s1y, $s1z) = ($x0x < $x0y ? 0 : 1, $x0y < $x0z ? 0 : 1, $x0z < $x0x ? 0 : 1);
    my ($lx, $ly, $lz) = (1 - $s1z, 1 - $s1x, 1 - $s1y);
    my ($i1x, $i1y, $i1z) = (_cmin($s1x, $lx), _cmin($s1y, $ly), _cmin($s1z, $lz));
    my ($i2x, $i2y, $i2z) = (_cmax($s1x, $lx), _cmax($s1y, $ly), _cmax($s1z, $lz));
    my @corners = ($x0x, $x0y, $x0z,
        _cadd(_csub($x0x, $i1x), $C_X), _cadd(_csub($x0y, $i1y), $C_X), _cadd(_csub($x0z, $i1z), $C_X),
        _cadd(_csub($x0x, $i2x), $C_Y), _cadd(_csub($x0y, $i2y), $C_Y), _cadd(_csub($x0z, $i2z), $C_Y),
        _csub($x0x, 0.5), _csub($x0y, 0.5), _csub($x0z, 0.5));
    my ($ix, $iy, $iz) = map { _cmod289($_) } ($i0x, $i0y, $i0z);
    my @offsets_x = (0, $i1x, $i2x, 1);
    my @offsets_y = (0, $i1y, $i2y, 1);
    my @offsets_z = (0, $i1z, $i2z, 1);
    my @p;
    for my $k (0 .. 3) {
        my $pz = _cpermute(_cadd($iz, $offsets_z[$k]));
        my $py = _cpermute(_cadd(_cadd($pz, $iy), $offsets_y[$k]));
        $p[$k] = _cpermute(_cadd(_cadd($py, $ix), $offsets_x[$k]));
    }
    my (@x, @y, @h);
    for my $k (0 .. 3) {
        my $j = _csub($p[$k], _cmul(49, POSIX::floor(_cmul(_cmul($p[$k], $C_N), $C_N))));
        my $xi = POSIX::floor(_cmul($j, $C_N));
        my $yi = POSIX::floor(_csub($j, _cmul(7, $xi)));
        $x[$k] = _cfma32($xi, $C_NS_X, $C_NS_Y);
        $y[$k] = _cfma32($yi, $C_NS_X, $C_NS_Y);
        $h[$k] = _csub(_csub(1, abs($x[$k])), abs($y[$k]));
    }
    my @b0 = ($x[0], $x[1], $y[0], $y[1]);
    my @b1 = ($x[2], $x[3], $y[2], $y[3]);
    my @s0 = map { _cadd(_cmul(POSIX::floor($_), 2), 1) } @b0;
    my @s1 = map { _cadd(_cmul(POSIX::floor($_), 2), 1) } @b1;
    my @sh = map { $_ > 0 ? 0 : -1 } @h;
    my @gradient = (_cfma32($s0[0], $sh[0], $b0[0]), _cfma32($s0[2], $sh[0], $b0[2]), $h[0],
        _cfma32($s0[1], $sh[1], $b0[1]), _cfma32($s0[3], $sh[1], $b0[3]), $h[1],
        _cfma32($s1[0], $sh[2], $b1[0]), _cfma32($s1[2], $sh[2], $b1[2]), $h[2],
        _cfma32($s1[1], $sh[3], $b1[1]), _cfma32($s1[3], $sh[3], $b1[3]), $h[3]);
    my $sum = 0;
    for my $k (0 .. 3) {
        my $g = $k * 3;
        my ($gx, $gy, $gz) = @gradient[$g .. $g + 2];
        my $norm = _cfma32(-$C_TAYLOR_B, _cdot3($gx, $gy, $gz, $gx, $gy, $gz), $C_TAYLOR_A);
        my ($cx, $cy, $cz) = @corners[$g .. $g + 2];
        my $m = _cmax(_csub($C_M0, _cdot3($cx, $cy, $cz, $cx, $cy, $cz)), 0);
        my $msq = _cmul($m, $m);
        my $term = _cdot3(_cmul($gx, $norm), _cmul($gy, $norm), _cmul($gz, $norm), $cx, $cy, $cz);
        $sum = $k == 0 ? _cmul(_cmul($msq, $msq), $term) : _cfma32(_cmul($msq, $msq), $term, $sum);
    }
    return _cmul(42, $sum);
}
sub _cwrap_float {
    my ($value, $limit) = @_;
    return 0 if $limit <= 0;
    my $result = _cfma32(-POSIX::floor(_cdiv($value, $limit)), $limit, $value);
    return $result < 0 ? _cadd($result, $limit) : $result;
}
sub _cfreq_for_shape {
    my ($base_freq, $width, $height) = @_;
    my $freq = _cmax($base_freq, 1);
    $width = _cmax($width, 1); $height = _cmax($height, 1);
    return ($freq, $freq) if abs(_csub($width, $height)) < _f32(1e-5);
    return ($freq, _cmax(POSIX::floor(_cdiv(_cmul($freq, $width), $height)), 1)) if $height < $width;
    return (_cmax(POSIX::floor(_cdiv(_cmul($freq, $height), $width)), 1), $freq);
}
sub _cvalue_noise_hash {
    my ($cx, $cy, $cz, $seed) = @_;
    my $value = _cfma32($seed, _f32(0.001), _cdot3($cx, $cy, $cz, _f32(12.9898), _f32(78.233), _f32(37.719)));
    return _cfract(_cmul(_csin($value), $C_HASH3));
}
sub _cfade { _cmul(_cmul($_[0], $_[0]), _cfma32(-2, $_[0], 3)) }
sub _clerp { _cfma32(_csub($_[1], $_[0]), $_[2], $_[0]) }
sub _cvalue_noise_3d {
    my ($x, $y, $z, $seed) = @_;
    my ($cx, $cy, $cz) = map { POSIX::floor($_) } ($x, $y, $z);
    my ($tx, $ty, $tz) = (_cfade(_csub($x, $cx)), _cfade(_csub($y, $cy)), _cfade(_csub($z, $cz)));
    my $h = sub { _cvalue_noise_hash($cx + $_[0], $cy + $_[1], $cz + $_[2], $seed) };
    my $x00 = _clerp($h->(0,0,0), $h->(1,0,0), $tx);
    my $x10 = _clerp($h->(0,1,0), $h->(1,1,0), $tx);
    my $x01 = _clerp($h->(0,0,1), $h->(1,0,1), $tx);
    my $x11 = _clerp($h->(0,1,1), $h->(1,1,1), $tx);
    return _clerp(_clerp($x00, $x10, $ty), _clerp($x01, $x11, $ty), $tz);
}
sub _cwrap_unit {
    my $wrapped = _csub($_[0], POSIX::floor($_[0]));
    return $wrapped < 0 ? _cadd($wrapped, 1) : $wrapped;
}
sub _crgb_to_hsv {
    my ($r, $g, $b) = @_;
    my $cmax = _cmax(_cmax($r, $g), $b);
    my $cmin = _cmin(_cmin($r, $g), $b);
    my $delta = _csub($cmax, $cmin);
    my $hue = 0;
    if ($delta > 0) {
        if ($cmax == $r) {
            $hue = _cdiv(_csub($g, $b), $delta);
            $hue = _cadd($hue, 6) if $hue < 0;
        } elsif ($cmax == $g) {
            $hue = _cadd(_cdiv(_csub($b, $r), $delta), 2);
        } else {
            $hue = _cadd(_cdiv(_csub($r, $g), $delta), 4);
        }
        $hue = _cwrap_unit(_cdiv($hue, 6));
    }
    return ($hue, $cmax != 0 ? _cdiv($delta, $cmax) : 0, $cmax);
}
sub _chsv_to_rgb {
    my ($h, $s, $v) = @_;
    my $dh = _cmul($h, 6);
    my $one_minus_s = _csub(1, $s);
    return (_cclamp01(_cmul(_cfma32($s, _cclamp01(_csub(abs(_csub($dh, 3)), 1)), $one_minus_s), $v)),
        _cclamp01(_cmul(_cfma32($s, _cclamp01(_cadd(-abs(_csub($dh, 2)), 2)), $one_minus_s), $v)),
        _cclamp01(_cmul(_cfma32($s, _cclamp01(_cadd(-abs(_csub($dh, 4)), 2)), $one_minus_s), $v)));
}
sub _cadjust_hue {
    my ($r, $g, $b, $amount) = @_;
    my ($h, $s, $v) = _crgb_to_hsv($r, $g, $b);
    return _chsv_to_rgb(_cwrap_unit(_cadd($h, $amount)), _cclamp01($s), _cclamp01($v));
}
sub _cadjust_saturation {
    my ($r, $g, $b, $amount) = @_;
    my ($h, $s, $v) = _crgb_to_hsv($r, $g, $b);
    return _chsv_to_rgb($h, _cclamp01(_cmul($s, $amount)), _cclamp01($v));
}
register('filter/crt', 'crt', sub {
    my ($rt, $compiled) = @_;
    return sub {
        my ($ctx, $out) = @_;
        $rt->begin_pixel($ctx);
        my $u = $ctx->{uniforms};
        my $resolution = $u->{resolution} // $ctx->{resolution};
        my $tile_offset = $u->{tileOffset} // [0,0];
        my $render_scale = $u->{renderScale} // 1;
        my $alpha = _cclamp01($u->{alpha} // 0);
        my $rs = _cmax($render_scale, 1);
        my $full_res = $u->{fullResolution} // [0,0];
        $full_res = $resolution unless $full_res->[0] > 0;
        my $width = _cmax(_cdiv($full_res->[0], $rs), 1);
        my $height = _cmax(_cdiv($full_res->[1], $rs), 1);
        my ($time, $speed, $seed) = ($u->{time} // $ctx->{time}, $u->{speed} // 1, $u->{seed} // $ctx->{seed});
        my ($gx, $gy) = map { _cint32($_) } @{$ctx->{frag_coord}}[0,1];
        my $fetch = sub { $rt->texel_fetch($ctx->texture_binding('inputTex'), [map {_cint32($_)} @_]) };
        my ($base_r, $base_g, $base_b, $base_a) = @{$fetch->($gx,$gy)};
        if ($alpha == 0) { @$out = ($base_r, $base_g, $base_b, $base_a); return; }
        my @freq = _cfreq_for_shape(2, $width, $height);
        my ($freq_x, $freq_y) = (_cmax($freq[1],1), _cmax($freq[0],1));
        my $z_base = _cmul(_ccos_turns($time), $speed);
        my $s = _cmul($seed,73);
        my ($base_seed_x, $base_seed_y, $base_seed_z) = (_cadd(17,$s), _cfma32($s,_f32(1.1),29), _cfma32($s,_f32(0.7),47));
        my ($time_seed_x, $time_seed_y, $time_seed_z) = (_cadd($base_seed_x,54), _cadd($base_seed_y,82), _cadd($base_seed_z,124));
        my $animated_simplex_value = sub {
            my ($a,$b)=@_;
            my $base_noise = _csimplex_noise(_cadd($a,$base_seed_x),_cadd($b,$base_seed_y),_cadd($z_base,$base_seed_z));
            my $value = _cclamp01(_cfma32($base_noise,0.5,0.5));
            if ($speed != 0 && $time != 0) {
                my $time_noise = _csimplex_noise(_cadd($a,$time_seed_x),_cadd($b,$time_seed_y),$time_seed_z);
                my $time_value = _cclamp01(_cfma32($time_noise,0.5,0.5));
                $value = _cclamp01(_cperiodic_value(_cmul(_cperiodic_value($time,$time_value),$speed),$value));
            }
            return _cclamp01($value);
        };
        my $aspect = _cdiv($width,$height);
        my $max_radius = _clength2(_cmul($aspect,0.5),0.5);
        my $lens_offsets = sub {
            my ($sample_x,$sample_y)=@_;
            my ($wx,$wy)=(_cwrap_float($sample_x,$width),_cwrap_float($sample_y,$height));
            my $noise = $animated_simplex_value->(_cmul(_cdiv($wx,$width),$freq_x),_cmul(_cdiv($wy,$height),$freq_y));
            my $dx = abs(_csub(_cdiv(_cadd($wx,0.5),$width),0.5));
            my $dy = abs(_csub(_cdiv(_cadd($wy,0.5),$height),0.5));
            my $mask=0;
            if ($max_radius > 0) {
                my $normalized = _cclamp01(_cdiv(_clength2(_cmul($dx,$aspect),$dy),$max_radius));
                my $masked = _csqrt($normalized);
                my $squared = _cmul($masked,$masked);
                $mask = _cmul(_cmul($squared,$squared),$masked);
            }
            my $distortion = _cmul(_cfma32($noise,2,-1),$mask);
            return (_cmul(_cmul(_ccos_turns($distortion),0.0625),$width),_cmul(_cmul(_csin_turns($distortion),0.0625),$height));
        };
        my $time_scaled = _cmul(_cmul($time,$speed),_f32(0.1));
        my $noise_seed = _cfma32($seed,31,_f32(19.37));
        my $scan_base0 = _cvalue_noise_3d(0,0,$time_scaled,$noise_seed);
        my $scan_base1 = _cvalue_noise_3d(1,0,$time_scaled,$noise_seed);
        my $scan_row = sub { POSIX::trunc(POSIX::floor(_cdiv($_[0],2.5))) % 2 == 0 ? $scan_base0 : $scan_base1 };
        my $sample_scanline = sub {
            my ($sample_x,$sample_y)=@_;
            my $wx = _cfma32(-POSIX::floor(_cdiv($sample_x,$width)),$width,$sample_x);
            my $wy = _cfma32(-POSIX::floor(_cdiv($sample_y,$height)),$height,$sample_y);
            $wx = _cadd($wx,$width) if $wx < 0;
            $wy = _cadd($wy,$height) if $wy < 0;
            ($wx,$wy)=(_cclamp($wx,0,_csub($width,1)),_cclamp($wy,0,_csub($height,1)));
            my $y0 = POSIX::floor($wy);
            my $y1 = _cmin(_cadd($y0,1),_csub($height,1));
            my ($xf,$yf)=(_cclamp01(_csub($wx,POSIX::floor($wx))),_cclamp01(_csub($wy,$y0)));
            my ($top,$bottom)=($scan_row->($y0),$scan_row->($y1));
            return _cmix(_cmix($top,$top,$xf),_cmix($bottom,$bottom,$xf),$yf);
        };
        my $seed_hash = sub {
            my $turns = _cfma32($seed,_f32(73*$C_INV_TAU),_f32(_f32(17+_f32($_[0]))*$C_INV_TAU));
            return _cfract(_cmul(_cquadrant_sine(_cquadrant_of_turns($turns)),$C_HASH));
        };
        my $displacement_base = _cfma32($seed_hash->(0.37),_f32(0.00625),_f32(0.0125));
        my $displacement_pixels = _cmul(_cmul($displacement_base,$width),$seed_hash->(0.73));
        my $hue_shift = _cfma32($seed_hash->(1.91),0.25,-0.125);
        my $vignette_alpha = _cmul($seed_hash->(3.17),_f32(0.175));
        my $blend_cosine = sub {
            my ($a,$b,$value)=@_;
            my $c = _ccos_half_turns(_cclamp01($value));
            my $weight = _cmul(_csub(1,$c),0.5);
            return _cfma32($b,$weight,_cmul($a,_cfma32(0.5,$c,0.5)));
        };
        my $blend_scan = sub { _cmix($_[0],_cmul(_cadd($_[0],$_[1]),$_[1]),0.5) };
        my ($x,$y)=(_cdiv(_cadd($gx,$tile_offset->[0]),$rs),_cdiv(_cadd($gy,$tile_offset->[1]),$rs));
        my ($ox,$oy)=$lens_offsets->($x,$y);
        my $scan_value = $sample_scanline->(_cadd($x,$ox),_cadd($y,$oy));
        my @green = map {_cclamp01($blend_scan->($_,$scan_value))} ($base_r,$base_g,$base_b);
        my ($dx,$dy)=(_cdiv(_csub($x,_cmul($width,0.5)),$width),_cdiv(_csub($y,_cmul($height,0.5)),$height));
        my $singularity = _clength2($dx,$dy);
        my $aber_mask = _cmul(_cmul($singularity,$singularity),$singularity);
        my $gradient_x = _cclamp01(_cdiv($x,_csub($width,1)));
        my $red_x = _cmix(_cmin(_cadd($x,$displacement_pixels),_csub($width,1)),$x,$gradient_x);
        my $red_sample_x = $blend_cosine->($x,$red_x,$aber_mask);
        my $red_sample = $fetch->(POSIX::trunc(_csub(_cmul($red_sample_x,$render_scale),$tile_offset->[0])),$gy);
        ($ox,$oy)=$lens_offsets->($red_sample_x,$y);
        my $red_scan = $sample_scanline->(_cadd($red_sample_x,$ox),_cadd($y,$oy));
        my $blue_x = _cmix($x,_cmax(_csub($x,$displacement_pixels),0),$gradient_x);
        my $blue_sample_x = $blend_cosine->($x,$blue_x,$aber_mask);
        my $blue_sample = $fetch->(POSIX::trunc(_csub(_cmul($blue_sample_x,$render_scale),$tile_offset->[0])),$gy);
        ($ox,$oy)=$lens_offsets->($blue_sample_x,$y);
        my $blue_scan = $sample_scanline->(_cadd($blue_sample_x,$ox),_cadd($y,$oy));
        my @red = _cadjust_hue((map {$blend_scan->($_,$red_scan)} @$red_sample[0..2]),$hue_shift);
        @green = _cadjust_hue(@green,$hue_shift);
        my @blue = _cadjust_hue((map {$blend_scan->($_,$blue_scan)} @$blue_sample[0..2]),$hue_shift);
        my @color = _cadjust_hue($red[0],$green[1],$blue[2],-$hue_shift);
        @color = _cadjust_saturation(@color,1.125);
        @color = map {_cmix($_,_cmix($_,0,$singularity),_cclamp01($vignette_alpha))} @color;
        my $local_mean = _cmul(_cadd(_cadd($color[0],$color[1]),$color[2]),$C_INV_THREE);
        my @base=($base_r,$base_g,$base_b);
        for my $channel (0..2) {
            my $normalized = _cclamp01(_cfma32(_csub($color[$channel],$local_mean),1.25,$local_mean));
            my $quantized = _cdiv(POSIX::floor(_cfma32(_cclamp01($normalized),255,0.5)),255);
            $out->[$channel] = _cmix($base[$channel],$quantized,$alpha);
        }
        $out->[3]=$base_a;
    };
});

# ---- filter/snow: TV static (full reimplementation) ----

my @TIME_SEED_OFFSETS = (_f32(97.0),  _f32(57.0), _f32(131.0));
my @STATIC_SEED       = (_f32(37.0),  _f32(17.0), _f32(53.0));
my @LIMITER_SEED      = (_f32(113.0), _f32(71.0), _f32(193.0));

sub _sadd { _f32($_[0] + $_[1]) }
sub _ssub { _f32($_[0] - $_[1]) }
sub _smul { _f32($_[0] * $_[1]) }
sub _sdiv { _f32($_[0] / $_[1]) }
sub _sfract { _f32($_[0] - POSIX::floor($_[0])) }
sub _sclamp01 { $_[0] <= 0 ? 0.0 : $_[0] >= 1 ? 1.0 : $_[0] }

sub _ssine {
    my $turns = _f32($_[0] * $INV_TAU);
    my $phase = $turns - POSIX::floor($turns);
    return _f32(sin($phase * $TAU32));
}

sub _speriodic { _smul(_sadd(_ssine(_smul(_ssub($_[0], $_[1]), $TAU32)), 1.0), 0.5) }

sub _snow_hash {
    my ($x, $y, $z) = @_;
    my $sx = _sfract(_smul($x, _f32(0.1031)));
    my $sy = _sfract(_smul($y, _f32(0.1031)));
    my $sz = _sfract(_smul($z, _f32(0.1031)));
    my $dot = _cfma32($sz, _sadd($sx, _f32(33.33)),
        _cfma32($sy, _sadd($sz, _f32(33.33)), _smul($sx, _sadd($sy, _f32(33.33)))));
    return _sclamp01(_sfract(_smul(_sadd(_sadd($sx, $sy), 2 * $dot), _sadd($sz, $dot))));
}

sub _snow_noise {
    my ($x, $y, $time, $speed, $seed) = @_;
    my $angle        = _smul($time, $TAU32);
    my $cosine_value = _f32(cos($angle));
    my $z_base = _smul($cosine_value, $speed);
    my $base_value = _snow_hash(_sadd($x, $seed->[0]), _sadd($y, $seed->[1]), _sadd($z_base, $seed->[2]));
    return $base_value if $speed == 0 || $time == 0;

    my $tsx = _sadd($seed->[0], $TIME_SEED_OFFSETS[0]);
    my $tsy = _sadd($seed->[1], $TIME_SEED_OFFSETS[1]);
    my $tsz = _sadd($seed->[2], $TIME_SEED_OFFSETS[2]);
    my $time_value  = _snow_hash(_sadd($x, $tsx), _sadd($y, $tsy), _sadd(1.0, $tsz));
    my $scaled_time = _smul(_speriodic($time, $time_value), $speed);
    return _sclamp01(_speriodic($scaled_time, $base_value));
}

register('filter/snow', 'snow', sub {
    my ($rt, $compiled) = @_;
    return sub {
        my ($ctx, $out) = @_;
        my $x = 0.0 + $ctx->{frag_coord}[0];
        my $y = 0.0 + $ctx->{frag_coord}[1];
        $rt->begin_pixel($ctx);
        my $source = $rt->texel_fetch($ctx->texture_binding('inputTex'), [_cint32($x), _cint32($y)]);
        my $alpha = _sclamp01(defined $ctx->{uniforms}{alpha} ? $ctx->{uniforms}{alpha} : 0.0);
        if ($alpha == 0) {
            @{$out}[0 .. 3] = @{$source}[0 .. 3];
            return;
        }
        my $pause = defined $ctx->{uniforms}{pause} ? $ctx->{uniforms}{pause} : 0;
        my $time  = $pause > 0.5 ? 0.0
            : (defined $ctx->{uniforms}{time} ? $ctx->{uniforms}{time} : $ctx->{time});
        my $speed         = _f32(100.0);
        my $static_value  = _snow_noise($x, $y, $time, $speed, \@STATIC_SEED);
        my $limiter_value = _snow_noise($x, $y, $time, $speed, \@LIMITER_SEED);
        my $density_u = defined $ctx->{uniforms}{density} ? $ctx->{uniforms}{density} : 0.0;
        my $density   = _smul($density_u, _f32(0.01));
        $density = _f32(0.0001) if $density < _f32(0.0001);
        my $exponent = _sdiv(_ssub(1.0, $density), $density);
        my $lim      = _cmin($limiter_value, _f32(0.99));
        my $limiter_mask = _smul(_f32($lim**$exponent), $alpha);
        my $inverse_mask = _ssub(1.0, $limiter_mask);
        $out->[$_] = _f32($source->[$_] * $inverse_mask + $static_value * $limiter_mask) for 0 .. 2;
        $out->[3] = $source->[3];
    };
});

# ---- filter/median: packed unsigned ordering, direct CPU adapter ----

sub _mfloat_bits { unpack('L<', pack('f<', $_[0])) }
sub _mfloat_to_half {
    my ($value) = @_;
    return 0x7e00 if POSIX::isnan($value);
    return $value < 0 ? 0xfc00 : 0x7c00 unless POSIX::isfinite($value);
    my $bits = _mfloat_bits($value);
    my $sign = ($bits >> 16) & 0x8000;
    my $exponent = (($bits >> 23) & 0xff) - 127 + 15;
    my $fraction = $bits & 0x7fffff;
    if ($exponent <= 0) {
        return $sign if $exponent < -10;
        $fraction = ($fraction | 0x800000) >> (1 - $exponent);
        return $sign | (($fraction + 0x1000) >> 13);
    }
    return $sign | 0x7c00 if $exponent >= 31;
    $fraction += 0x1000;
    if ($fraction & 0x800000) {
        $fraction = 0;
        ++$exponent;
        return $sign | 0x7c00 if $exponent >= 31;
    }
    return $sign | ($exponent << 10) | ($fraction >> 13);
}
sub _mhalf_to_float {
    my ($value) = @_;
    my $sign = $value & 0x8000 ? -1 : 1;
    my $exponent = ($value >> 10) & 0x1f;
    my $fraction = $value & 0x3ff;
    if ($exponent == 0) {
        return POSIX::copysign(0.0, $sign) if $fraction == 0;
        return $sign * 2**-14 * $fraction / 1024;
    }
    return $fraction ? POSIX::nan(0) : POSIX::copysign(POSIX::HUGE_VAL(), $sign) if $exponent == 0x1f;
    return $sign * 2**($exponent - 15) * (1 + $fraction / 1024);
}
register('filter/median', 'median', sub {
    my ($rt, $compiled) = @_;
    my @brightness = (0) x 49;
    my @red_green = (0) x 49;
    my @blue = (0) x 49;
    my $swap = sub {
        my ($left, $right) = @_;
        ($brightness[$left], $brightness[$right]) = ($brightness[$right], $brightness[$left]);
        ($red_green[$left], $red_green[$right]) = ($red_green[$right], $red_green[$left]);
        ($blue[$left], $blue[$right]) = ($blue[$right], $blue[$left]);
    };
    return sub {
        my ($ctx, $out) = @_;
        $rt->begin_pixel($ctx);
        my $surface = $ctx->texture_binding('inputTex');
        my $data = $surface->data;
        my ($width, $height) = ($surface->width, $surface->height);
        my $radius = _cint32($ctx->{uniforms}{RADIUS} // 0);
        my ($center_x, $center_y) = map { _cint32($_) } @{$ctx->{frag_coord}}[0, 1];
        my $center_offset = (($height - 1 - $center_y) * $width + $center_x) * 4;
        # CPU Surface stores Float32Array lanes; target Surface callers can
        # supply raw doubles, so snap them at the same input storage boundary.
        my ($original_red, $original_green, $original_blue, $original_alpha) =
            map { _f32($_) } @{$data}[$center_offset .. $center_offset + 3];
        my $index = 0;
        for my $y (-$radius .. $radius) {
            my $sample_y = _cmin(_cmax($center_y + $y, 0), $height - 1);
            my $sample_row = $height - 1 - $sample_y;
            for my $x (-$radius .. $radius) {
                my $sample_x = _cmin(_cmax($center_x + $x, 0), $width - 1);
                my $offset = ($sample_row * $width + $sample_x) * 4;
                my ($red, $green, $sample_blue) = map { _f32($_) } @{$data}[$offset .. $offset + 2];
                my $luminance = _cadd(_cadd(_cmul($red, 0.2126), _cmul($green, 0.7152)), _cmul($sample_blue, 0.0722));
                my $packed_red = _mfloat_to_half($red);
                my $packed_green = _mfloat_to_half($green);
                $brightness[$index] = _mfloat_bits($luminance);
                $red_green[$index] = ($packed_red << 16) | $packed_green;
                $blue[$index] = _mfloat_to_half($sample_blue);
                ++$index;
            }
        }
        my $count = $index;
        my $median_index = ($count - 1) >> 1;
        my $left = 0;
        my $right = $count - 1;
        while ($left < $right) {
            my ($pivot_brightness, $pivot_red_green, $pivot_blue) =
                ($brightness[$median_index], $red_green[$median_index], $blue[$median_index]);
            my ($scan_left, $scan_right) = ($left, $right);
            my $less_pivot = sub {
                my ($record) = @_;
                return $brightness[$record] != $pivot_brightness ? $brightness[$record] < $pivot_brightness
                    : $red_green[$record] != $pivot_red_green ? $red_green[$record] < $pivot_red_green
                    : $blue[$record] < $pivot_blue;
            };
            my $pivot_less = sub {
                my ($record) = @_;
                return $pivot_brightness != $brightness[$record] ? $pivot_brightness < $brightness[$record]
                    : $pivot_red_green != $red_green[$record] ? $pivot_red_green < $red_green[$record]
                    : $pivot_blue < $blue[$record];
            };
            while ($scan_left <= $scan_right) {
                ++$scan_left while $less_pivot->($scan_left);
                --$scan_right while $pivot_less->($scan_right);
                if ($scan_left <= $scan_right) {
                    $swap->($scan_left, $scan_right);
                    ++$scan_left;
                    --$scan_right;
                }
            }
            $left = $scan_left if $scan_right < $median_index;
            $right = $scan_right if $median_index < $scan_left;
        }
        my $packed = $red_green[$median_index];
        my $median_red = _mhalf_to_float($packed >> 16);
        my $median_green = _mhalf_to_float($packed & 0xffff);
        my $median_blue = _mhalf_to_float($blue[$median_index]);
        my $maximum_difference = _cmax(_cmax(abs($original_red - $median_red), abs($original_green - $median_green)),
                                       abs($original_blue - $median_blue));
        my $threshold = $ctx->{uniforms}{threshold} // 0;
        my $replace = $threshold <= 0 || $maximum_difference >= $threshold / 100;
        @{$out}[0 .. 3] = ($replace ? ($median_red, $median_green, $median_blue)
                                   : ($original_red, $original_green, $original_blue), $original_alpha);
    };
});

# ---- filter/palette: cosine palette (full reimplementation) ----

sub _to_int32 {
    my $n = int($_[0]) & 0xFFFFFFFF;
    return $n >= 0x80000000 ? $n - 4294967296 : $n;
}

sub _pclamp01 { $_[0] < 0 ? 0.0 : $_[0] > 1 ? 1.0 : $_[0] }
sub _pmix { $_[0] * (1.0 - $_[2]) + $_[1] * $_[2] }

sub _hsv_to_rgb {
    my ($h, $s, $v) = @_;
    my $c  = $v * $s;
    my $hp = $h * 6.0;
    my $x  = $c * (1.0 - abs(($hp - 2.0 * POSIX::floor($hp / 2.0)) - 1.0));
    my $m  = $v - $c;
    my ($r, $g, $b);
    if    ($hp < 1.0) { ($r, $g, $b) = ($c + $m, $x + $m, $m) }
    elsif ($hp < 2.0) { ($r, $g, $b) = ($x + $m, $c + $m, $m) }
    elsif ($hp < 3.0) { ($r, $g, $b) = ($m, $c + $m, $x + $m) }
    elsif ($hp < 4.0) { ($r, $g, $b) = ($m, $x + $m, $c + $m) }
    elsif ($hp < 5.0) { ($r, $g, $b) = ($x + $m, $m, $c + $m) }
    else              { ($r, $g, $b) = ($c + $m, $m, $x + $m) }
    return (_f32($r), _f32($g), _f32($b));
}

sub _linear_to_srgb {
    my ($value) = @_;
    return $value * 12.92 if $value <= 0.0031308;
    return 1.055 * ($value**(1.0 / 2.4)) - 0.055;
}

sub _oklab_to_rgb {
    my ($lab_l, $lab_a, $lab_b) = @_;
    my $L = $lab_l;
    my $a = $lab_a * -0.509 + 0.276;
    my $b = $lab_b * -0.509 + 0.198;
    my $l1 = $L + 0.3963377774 * $a + 0.2158037573 * $b;
    my $m1 = $L - 0.1055613458 * $a - 0.0638541728 * $b;
    my $s1 = $L - 0.0894841775 * $a - 1.291485548 * $b;
    my $l = $l1**3;
    my $m = $m1**3;
    my $s = $s1**3;
    my $r  = _pclamp01(_linear_to_srgb(4.0767416621 * $l - 3.3077115913 * $m + 0.2309699292 * $s));
    my $g  = _pclamp01(_linear_to_srgb(-1.2684380046 * $l + 2.6097574011 * $m - 0.3413193965 * $s));
    my $bo = _pclamp01(_linear_to_srgb(-0.0041960863 * $l - 0.7034186147 * $m + 1.707614701 * $s));
    return (_f32($r), _f32($g), _f32($bo));
}

# Mirror GlslCpuRuntime#texture: uv against the input texture's own size,
# bilinear with flipped v when 'linear', else nearest-bottom-left.
sub _sample_input {
    my ($surface, $fx, $fy) = @_;
    my $u = $fx / $surface->width;
    my $v = $fy / $surface->height;
    if (($surface->filter || 'nearest') eq 'linear') {
        return sample_bilinear($surface, $u, 1.0 - $v);
    }
    return sample_nearest_bottom_left($surface, $u, $v);
}

register('filter/palette', 'palette', sub {
    my ($rt, $compiled) = @_;
    return sub {
        my ($ctx, $out) = @_;
        my $surface = $ctx->texture_binding('inputTex');
        my $inp = _sample_input($surface, 0.0 + $ctx->{frag_coord}[0], 0.0 + $ctx->{frag_coord}[1]);
        my $table = \@Math::Fractal::Noisemaker::PaletteData::PALETTE_DATA;

        my $palette_index = _to_int32(defined $ctx->{uniforms}{paletteIndex} ? $ctx->{uniforms}{paletteIndex} : 0);
        if ($palette_index <= 0 || $palette_index > @$table) {
            $out->[$_] = _f32($inp->[$_]) for 0 .. 3;
            return;
        }
        my $entry = $table->[ $palette_index - 1 ];
        my $lum = $inp->[0] * 0.299 + $inp->[1] * 0.587 + $inp->[2] * 0.114;
        my $repeat   = defined $ctx->{uniforms}{repeat}   ? $ctx->{uniforms}{repeat}   : 0;
        my $offset   = defined $ctx->{uniforms}{offset}   ? $ctx->{uniforms}{offset}   : 0.0;
        my $rotation = defined $ctx->{uniforms}{rotation} ? $ctx->{uniforms}{rotation} : 0;
        my $time     = defined $ctx->{uniforms}{time}     ? $ctx->{uniforms}{time}     : $ctx->{time};
        my $t = $lum * $repeat + $offset * 0.01;
        if    ($rotation == -1) { $t += $time }
        elsif ($rotation == 1)  { $t -= $time }

        my @color = (0.0, 0.0, 0.0);
        for my $channel (0 .. 2) {
            my $raw = $entry->[ 8 + $channel ]
                + $entry->[$channel] * cos($TAU * ($entry->[ 4 + $channel ] * $t + $entry->[ 12 + $channel ]));
            $color[$channel] = _f32(_pclamp01($raw));
        }
        my $mode = _to_int32($entry->[3]);
        if    ($mode == 1) { @color = _hsv_to_rgb(@color) }
        elsif ($mode == 2) { @color = _oklab_to_rgb(@color) }

        my $alpha = defined $ctx->{uniforms}{alpha} ? $ctx->{uniforms}{alpha} : 0.0;
        $out->[$_] = _f32(_pmix($inp->[$_], $color[$_], $alpha)) for 0 .. 2;
        $out->[3] = _f32($inp->[3]);
    };
});

# ---- classicNoisedeck/fractal: canonical CPU precision adapter ----

sub _fmap {
    my ($v, $lo, $hi, $a, $b) = @_;
    return $a + ($b - $a) * ($v - $lo) / ($hi - $lo);
}

sub _fmap32 {
    my ($v, $lo, $hi, $a, $b) = @_;
    return _f32($a + _f32($b - $a) * (($v - $lo) * _f32(1 / _f32($hi - $lo))));
}

sub _frotate {
    my ($x, $y, $rotation, $aspect) = @_;
    my $angle = _fmap($rotation, 0, 360, 0, 2) * 3.14159265359;
    my ($px, $py) = ($x - 0.5 * $aspect, $y - 0.5);
    my ($cs, $sn) = (cos($angle), sin($angle));
    return ($cs * $px + $sn * $py + 0.5 * $aspect,
        -$sn * $px + $cs * $py + 0.5);
}

sub _fjulia {
    my ($x, $y, $b, $aspect) = @_;
    ($x, $y, $aspect) = map { _f32($_) } ($x, $y, $aspect);
    my $zoom = _fmap32($b->{zoomAmt}, 0, 100, 2, 0.5);
    my $speedy = _fmap32($b->{speed}, 0, 100, 0, 1);
    my $speed = _f32(_f32(_f32($speedy * 0.05) * _f32(1 - $speedy))
        + _f32(_f32($speedy * 0.125) * $speedy));
    my $phase = _f32(_f32($b->{time}) * _f32(6.28318530718));
    my $cx = _f32(sin($phase) * $speed + _fmap32($b->{offsetX}, -100, 100, -0.5, 0.5));
    my $cy = _f32(cos($phase) * $speed + _fmap32($b->{offsetY}, -100, 100, -1, 1));
    my $angle = _f32(_fmap32(_f32($b->{rotation}), 0, 360, 0, 2)
        * _f32(3.1415929794311523));
    my ($px, $py) = (_f32($x - _f32(0.5 * $aspect)), _f32($y - 0.5));
    my ($cs, $sn) = (_f32(cos($angle)), _f32(sin($angle)));
    # Preserve the authority's fused product/add order and one final zoom rounding.
    $x = _f32($sn * $py + _f32($cs * $px));
    $y = _f32($cs * $py + _f32(-$sn * $px));
    $x = _f32($x * $zoom + _fmap32($b->{centerX}, -100, 100, 1, -1));
    $y = _f32($y * $zoom + _fmap32($b->{centerY}, -100, 100, 1, -1));
    my $count = $b->{iterations} * 2;
    my $iteration = 0;
    for (my $index = 0; $index < $count; $index++) {
        $iteration = $index;
        my $nx = _f32(_f32($x * $x + $cx) - $y * $y);
        my $ny = _f32($y * $x + $x * $y + $cy);
        last if _f32($nx * $nx + $ny * $ny) > 4;
        ($x, $y) = ($nx, $ny);
    }
    return 1 if $count - $iteration < int($b->{cutoff});
    return $b->{mode} == 0 ? _f32($iteration / $count)
        : _f32(sqrt(_f32($x * $x + $y * $y)));
}

sub _fnewton {
    my ($x, $y, $b, $aspect) = @_;
    ($x, $y) = _frotate($x, $y, $b->{rotation} + 90, $aspect);
    $x = ($x - 0.5 * $aspect) * _fmap($b->{zoomAmt}, 0, 130, 1, 0.01) + $b->{centerY} * 0.01;
    $y = ($y - 0.5) * _fmap($b->{zoomAmt}, 0, 130, 1, 0.01) + $b->{centerX} * 0.01;
    my $speed = _fmap($b->{speed}, 0, 100, 0, 1);
    my $ox = _fmap($b->{offsetX}, -100, 100, -0.25, 0.25);
    my $oy = _fmap($b->{offsetY}, -100, 100, -0.25, 0.25);
    my $iteration = 0;
    for (my $index = 0; $index < $b->{iterations}; $index++) {
        my $fx = $x * $x * $x - 3 * $x * $y * $y - 1;
        my $fy = 3 * $x * $x * $y - $y * $y * $y;
        my $fpx = 3 * $x * $x - 3 * $y * $y;
        my $fpy = 6 * $x * $y;
        my $den = $fpx * $fpx + $fpy * $fpy;
        # JS division at a singular point propagates NaN through the orbit.
        my $tx = $den == 0 ? POSIX::nan(0) : ($fx * $fpx + $fy * $fpy) / $den;
        my $ty = $den == 0 ? POSIX::nan(0) : ($fy * $fpx - $fx * $fpy) / $den;
        $tx += sin($b->{time} * 6.28318530718) * 0.1 * $speed + $ox;
        $ty += cos($b->{time} * 6.28318530718) * 0.1 * $speed + $oy;
        last if POSIX::hypot($tx, $ty) < 0.001;
        $x -= $tx;
        $y -= $ty;
        $iteration++;
    }
    return $b->{mode} == 0 ? $iteration / $b->{iterations} : POSIX::hypot($x, $y);
}

sub _fmandelbrot {
    my ($x, $y, $b, $aspect) = @_;
    my $zoom = _fmap($b->{zoomAmt}, 0, 100, 2, 0.5);
    my $speedy = _fmap($b->{speed}, 0, 100, 0, 1);
    my $speed = _pmix($speedy * 0.05, $speedy * 0.125, $speedy);
    ($x, $y) = _frotate($x, $y, $b->{rotation}, $aspect);
    $y = $y * 2 - 1;
    $x = $x * 2 - $aspect;
    my $cx = $zoom * $x - ($b->{centerX} + 50) * 0.01;
    my $cy = $zoom * $y - $b->{centerY} * 0.01;
    $x = sin($b->{time} * 6.28318530718) * $speed;
    $y = cos($b->{time} * 6.28318530718) * $speed;
    my $iteration = 0;
    for (; $iteration < $b->{iterations}; $iteration++) {
        my $nx = $x * $x - $y * $y + $cx;
        my $ny = 2 * $x * $y + $cy;
        ($x, $y) = ($nx, $ny);
        last if $x * $x + $y * $y > 16;
    }
    return 1 if $iteration == $b->{iterations};
    return $b->{mode} == 0 ? $iteration / $b->{iterations}
        : POSIX::hypot($x, $y) / $b->{iterations};
}

sub _fhsv32 {
    my ($h, $s, $v) = @_;
    $h = _sfract($h);
    my $c = _f32($v * $s);
    my $base = _f32($h * 6);
    my $mod = _f32($base - _f32(2 * POSIX::floor(_f32($base / 2))));
    my $x = _f32($c * _f32(1 - abs($mod - 1)));
    my $m = _f32($v - $c);
    my @color = $h < 1/6 ? ($c, $x, 0) : $h < 2/6 ? ($x, $c, 0)
        : $h < 3/6 ? (0, $c, $x) : $h < 4/6 ? (0, $x, $c)
        : $h < 5/6 ? ($x, 0, $c) : ($c, 0, $x);
    return map { _f32($_ + $m) } @color;
}

sub _fpalette32 {
    my ($t, $b) = @_;
    my @color;
    for my $ch (0 .. 2) {
        my $inner = _f32($b->{paletteFreq}[$ch] * $t + $b->{palettePhase}[$ch]);
        my $cos = _f32(cos(_f32($inner * _f32(6.28318))));
        $color[$ch] = _f32($b->{paletteAmp}[$ch] * $cos + $b->{paletteOffset}[$ch]);
    }
    return _fhsv32(@color) if $b->{paletteMode} == 1;
    if ($b->{paletteMode} == 2) {
        @color = map { _f32($b->{paletteOffset}[$_] + $b->{paletteAmp}[$_]
            * cos(6.28318 * ($b->{paletteFreq}[$_] * $t + $b->{palettePhase}[$_]))) } 0 .. 2;
        my ($L, $a, $b2) = ($color[0], $color[1] * -0.509 + 0.276, $color[2] * -0.509 + 0.198);
        my $l = $L + 0.3963377774 * $a + 0.2158037573 * $b2;
        my $m = $L - 0.1055613458 * $a - 0.0638541728 * $b2;
        my $s = $L - 0.0894841775 * $a - 1.291485548 * $b2;
        ($l, $m, $s) = ($l * $l * $l, $m * $m * $m, $s * $s * $s);
        @color = map { _f32(_linear_to_srgb($_)) } (
            4.0767245293 * $l - 3.3072168827 * $m + 0.2307590544 * $s,
            -1.2681437731 * $l + 2.6093323231 * $m - 0.341134429 * $s,
            -0.0041119885 * $l - 0.7034763098 * $m + 1.7068625689 * $s);
    }
    return @color;
}

register('classicNoisedeck/fractal', 'fractal', sub {
    return sub {
        my ($ctx, $out) = @_;
        my $b = $ctx->{uniforms};
        my $aspect = $b->{fullResolution}[0] / $b->{fullResolution}[1];
        my $x = ($ctx->{frag_coord}[0] + $b->{tileOffset}[0]) / $b->{fullResolution}[1];
        my $y = ($ctx->{frag_coord}[1] + $b->{tileOffset}[1]) / $b->{fullResolution}[1];
        my $d = $b->{type} == 0 ? _fjulia($x, $y, $b, $aspect)
            : $b->{type} == 1 ? _fnewton($x, $y, $b, $aspect) : _fmandelbrot($x, $y, $b, $aspect);
        if ($d == 1) {
            @{$out}[0 .. 2] = @{$b->{bgColor}}[0 .. 2];
            $out->[3] = _f32(_f32($b->{bgAlpha}) * _f32(0.01));
            return;
        }
        $d = _f32($d - $b->{time}) if $b->{cyclePalette} == -1;
        $d = _f32($d + $b->{time}) if $b->{cyclePalette} == 1;
        $d = _sfract(_f32($d * _f32($b->{repeatPalette})
            + _f32(_f32($b->{rotatePalette}) * _f32(0.01))));
        if ($b->{levels} > 0) {
            my $levels = _f32(_f32($b->{levels}) + 1);
            $d = _f32(POSIX::floor(_f32($d * $levels)) / $levels);
        }
        my @color = $b->{colorMode} == 0 ? ((_sfract($d)) x 3)
            : $b->{colorMode} == 4 ? _fpalette32($d, $b)
            : $b->{colorMode} == 6 ? _fhsv32(_f32($d * _f32(_f32($b->{hueRange}) * _f32(0.01))), 1, 1)
            : (0, 0, 1);
        @{$out}[0 .. 2] = map { _f32($_) } @color;
        $out->[3] = 1;
    };
});

1;
