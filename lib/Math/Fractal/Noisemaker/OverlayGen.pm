package Math::Fractal::Noisemaker::OverlayGen;

# Procedural worm/fiber/scratch overlay generator.
#
# Port of noisemaker-cpu src/effects/cpu/worm-overlay.js (via the Python
# port). filter/fibers, filter/scratches and filter/strayHair declare an
# overlayTex that no pass produces; the reference engine generates it once on
# the CPU and binds it.
#
# Fidelity notes:
# - SeededRng multiplies with plain JS `*` on products up to ~2^61, which is
#   LOSSY in float64 (NOT Math.imul). We replicate that by multiplying in NV
#   (float64) and truncating.
# - Field/surface storage is float32; reads promote to float64, writes round.
# - Final surface is quantized to 8-bit like the reference.

use strict;
use warnings;
use POSIX ();

use Math::Fractal::Noisemaker::Surface;

my $TAU = 2.0 * 3.141592653589793;
my $M   = 0xFFFFFFFF;

my %OVERLAY_EFFECTS = map { $_ => 1 } qw(filter/fibers filter/scratches filter/strayHair);

sub is_overlay_effect { $OVERLAY_EFFECTS{ $_[0] } ? 1 : 0 }

sub _f32 { unpack('f', pack('f', $_[0])) }

# Floored float modulo (Python/JS `((x % n) + n) % n` building block): result
# sign follows the divisor, unlike POSIX::fmod's truncated semantics.
sub _pymod {
    my ($x, $n) = @_;
    my $r = POSIX::fmod($x, $n);
    $r += $n if $r != 0 && (($r < 0) != ($n < 0));
    return $r;
}

package Math::Fractal::Noisemaker::OverlayGen::SeededRng;

# JS advances state with a plain `*` whose ~2^61 product is LOSSY in float64
# — that loss is part of the reference stream. Perl's numeric model cannot be
# trusted to reproduce IEEE double mul/add at that magnitude (its integer-
# preferring `+` and its NV<->IV conversions both corrupt low bits there), so
# the float64 arithmetic is EMULATED in exact integer space: products of
# (u32 x 30-bit constant) fit an IV exactly, and _round53 applies IEEE
# round-to-nearest-even to 53 bits of mantissa — bit-identical to the JS
# double result — before the exact mod-2^32.

# Round a non-negative exact integer (< 2^62) to float64 precision: keep the
# top 53 significant bits, round half to even.
sub _round53 {
    my ($n) = @_;
    return $n if $n < 9007199254740992;    # < 2^53: already exact
    my $h = 0;
    { my $t = $n; while ($t >>= 1) { $h++ } }
    my $shift = $h - 52;
    my $keep  = $n >> $shift;
    my $rem   = $n & ((1 << $shift) - 1);
    my $half  = 1 << ($shift - 1);
    $keep++ if $rem > $half || ($rem == $half && ($keep & 1));
    return $keep << $shift;
}

sub _advance {    # float64( state*747796405 + 2891336453 ) mod 2^32, exactly
    my ($state) = @_;
    my $sum = _round53(_round53($state * 747796405) + 2891336453);
    return $sum % 4294967296;
}

sub new {
    my ($class, $seed) = @_;
    my $state = int($seed) & $M;
    # constructor already advances once (matches JS)
    return bless { state => _advance($state) }, $class;
}

sub next_word {
    my ($self) = @_;
    my $s = $self->{state} = _advance($self->{state});
    my $word = _round53((($s >> (($s >> 28) + 4)) ^ $s) * 277803737) % 4294967296;
    return (($word >> 22) ^ $word) & $M;
}

sub float { $_[0]->next_word / 4294967295.0 }

sub normal {
    my ($self, $mean, $deviation) = @_;
    my $u1 = $self->float;
    $u1 = 1e-10 if $u1 < 1e-10;
    my $u2 = $self->float;
    return $mean + $deviation * sqrt(-2.0 * log($u1)) * cos($TAU * $u2);
}

package Math::Fractal::Noisemaker::OverlayGen;

