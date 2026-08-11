package Math::Fractal::Noisemaker::DrawOps;

# CPU-only draw operations for drawMode passes: wormhole scattering plus the
# point and billboard adapters used by the stateful particle effects.

use strict;
use warnings;
use POSIX ();

use Math::Fractal::Noisemaker::Sampler qw(sample_bilinear sample_nearest_bottom_left);
use Math::Fractal::Noisemaker::TextureFormat qw(float16_truncate);
use Math::Fractal::Noisemaker::UintMath qw(float_bits_to_uint uadd umul ushr uxor);

my %DRAW_OPS;    # "effect_id:program" -> sub { my ($context) = @_; }

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
my $GOLDEN_RATIO_CONJUGATE = 0.618033988749895;

sub _f32 { unpack('f', pack('f', $_[0])) }
sub _add { _f32($_[0] + $_[1]) }
sub _mul { _f32($_[0] * $_[1]) }
sub _div { _f32($_[0] / $_[1]) }

# texelFetch on agent-state textures: GLSL rows are bottom-up while Surface
# storage is top-down.
sub texel_fetch_agent {
    my ($surface, $sx, $sy) = @_;
    my ($width, $height) = ($surface->width, $surface->height);
    my $x = $sx < 0 ? 0 : $sx >= $width ? $width - 1 : $sx;
    my $shader_y = $sy < 0 ? 0 : $sy >= $height ? $height - 1 : $sy;
    my $y = $height - 1 - $shader_y;
    my $offset = ($y * $width + $x) * 4;
    return [@{ $surface->data }[$offset .. $offset + 3]];
}

# Rasterize one GL point from clip space to a top-down Surface offset.
sub scatter_point_pixel {
    my ($clip_x, $clip_y, $clip_w, $dest_width, $dest_height) = @_;
    return undef unless $clip_w > 0;
    my $ndc_x = $clip_x / $clip_w;
    my $ndc_y = $clip_y / $clip_w;
    my $gl_col = POSIX::floor(($ndc_x * 0.5 + 0.5) * $dest_width);
    my $gl_row = POSIX::floor(($ndc_y * 0.5 + 0.5) * $dest_height);
    my $inf = 9**9**9;
    return undef if $gl_col != $gl_col || $gl_row != $gl_row
        || abs($gl_col) == $inf || abs($gl_row) == $inf;
    return undef if $gl_col < 0 || $gl_col >= $dest_width || $gl_row < 0 || $gl_row >= $dest_height;
    my $storage_row = $dest_height - 1 - $gl_row;
    return ($storage_row * $dest_width + $gl_col) * 4;
}

sub _fract { $_[0] - POSIX::floor($_[0]) }

