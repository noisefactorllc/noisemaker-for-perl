package Math::Fractal::Noisemaker::Remap;

use strict;
use warnings;
use List::Util qw(min max);
use Math::Fractal::Noisemaker::Sampler qw(sample_bilinear sample_nearest_texel_bottom_left);

# The CPU reference tests polygons in top-left, full-resolution pixel space
# using the authored doubles. Precompute the edge vectors once per pass.
sub _zones {
    my ($ctx, $width, $height) = @_;
    my $u = $ctx->uniforms;
    my @zones;
    for my $zone (reverse 0 .. min(int($u->{zoneCount} // 0), 8) - 1) {
        my $prefix = "zone${zone}_";
        my $count = min(int($u->{$prefix . 'count'} // 0), 64);
        next if $count < 3 || ($u->{$prefix . 'active'} // 0) < 0.5;
        my @vertices;
        for my $i (0 .. $count - 1) {
            my $pair = $u->{$prefix . 'v' . int($i / 2)} // [0, 0, 0, 0];
            my $offset = 2 * ($i % 2);
            push @vertices, [$pair->[$offset] * $width, $pair->[$offset + 1] * $height];
        }
        my @edges;
        for my $i (0 .. $#vertices) {
            my ($ax, $ay) = @{$vertices[$i]};
            my ($bx, $by) = @{$vertices[$i - 1]};
            my ($ex, $ey) = ($bx - $ax, $by - $ay);
            push @edges, [$ax, $ay, $by, $ex, $ey, max($ex * $ex + $ey * $ey, 1e-6)];
        }
        push @zones, {
            edges  => \@edges,
            bounds => $u->{$prefix . 'bounds'} // [0, 0, 1, 1],
            alpha  => $u->{$prefix . 'alpha'} // 1,
            tex    => $ctx->texture_binding($prefix . 'tex'),
        };
    }
    return \@zones;
}

sub _coverage {
    my ($edges, $x, $y, $feather) = @_;
    my ($inside, $d2) = (0, 1e30);
    for my $edge (@$edges) {
        my ($ax, $ay, $by, $ex, $ey, $length2) = @$edge;
        my ($wx, $wy) = ($x - $ax, $y - $ay);
        my ($c1, $c2, $c3) = ($y >= $ay, $y < $by, $ex * $wy > $ey * $wx);
        $inside = !$inside if ($c1 && $c2 && $c3) || !($c1 || $c2 || $c3);
        if ($feather > 0) {
            my $s = min(max(($wx * $ex + $wy * $ey) / $length2, 0), 1);
            my ($rx, $ry) = ($wx - $ex * $s, $wy - $ey * $s);
            $d2 = min($d2, $rx * $rx + $ry * $ry);
        }
    }
    return 1 if $inside;
    return 0 unless $feather > 0;
    my $t = min(sqrt($d2) / $feather, 1);
    return 1 - $t * $t * (3 - 2 * $t);
}

sub factory {
    my ($last_ctx, $zones, $feather, $dilate_x, $dilate_y);
    return sub {
        my ($ctx, $out) = @_;
        my $u = $ctx->uniforms;
        my ($width, $height) = @{$u->{fullResolution}};
        if (!$last_ctx || $ctx != $last_ctx) {
            $zones = _zones($ctx, $width, $height);
            $feather = max($u->{smoothEdge} // 0, 0) * 0.05 * min($width, $height);
            ($dilate_x, $dilate_y) = ($feather / $width, $feather / $height);
            $last_ctx = $ctx;
        }
        my ($fx, $fy) = @{$ctx->frag_coord};
        my $offset = $u->{tileOffset} // [0, 0];
        my ($x, $y) = ($fx + $offset->[0], $height - ($fy + $offset->[1]));
        my ($px, $py) = ($x / $width, $y / $height);
        my ($su, $sv) = ($fx / $u->{resolution}[0], $fy / $u->{resolution}[1]);
        my @rgba = (0, 0, 0, 0);
        for my $zone (@$zones) {
            my ($left, $top, $right, $bottom) = @{$zone->{bounds}};
            next if $px < $left - $dilate_x || $py < $top - $dilate_y
                 || $px > $right + $dilate_x || $py > $bottom + $dilate_y;
            my $coverage = _coverage($zone->{edges}, $x, $y, $feather);
            next unless $coverage > 0;
            my $tex = $zone->{tex};
            my $sample = ($tex->filter // '') eq 'linear'
                ? sample_bilinear($tex, $su, $sv)
                : sample_nearest_texel_bottom_left($tex, $su, $sv);
            my $weight = $coverage * $zone->{alpha};
            my $remaining = 1 - $rgba[3];
            $rgba[$_] += $sample->[$_] * $weight * $remaining for 0 .. 3;
            last if $rgba[3] >= 0.999;
        }
        my $remaining = 1 - $rgba[3];
        my $bg = $u->{bgColor} // [0, 0, 0];
        my $alpha = $u->{bgAlpha} // 1;
        $rgba[$_] += $bg->[$_] * $alpha * $remaining for 0 .. 2;
        $rgba[3] += $alpha * $remaining;
        @$out = unpack('f*', pack('f*', @rgba));
    };
}

1;