sub _value_noise_field {
    my ($width, $height, $frequency, $rng) = @_;
    my $grid_w = POSIX::ceil($frequency) + 2;
    my $grid_h = POSIX::ceil($frequency) + 2;
    my @grid   = map { _f32($rng->float) } 1 .. $grid_w * $grid_h;
    my @field;
    for my $y (0 .. $height - 1) {
        for my $x (0 .. $width - 1) {
            my $fx = $x / $width * $frequency;
            my $fy = $y / $height * $frequency;
            my $ix = POSIX::floor($fx);
            my $iy = POSIX::floor($fy);
            my $dx = $fx - $ix;
            my $dy = $fy - $iy;
            my $sx = $dx * $dx * (3 - 2 * $dx);
            my $sy = $dy * $dy * (3 - 2 * $dy);
            my $tl = $grid[ $iy * $grid_w + $ix ];
            my $tr = $grid[ $iy * $grid_w + $ix + 1 ];
            my $bl = $grid[ ($iy + 1) * $grid_w + $ix ];
            my $br = $grid[ ($iy + 1) * $grid_w + $ix + 1 ];
            push @field, _f32(($tl * (1 - $sx) + $tr * $sx) * (1 - $sy) + ($bl * (1 - $sx) + $br * $sx) * $sy);
        }
    }
    return \@field;
}

sub _draw_segment {
    my ($surface, $x0, $y0, $x1, $y1, $line_width, $color, $alpha) = @_;
    return if $alpha <= 0;
    my $radius = $line_width * 0.5;
    my $w      = $surface->width;
    my $h      = $surface->height;
    my $min_x  = POSIX::floor(($x0 < $x1 ? $x0 : $x1) - $radius - 1); $min_x = 0 if $min_x < 0;
    my $max_x  = POSIX::ceil(($x0 > $x1 ? $x0 : $x1) + $radius + 1);  $max_x = $w - 1 if $max_x > $w - 1;
    my $min_y  = POSIX::floor(($y0 < $y1 ? $y0 : $y1) - $radius - 1); $min_y = 0 if $min_y < 0;
    my $max_y  = POSIX::ceil(($y0 > $y1 ? $y0 : $y1) + $radius + 1);  $max_y = $h - 1 if $max_y > $h - 1;
    my $dx     = $x1 - $x0;
    my $dy     = $y1 - $y0;
    my $len_sq = $dx * $dx + $dy * $dy;
    my $data   = $surface->data;
    for my $y ($min_y .. $max_y) {
        for my $x ($min_x .. $max_x) {
            my $px = $x + 0.5;
            my $py = $y + 0.5;
            my $amount = 0;
            if ($len_sq > 0) {
                $amount = (($px - $x0) * $dx + ($py - $y0) * $dy) / $len_sq;
                $amount = 0 if $amount < 0;
                $amount = 1 if $amount > 1;
            }
            my $near_x   = $x0 + $dx * $amount;
            my $near_y   = $y0 + $dy * $amount;
            my $distance = sqrt(($px - $near_x)**2 + ($py - $near_y)**2);
            my $coverage = $radius + 0.5 - $distance;
            $coverage = 0 if $coverage < 0;
            $coverage = 1 if $coverage > 1;
            my $src_a = $alpha * $coverage;
            next if $src_a <= 0;
            my $off   = ($y * $w + $x) * 4;
            my $dst_a = $data->[ $off + 3 ];
            my $out_a = $src_a + $dst_a * (1 - $src_a);
            for my $c (0 .. 2) {
                $data->[ $off + $c ] =
                    $out_a > 0
                    ? _f32(($color->[$c] * $src_a + $data->[ $off + $c ] * $dst_a * (1 - $src_a)) / $out_a)
                    : 0;
            }
            $data->[ $off + 3 ] = _f32($out_a);
        }
    }
}