sub compute_clip_center {
    my ($x, $y, $z, $uniforms) = @_;
    return [$x * 2 - 1, $y * 2 - 1] if int($uniforms->{viewMode} // 0) == 0;

    my $is_2d = abs($z) < 1 && $x >= 0 && $x <= 1 && $y >= 0 && $y <= 1;
    my ($px, $py, $pz) = $is_2d ? ($x - 0.5, $y - 0.5, 0) : ($x, $y, $z);
    my ($rx, $ry, $rz) = map { 0 + ($uniforms->{$_} // 0) } qw(rotateX rotateY rotateZ);

    my ($cos_x, $sin_x) = (cos($rx), sin($rx));
    my ($x1, $y1, $z1) = ($px, $py * $cos_x - $pz * $sin_x, $py * $sin_x + $pz * $cos_x);
    my ($cos_y, $sin_y) = (cos($ry), sin($ry));
    my ($x2, $y2) = ($x1 * $cos_y + $z1 * $sin_y, $y1);
    my ($cos_z, $sin_z) = (cos($rz), sin($rz));
    my $fx = $x2 * $cos_z - $y2 * $sin_z + ($uniforms->{posX} // 0);
    my $fy = $x2 * $sin_z + $y2 * $cos_z + ($uniforms->{posY} // 0);
    my $scale = 0 + ($uniforms->{viewScale} // 0);
    return $is_2d ? [$fx * 3.5 * $scale, $fy * 3.5 * $scale]
                  : [($fx / 40) * $scale, ($fy / 40) * $scale];
}

sub _dla_deposit {
    my ($ctx) = @_;
    my ($xyz, $vel, $rgba) = @{$ctx->{inputs}}{qw(xyzTex velTex rgbaTex)};
    my $dest = $ctx->{destination};
    my ($width, $height) = ($xyz->width, $xyz->height);
    my $energy = ($ctx->{uniforms}{deposit} // 0) * 0.1;
    my $pixels = 0;
    for my $v (0 .. $width * $height - 1) {
        my ($sx, $sy) = ($v % $width, POSIX::floor($v / $width));
        next if texel_fetch_agent($vel, $sx, $sy)->[1] < 0.5;
        my $pos = texel_fetch_agent($xyz, $sx, $sy);
        my $offset = scatter_point_pixel($pos->[0] * 2 - 1, $pos->[1] * 2 - 1,
            1, $dest->width, $dest->height);
        next unless defined $offset;
        my $color = texel_fetch_agent($rgba, $sx, $sy);
        $dest->data->[$offset] += $color->[0] * $energy;
        $dest->data->[$offset + 1] += $color->[1] * $energy;
        $dest->data->[$offset + 2] += $color->[2] * $energy;
        $dest->data->[$offset + 3] += $energy;
        $pixels++;
    }
    return { pixels => $pixels };
}

sub _lenia_deposit {
    my ($ctx) = @_;
    my $xyz = $ctx->{inputs}{xyzTex};
    my $dest = $ctx->{destination};
    my ($width, $height) = ($xyz->width, $xyz->height);
    my $amount = $ctx->{uniforms}{depositAmount};
    my $pixels = 0;
    for my $v (0 .. $width * $height - 1) {
        my $pos = texel_fetch_agent($xyz, $v % $width, POSIX::floor($v / $width));
        next if $pos->[3] < 0.5;
        my $offset = scatter_point_pixel($pos->[0] * 2 - 1, $pos->[1] * 2 - 1,
            1, $dest->width, $dest->height);
        next unless defined $offset;
        $dest->data->[$offset] += $amount;
        $dest->data->[ $offset + 3 ] += 1;
        $pixels++;
    }
    return { pixels => $pixels };
}

sub _physarum_deposit {
    my ($ctx) = @_;
    my ($xyz, $rgba) = @{$ctx->{inputs}}{qw(xyzTex rgbaTex)};
    my $dest = $ctx->{destination};
    my ($width, $height) = ($xyz->width, $xyz->height);
    my $deposit = $ctx->{uniforms}{deposit} // 0;
    my $pixels = 0;
    for my $v (0 .. $width * $height - 1) {
        my ($sx, $sy) = ($v % $width, POSIX::floor($v / $width));
        my $pos = texel_fetch_agent($xyz, $sx, $sy);
        next if $pos->[3] < 0.5;
        my $offset = scatter_point_pixel($pos->[0] * 2 - 1, $pos->[1] * 2 - 1,
            1, $dest->width, $dest->height);
        next unless defined $offset;
        my $color = texel_fetch_agent($rgba, $sx, $sy);
        for my $channel (0 .. 3) {
            $dest->data->[$offset + $channel] += $color->[$channel] * $deposit;
        }
        $pixels++;
    }
    return { pixels => $pixels };
}

sub _flow3d_deposit {
    my ($ctx) = @_;
    my ($state1, $state2) = @{$ctx->{inputs}}{qw(stateTex1 stateTex2)};
    my $dest = $ctx->{destination};
    my ($state_width, $state_height) = ($state1->width, $state1->height);
    my $capacity = $state_width * $state_height;
    my $max_dimension = $state_width > $state_height ? $state_width : $state_height;
    my $max_agents = int($max_dimension * ($ctx->{uniforms}{density} // 0) * 0.2);
    my $draw_count = defined $ctx->{pass}{count} ? $ctx->{pass}{count} : $capacity;
    my $count = $draw_count < $capacity ? $draw_count : $capacity;
    $count = $max_agents if $count > $max_agents;
    $count = 0 if $count < 0;
    my $volume_size = $ctx->{uniforms}{volumeSize};
    my $atlas_height = $volume_size * $volume_size;
    my $pixels = 0;

    for my $agent_index (0 .. $count - 1) {
        my $state_x = $agent_index % $state_width;
        my $state_y = POSIX::floor($agent_index / $state_width);
        my $position = texel_fetch_agent($state1, $state_x, $state_y);
        my $color = texel_fetch_agent($state2, $state_x, $state_y);
        my $atlas_x = $position->[0];
        my $atlas_y = $position->[1] + POSIX::floor($position->[2]) * $volume_size;
        my $offset = scatter_point_pixel(
            ($atlas_x / $volume_size) * 2 - 1,
            ($atlas_y / $atlas_height) * 2 - 1,
            1, $dest->width, $dest->height,
        );
        next unless defined $offset;
        $dest->data->[$offset]     += $color->[0];
        $dest->data->[$offset + 1] += $color->[1];
        $dest->data->[$offset + 2] += $color->[2];
        $dest->data->[$offset + 3] += 1;
        $pixels++;
    }
    return { pixels => $pixels };
}

sub _points_render_deposit {
    my ($ctx) = @_;
    my ($xyz, $rgba) = @{$ctx->{inputs}}{qw(xyzTex rgbaTex)};
    my $dest = $ctx->{destination};
    my ($width, $height) = ($xyz->width, $xyz->height);
    my $threshold = ($ctx->{uniforms}{density} // 0) / 100;
    my $pixels = 0;
    for my $v (0 .. $width * $height - 1) {
        next if _fract($v * $GOLDEN_RATIO_CONJUGATE) > $threshold;
        my ($sx, $sy) = ($v % $width, POSIX::floor($v / $width));
        my $pos = texel_fetch_agent($xyz, $sx, $sy);
        next if $pos->[3] < 0.5;
        my $clip = compute_clip_center(@$pos[0 .. 2], $ctx->{uniforms});
        my $offset = scatter_point_pixel(@$clip, 1, $dest->width, $dest->height);
        next unless defined $offset;
        my $color = texel_fetch_agent($rgba, $sx, $sy);
        for my $channel (0 .. 3) {
            $dest->data->[$offset + $channel] += $color->[$channel];
        }
        $pixels++;
    }
    return { pixels => $pixels };
}

sub _clamp {
    my ($value, $low, $high) = @_;
    return $low if $value < $low;
    return $high if $value > $high;
    return $value;
}

sub _smoothstep {
    my ($edge0, $edge1, $value) = @_;
    my $t = _clamp(($value - $edge0) / ($edge1 - $edge0), 0, 1);
    return $t * $t * (3 - 2 * $t);
}

sub billboard_hash {
    my ($n, $seed) = @_;
    my $seed_bits = float_bits_to_uint(_f32($n + $seed));
    my $state = uadd(umul($seed_bits, 747796405), 2891336453);
    my $word = umul(uxor(ushr($state, ushr($state, 28) + 4), $state), 277803737);
    return uxor(ushr($word, 22), $word) / 4294967295;
}

sub _sign { $_[0] < 0 ? -1 : $_[0] > 0 ? 1 : 0 }

sub _shape_distance {
    my ($mode, $px, $py) = @_;
    return sqrt($px * $px + $py * $py) - 0.45 if $mode == 1;
    return abs(sqrt($px * $px + $py * $py) - 0.35) - 0.08 if $mode == 2;
    return (abs($px) > abs($py) ? abs($px) : abs($py)) - 0.4 if $mode == 3;
    return abs($px) + abs($py) - 0.45 if $mode == 4;
    if ($mode == 5) {
        my ($r, $k) = (0.25, 1.732050808);
        my ($tx, $ty) = (abs($px) - $r, $py - 0.04 + $r / $k);
        if ($tx + $k * $ty > 0) {
            ($tx, $ty) = (($tx - $k * $ty) / 2, (-$k * $tx - $ty) / 2);
        }
        $tx -= _clamp($tx, -2 * $r, 0);
        return -sqrt($tx * $tx + $ty * $ty) * _sign($ty);
    }

    my ($r, $rf) = (0.35, 0.4);
    my ($k1x, $k1y) = (0.809016994375, -0.587785252292);
    my ($k2x, $k2y) = (-$k1x, $k1y);
    my ($sx, $sy) = (abs($px), $py);
    my $m1 = $k1x * $sx + $k1y * $sy;
    $m1 = 0 if $m1 < 0;
    ($sx, $sy) = ($sx - 2 * $m1 * $k1x, $sy - 2 * $m1 * $k1y);
    my $m2 = $k2x * $sx + $k2y * $sy;
    $m2 = 0 if $m2 < 0;
    ($sx, $sy) = ($sx - 2 * $m2 * $k2x, $sy - 2 * $m2 * $k2y);
    ($sx, $sy) = (abs($sx), $sy - $r);
    my ($bax, $bay) = ($rf * -$k1y, $rf * $k1x - 1);
    my $h = _clamp(($sx * $bax + $sy * $bay) / ($bax * $bax + $bay * $bay), 0, $r);
    my ($rem_x, $rem_y) = ($sx - $bax * $h, $sy - $bay * $h);
    return sqrt($rem_x * $rem_x + $rem_y * $rem_y) * _sign($sy * $bax - $sx * $bay);
}

sub billboard_shape_alpha {
    my ($shape_mode, $u, $v) = @_;
    my ($x, $y) = ($u - 0.5, $v - 0.5);
    return exp(-($x * $x + $y * $y) * 8) unless $shape_mode >= 1 && $shape_mode <= 6;
    return 1 - _smoothstep(-0.02, 0.02, _shape_distance($shape_mode, $x, $y));
}

sub _billboard_fragment {
    my ($mode, $sprite, $u, $v, $color, $opacity) = @_;
    if ($mode == 0) {
        my $sample = $sprite->filter eq 'linear'
            ? sample_bilinear($sprite, $u, 1 - $v)
            : sample_nearest_bottom_left($sprite, $u, $v);
        return [map { $sample->[$_] * $color->[$_] * $opacity } 0 .. 3];
    }
    my $alpha = billboard_shape_alpha($mode, $u, $v);
    return [
        $color->[0] * $alpha * $opacity,
        $color->[1] * $alpha * $opacity,
        $color->[2] * $alpha * $opacity,
        $alpha * $color->[3] * $opacity,
    ];
}

sub _premultiplied_blend {
    my ($pass) = @_;
    return 0 unless ref $pass->{blend} eq 'ARRAY';
    return uc($pass->{blend}[0] // '') eq 'ONE'
        && uc($pass->{blend}[1] // '') eq 'ONE_MINUS_SRC_ALPHA';
}

sub _billboard_deposit {
    my ($ctx) = @_;
    my ($xyz, $rgba, $sprite) = @{$ctx->{inputs}}{qw(xyzTex rgbaTex spriteTex)};
    my ($uniforms, $dest) = @{$ctx}{qw(uniforms destination)};
    my ($width, $height) = ($xyz->width, $xyz->height);
    my ($dest_width, $dest_height) = ($dest->width, $dest->height);
    my $threshold = ($uniforms->{density} // 0) / 100;
    my $shape_mode = int($uniforms->{shapeMode} // 0);
    my $opacity = ($uniforms->{depositOpacity} // 0) / 100;
    my $size_variation = ($uniforms->{sizeVariation} // 0) / 100;
    my $rotation_variation = ($uniforms->{rotationVar} // 0) / 100;
    my $premultiplied = _premultiplied_blend($ctx->{pass});
    my $inf = 9**9**9;
    my $pixels = 0;

    for my $v (0 .. $width * $height - 1) {
        next if _fract($v * $GOLDEN_RATIO_CONJUGATE) > $threshold;
        my ($sx, $sy) = ($v % $width, POSIX::floor($v / $width));
        my $pos = texel_fetch_agent($xyz, $sx, $sy);
        next if $pos->[3] < 0.5;
        my $color = texel_fetch_agent($rgba, $sx, $sy);
        my $center = compute_clip_center(@$pos[0 .. 2], $uniforms);
        my $size = ($uniforms->{pointSize} // 0)
            * (1 - $size_variation * (billboard_hash($v, $uniforms->{seed} // 0) - 0.5));
        next unless $size > 0;
        my $rotation = $rotation_variation
            * billboard_hash($v + 1234.5, $uniforms->{seed} // 0) * 6.283185;
        my ($cos_r, $sin_r) = (cos($rotation), sin($rotation));
        my ($size_clip_x, $size_clip_y) = ($size / $dest_width, $size / $dest_height);
        my ($min_x, $max_x, $min_y, $max_y) = ($inf, -$inf, $inf, -$inf);
        for my $corner ([-1, -1], [1, -1], [-1, 1], [1, 1]) {
            my ($rot_x, $rot_y) = (
                $corner->[0] * $cos_r - $corner->[1] * $sin_r,
                $corner->[0] * $sin_r + $corner->[1] * $cos_r,
            );
            my $px = (($center->[0] + $rot_x * $size_clip_x) * 0.5 + 0.5) * $dest_width;
            my $py = (($center->[1] + $rot_y * $size_clip_y) * 0.5 + 0.5) * $dest_height;
            $min_x = $px if $px < $min_x; $max_x = $px if $px > $max_x;
            $min_y = $py if $py < $min_y; $max_y = $py if $py > $max_y;
        }
        my $col_start = POSIX::floor($min_x); $col_start = 0 if $col_start < 0;
        my $col_end = POSIX::ceil($max_x); $col_end = $dest_width - 1 if $col_end >= $dest_width;
        my $row_start = POSIX::floor($min_y); $row_start = 0 if $row_start < 0;
        my $row_end = POSIX::ceil($max_y); $row_end = $dest_height - 1 if $row_end >= $dest_height;

        for my $gl_row ($row_start .. $row_end) {
            my $dy = (($gl_row + 0.5) / $dest_height) * 2 - 1 - $center->[1];
            my $b = $dy / $size_clip_y;
            my $storage_row = $dest_height - 1 - $gl_row;
            for my $col ($col_start .. $col_end) {
                my $dx = (($col + 0.5) / $dest_width) * 2 - 1 - $center->[0];
                my $a = $dx / $size_clip_x;
                my ($offset_x, $offset_y) = (
                    $a * $cos_r + $b * $sin_r,
                    -$a * $sin_r + $b * $cos_r,
                );
                next if $offset_x < -1 || $offset_x > 1 || $offset_y < -1 || $offset_y > 1;
                my $source = _billboard_fragment(
                    $shape_mode, $sprite, $offset_x * 0.5 + 0.5,
                    $offset_y * 0.5 + 0.5, $color, $opacity,
                );
                my $offset = ($storage_row * $dest_width + $col) * 4;
                if ($premultiplied) {
                    my $inverse_alpha = 1 - $source->[3];
                    for my $channel (0 .. 3) {
                        $dest->data->[$offset + $channel] = $source->[$channel]
                            + $dest->data->[$offset + $channel] * $inverse_alpha;
                    }
                }
                else {
                    for my $channel (0 .. 3) {
                        $dest->data->[$offset + $channel] += $source->[$channel];
                    }
                }
                $pixels++;
            }
        }
    }
    return { pixels => $pixels };
}

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

register('filter/wormhole', 'deposit', sub {
    my ($ctx) = @_;
    wormhole_deposit($ctx->{inputs}{inputTex}, $ctx->{destination}, $ctx->{uniforms});
    return { pixels => $ctx->{inputs}{inputTex}->width * $ctx->{inputs}{inputTex}->height };
});
register('points/lenia', 'deposit', \&_lenia_deposit);
register('points/dla', 'depositGrid', \&_dla_deposit);
register('points/physarum', 'deposit', \&_physarum_deposit);
register('filter3d/flow3d', 'deposit', \&_flow3d_deposit);
register('render/pointsRender', 'deposit', \&_points_render_deposit);
register('render/pointsBillboardRender', 'deposit', \&_billboard_deposit);

1;
