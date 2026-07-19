package Math::Fractal::Noisemaker::Adapters;

# CPU adapter registry — the reference engine renders a handful of effects
# through hand-written CPU adapters (canonicalAdapterFactories) instead of
# the transpiled GLSL kernel. For byte-parity we run the same adapters:
#
#   filter/crt:crt        — same kernel, `sin` replaced by range-reduced
#                           metalSine (large-argument precision).
#   filter/snow:snow      — full reimplementation (TV static), bit-faithful
#                           to snow.js's exact f32-rounding points.
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

# ---- filter/crt: range-reduced sine ----

sub _metal_sine {
    my ($value) = @_;
    my $turns = _f32($value * $INV_TAU);
    my $phase = $turns - POSIX::floor($turns);
    return _f32(sin($phase * $TAU32));
}

sub _crt_sin {
    my ($v) = @_;
    return _metal_sine($v) unless ref $v;
    return [map { _metal_sine($_) } @$v];
}

register('filter/crt', 'crt', sub {
    my ($rt, $compiled) = @_;
    my $base = $compiled->{kernel};
    return sub {
        my ($ctx, $out) = @_;
        my $prev = $rt->{stdlib_override};
        $rt->{stdlib_override} = { %$prev, sin => \&_crt_sin };
        my $ok = eval { $base->($ctx, $out); 1 };
        $rt->{stdlib_override} = $prev;
        die $@ unless $ok;
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
    # `sx * add(...)` and `sz * add(...)` are RAW float64 products in the JS
    # source; only mul(...) and the two outer F32(...) wraps round. Preserve
    # that grouping exactly.
    my $inner = _f32($sx * _sadd($sy, _f32(33.33)) + _smul($sy, _sadd($sz, _f32(33.33))));
    my $dot   = _f32($inner + $sz * _sadd($sx, _f32(33.33)));
    my $shifted_xy = _f32($sx + $sy + _f32(2.0 * $dot));
    return _sclamp01(_sfract(_f32($shifted_xy * _sadd($sz, $dot))));
}

sub _snow_noise {
    my ($x, $y, $time, $speed, $seed) = @_;
    my $angle        = _smul($time, $TAU32);
    my $cosine_value = _f32(cos($angle));
    my $z_base = abs($cosine_value) < _f32(0.0000001) ? 0.0 : _smul($cosine_value, $speed);
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
        my $source = $rt->texel_fetch($ctx->texture_binding('inputTex'), [$x, $y]);
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
        my $lim      = $limiter_value < _f32(0.99) ? $limiter_value : _f32(0.99);
        my $limiter_mask = _smul(_f32($lim**$exponent), $alpha);
        my $inverse_mask = _ssub(1.0, $limiter_mask);
        $out->[$_] = _f32($source->[$_] * $inverse_mask + $static_value * $limiter_mask) for 0 .. 2;
        $out->[3] = $source->[3];
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

1;