sub _trace {
    my ($surface, $opts) = @_;
    my $rng     = Math::Fractal::Noisemaker::OverlayGen::SeededRng->new($opts->{seed});
    my $min_dim = $surface->width < $surface->height ? $surface->width : $surface->height;
    my $max_dim = $surface->width > $surface->height ? $surface->width : $surface->height;
    my $stride_scale = $max_dim / 1024;
    my $flow = _value_noise_field(
        $surface->width, $surface->height, $opts->{flowFrequency},
        Math::Fractal::Noisemaker::OverlayGen::SeededRng->new($opts->{seed} * 31337)
    );
    my $count = POSIX::floor($max_dim * $opts->{density});
    $count = 1 if $count < 1;
    my $shared_rotation = $rng->float * $TAU;
    my @worms;
    for my $index (0 .. $count - 1) {
        push @worms, {
            x        => $rng->float * $surface->width,
            y        => $rng->float * $surface->height,
            stride   => $rng->normal($opts->{stride}, $opts->{strideDeviation}) * $stride_scale,
            rotation => $opts->{behavior} eq 'obedient' ? $shared_rotation : $rng->float * $TAU,
            color    => $opts->{color}->($rng, $index),
        };
    }
    my $iterations = POSIX::floor(sqrt($min_dim) * $opts->{duration});
    $iterations = 1 if $iterations < 1;
    for my $worm (@worms) {
        my $x = $worm->{x};
        my $y = $worm->{y};
        for my $iteration (0 .. $iterations - 1) {
            my $lifetime = $iterations > 1 ? $iteration / ($iterations - 1) : 1;
            my $exposure = 1 - abs(1 - $lifetime * 2);
            my $flow_x = POSIX::floor(_pymod(_pymod($x, $surface->width) + $surface->width, $surface->width));
            my $flow_y = POSIX::floor(_pymod(_pymod($y, $surface->height) + $surface->height, $surface->height));
            my $angle = $flow->[ $flow_y * $surface->width + $flow_x ] * $TAU * $opts->{kink};
            $angle += $opts->{behavior} eq 'obedient' ? $shared_rotation : $worm->{rotation};
            my $next_x = $x + sin($angle) * $worm->{stride};
            my $next_y = $y + cos($angle) * $worm->{stride};
            _draw_segment($surface, $x, $y, $next_x, $next_y, $opts->{lineWidth}, $worm->{color},
                $opts->{alpha} * $exposure);
            $x = $next_x;
            $y = $next_y;
        }
    }
}

sub render_worm_overlay {
    my ($effect_id, $width, $height, $params) = @_;
    my $surface = Math::Fractal::Noisemaker::Surface->new($width, $height);
    my $seed    = $params->{seed} || 1;
    my $density = $params->{density};
    if ($effect_id eq 'filter/fibers') {
        my $base_density = 0.5 + $density * 2;
        for my $layer (0 .. 3) {
            my $layer_seed = $seed * 1000 + $layer * 137;
            _trace($surface, {
                seed            => $layer_seed,
                density         => $base_density,
                kink            => 5 + $layer_seed % 5,
                stride          => 0.75,
                strideDeviation => 0.125,
                duration        => 1,
                behavior        => 'chaotic',
                flowFrequency   => 4,
                lineWidth       => ($width / 384 > 1.5 ? $width / 384 : 1.5),
                color           => sub {
                    my ($rng) = @_;
                    [
                        POSIX::floor($rng->float * 200 + 55) / 255,
                        POSIX::floor($rng->float * 200 + 55) / 255,
                        POSIX::floor($rng->float * 200 + 55) / 255,
                    ];
                },
                alpha => 0.5,
            });
        }
    }
    elsif ($effect_id eq 'filter/scratches') {
        for my $layer (0 .. 3) {
            my $layer_seed = $seed * 1000 + $layer * 251;
            _trace($surface, {
                seed            => $layer_seed,
                density         => 0.1 + $density * 0.4,
                kink            => 0.125 + $layer_seed % 50 / 400,
                stride          => 0.75,
                strideDeviation => 0.5,
                duration        => 2 + $layer_seed % 3,
                behavior        => ($layer_seed % 2 == 0 ? 'obedient' : 'unruly'),
                flowFrequency   => 2 + $layer_seed % 3,
                lineWidth       => ($width / 1024 > 0.5 ? $width / 1024 : 0.5),
                color           => sub { [1.0, 1.0, 1.0] },
                alpha           => 1,
            });
        }
    }
    elsif ($effect_id eq 'filter/strayHair') {
        my $layer_seed = $seed * 1000 + 42;
        _trace($surface, {
            seed            => $layer_seed,
            density         => 0.001 + $density * 0.004,
            kink            => 5 + $layer_seed % 45,
            stride          => 0.5,
            strideDeviation => 0.25,
            duration        => 8 + $layer_seed % 8,
            behavior        => 'unruly',
            flowFrequency   => 4,
            lineWidth       => ($width / 400 > 1 ? $width / 400 : 1),
            color           => sub {
                my ($rng) = @_;
                [
                    POSIX::floor($rng->float * 30) / 255,
                    POSIX::floor($rng->float * 30) / 255,
                    POSIX::floor($rng->float * 30) / 255,
                ];
            },
            alpha => 0.666,
        });
    }
    else {
        die "Unsupported canonical CPU overlay $effect_id\n";
    }
    for my $v (@{ $surface->data }) {
        my $x = $v < 0 ? 0 : $v > 1 ? 1 : $v;
        # Snap to f32 — Surface data holds float32-representable values (the
        # Python port gets this free from the numpy dtype).
        $v = _f32(POSIX::floor($x * 255.0 + 0.5) / 255.0);
    }
    return $surface;
}

1;
