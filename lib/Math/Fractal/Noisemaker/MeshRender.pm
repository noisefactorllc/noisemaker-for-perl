package Math::Fractal::Noisemaker::MeshRender;

# CPU triangle-mesh rasterizer for `drawMode: 'triangles'` passes
# (render/meshRender).
#
# Port of noisemaker-cpu src/effects/cpu/mesh-render.js. The canonical pass
# executor cannot run these through the per-pixel fragment kernels (they
# rasterize a variable number of triangles rather than filling every
# destination pixel once), so, like the scatter draw ops, this is a hand-ported
# function the renderer dispatches by "effect_id:program". It follows the
# upstream WebGL2 triangle-mesh draw:
#   - drawArrays(TRIANGLES) over one texel per vertex of the mesh positions
#     texture, consecutive texel triples forming a de-indexed triangle soup;
#   - depth test LESS against a per-pass depth buffer cleared to 1.0, back-face
#     culling with CCW = front, blending disabled;
#   - the vertex stage of render.vert (scale/offset, Rz*Ry*Rx rotation in
#     degrees, orthographic projection with viewScale and the aspect divide, z
#     mapped to [0, 1] over nearZ -10 / farZ 10) and the fragment stage of
#     render.frag (Blinn-Phong diffuse/specular, ambient, Fresnel rim, optional
#     wireframe discard via screen-space normal derivatives, gamma 1/2.2).
# Every f32() here is a Math.fround in the JS; arithmetic the JS leaves in f64
# (the barycentric divisions, Math.pow, Math.hypot) stays f64 here too.

use strict;
use warnings;
use POSIX ();
use Math::Fractal::Noisemaker::JsTrig qw(js_sin js_cos);

my %ADAPTERS;

sub register_adapter { $ADAPTERS{ $_[0] } = $_[1] }
sub get_adapter      { $ADAPTERS{"$_[0]:$_[1]"} }

sub f32 { unpack('f', pack('f', $_[0])) }
sub _vec3 { [f32($_[0]), f32($_[1]), f32($_[2])] }

# JS Math.max(a, 0): NaN when a is NaN.
sub _max0 { my ($a) = @_; return $a != $a ? $a : ($a > 0 ? $a : 0) }

sub _min { my $m = shift; for (@_) { $m = $_ if $_ < $m } $m }
sub _max { my $m = shift; for (@_) { $m = $_ if $_ > $m } $m }

# Vertex stage of render.vert for one mesh texel.
sub vertex_stage {
    my ($pos, $nrm, $u) = @_;
    my $position = _vec3(@$pos[0 .. 2]);
    my $normal   = _vec3(@$nrm[0 .. 2]);
    my $scale = $u->{meshScale};
    $position = _vec3(map { f32($_ * $scale) } @$position);
    $position = _vec3(
        f32($position->[0] + $u->{meshOffsetX}),
        f32($position->[1] + $u->{meshOffsetY}),
        f32($position->[2] + $u->{meshOffsetZ}),
    );
    my $deg2rad = f32(3.14159265 / 180.0);
    my ($rx, $ry, $rz) = map { f32($u->{$_} * $deg2rad) } qw(rotateX rotateY rotateZ);
    my ($cx, $sx) = (f32(js_cos($rx)), f32(js_sin($rx)));
    my ($cy, $sy) = (f32(js_cos($ry)), f32(js_sin($ry)));
    my ($cz, $sz) = (f32(js_cos($rz)), f32(js_sin($rz)));
    # mat3 rotationZ * rotationY * rotationX, column-major constructor values.
    my @rot_x = (1, 0, 0, 0, $cx, $sx, 0, -$sx, $cx);
    my @rot_y = ($cy, 0, $sy, 0, 1, 0, -$sy, 0, $cy);
    my @rot_z = ($cz, -$sz, 0, $sz, $cz, 0, 0, 0, 1);
    my $mul = sub {
        my ($a, $b) = @_;
        my @out;
        for my $col (0 .. 2) {
            for my $row (0 .. 2) {
                $out[ $col * 3 + $row ] = f32(
                    f32($a->[$row] * $b->[ $col * 3 ])
                    + f32($a->[ 3 + $row ] * $b->[ $col * 3 + 1 ])
                    + f32($a->[ 6 + $row ] * $b->[ $col * 3 + 2 ]));
            }
        }
        return \@out;
    };
    my $rotation = $mul->($mul->(\@rot_z, \@rot_y), \@rot_x);
    my $apply = sub {
        my ($m, $v) = @_;
        return _vec3(map {
            f32(f32($m->[$_] * $v->[0]) + f32($m->[ 3 + $_ ] * $v->[1]) + f32($m->[ 6 + $_ ] * $v->[2]))
        } 0 .. 2);
    };
    my $rotated_pos    = $apply->($rotation, $position);
    my $rotated_normal = $apply->($rotation, $normal);
    $rotated_pos->[0] = f32($rotated_pos->[0] + $u->{posX});
    $rotated_pos->[1] = f32($rotated_pos->[1] + $u->{posY});
    my $clip_x = f32($rotated_pos->[0] * $u->{viewScale});
    my $clip_y = f32($rotated_pos->[1] * $u->{viewScale});
    $clip_x = f32($clip_x / $u->{aspect});
    my ($near_z, $far_z) = (-10.0, 10.0);
    my $ndc_z = f32(f32($rotated_pos->[2] - $near_z) / f32($far_z - $near_z));
    return {
        clip_x => $clip_x, clip_y => $clip_y, ndc_z => $ndc_z,
        normal => $rotated_normal, position => $rotated_pos,
    };
}

sub _normalize {
    my ($v) = @_;
    my $len_sq = f32(f32(f32($v->[0] * $v->[0]) + f32($v->[1] * $v->[1])) + f32($v->[2] * $v->[2]));
    return _vec3(0, 0, 0) if $len_sq == 0;
    my $inv = f32(1 / sqrt($len_sq));
    return _vec3(map { f32($_ * $inv) } @$v);
}

# Fragment stage of render.frag for one covered pixel: the color, or undef for
# a wireframe discard.
sub fragment_stage {
    my ($v_normal, $u) = @_;
    my $normal    = _normalize($v_normal);
    my $light_dir = _normalize(_vec3(@{ $u->{lightDirection} }[0 .. 2]));
    my $view_dir  = _vec3(0, 0, 1);
    my $mesh      = _vec3(@{ $u->{meshColor} }[0 .. 2]);
    my $dot = sub { my ($a, $b) = @_; $a->[0] * $b->[0] + $a->[1] * $b->[1] + $a->[2] * $b->[2] };
    my $ambient = _vec3(map { f32($u->{ambientColor}[$_] * $mesh->[$_]) } 0 .. 2);
    my $diffuse_factor = _max0(f32($dot->($normal, $light_dir)));
    my $diffuse = _vec3(map {
        f32(f32($u->{diffuseColor}[$_] * $diffuse_factor) * $mesh->[$_] * $u->{diffuseIntensity})
    } 0 .. 2);
    my $half_dir = _normalize(_vec3(map { f32($light_dir->[$_] + $view_dir->[$_]) } 0 .. 2));
    my $spec_angle = _max0(f32($dot->($half_dir, $normal)));
    my $specular_factor = ($spec_angle == 0 && $u->{shininess} == 0) ? 1 : $spec_angle ** $u->{shininess};
    my $specular = _vec3(map {
        f32(f32($u->{specularColor}[$_] * f32($specular_factor)) * $u->{specularIntensity})
    } 0 .. 2);
    my $rim_base = f32(1 - _max0(f32($dot->($normal, $view_dir))));
    my $rim = ($rim_base == 0 && $u->{rimPower} == 0) ? 1 : $rim_base ** $u->{rimPower};
    my $rim_light = f32($rim * $u->{rimIntensity});
    my $color = _vec3(map {
        f32(f32($ambient->[$_] + $diffuse->[$_]) + f32($specular->[$_] + $rim_light))
    } 0 .. 2);
    if ($u->{wireframe} == 1) {
        # dFdx/dFdy of the interpolated normal, per triangle (see the adapter).
        my $hypot = sub { my ($v) = @_; sqrt(f32($v->[0]) ** 2 + f32($v->[1]) ** 2 + f32($v->[2]) ** 2) };
        my $edge = f32(f32($hypot->($u->{_dFdxNormal}) + $hypot->($u->{_dFdyNormal})));
        return undef if $edge < 0.1;    # discard: interior pixel
        $color = _vec3(@$mesh);
    }
    my $gamma = f32(1 / 2.2);
    return _vec3(map { f32($_ ** $gamma) } @$color);
}

sub mesh_render_triangles {
    my ($args) = @_;
    my $mesh = ($args->{external_inputs} || {})->{meshData}
        or die "render/meshRender requires external mesh data (external_inputs meshData)\n";
    my $positions = $mesh->{positions} // $mesh->{positionData};
    my $normals   = $mesh->{normalData};
    my ($tex_width, $tex_height) = @$mesh{qw(texWidth texHeight)};
    my $dest = $args->{destination};
    my ($width, $height) = ($dest->width, $dest->height);
    my $data = $dest->data;
    my %u = (%{ $args->{uniforms} }, aspect => f32($width / $height));
    $u{wireframe} //= 0;
    # Per-pixel depth buffer cleared to 1.0 for each pass.
    my @depth = (1) x ($width * $height);
    my $covered = 0;
    my $triangles = int($tex_width * $tex_height / 3);
    for my $tri (0 .. $triangles - 1) {
        # A triangle of three invalid texels (position w = 0) is skipped. The
        # vertex stage has no side effects, so testing w first changes nothing.
        next unless grep { $positions->[ ($tri * 3 + $_) * 4 + 3 ] != 0 } 0 .. 2;
        my @verts;
        for my $v (0 .. 2) {
            # Texel (x, y) of a texWidth-wide texture is data[(y * texWidth + x) * 4].
            my $pi = ($tri * 3 + $v) * 4;
            my @pos = @$positions[ $pi .. $pi + 3 ];
            my @nrm = @$normals[ $pi .. $pi + 3 ];
            my $stage = vertex_stage(\@pos, \@nrm, \%u);
            # Window coordinates, GL bottom-up.
            push @verts, {
                px       => f32(f32(f32($stage->{clip_x} + 1) * 0.5) * $width),
                py       => f32(f32(f32($stage->{clip_y} + 1) * 0.5) * $height),
                z        => $stage->{ndc_z},
                normal   => $stage->{normal},
                position => $stage->{position},
            };
        }
        my ($v0, $v1, $v2) = @verts;
        # Signed area in GL window space (y up); CCW is the front face.
        my $area = f32(f32(f32($v1->{px} - $v0->{px}) * f32($v2->{py} - $v0->{py}))
            - f32(f32($v2->{px} - $v0->{px}) * f32($v1->{py} - $v0->{py})));
        next unless $area > 0;    # back face or degenerate: culled
        my %frag = %u;
        if ($u{wireframe} == 1) {
            my $det = f32(f32(f32($v0->{px} * f32($v1->{py} - $v2->{py}))
                + f32($v1->{px} * f32($v2->{py} - $v0->{py})))
                + f32($v2->{px} * f32($v0->{py} - $v1->{py})));
            my @dx = (0, 0, 0);
            my @dy = (0, 0, 0);
            if ($det != 0) {
                # The determinant divides the whole edge-function numerator.
                @dx = map {
                    my $c = $_;
                    f32((f32(f32($v0->{normal}[$c] * f32($v1->{py} - $v2->{py}))
                        + f32($v1->{normal}[$c] * f32($v2->{py} - $v0->{py})))
                        + f32($v2->{normal}[$c] * f32($v0->{py} - $v1->{py}))) / $det)
                } 0 .. 2;
                @dy = map {
                    my $c = $_;
                    f32((f32(f32($v0->{normal}[$c] * f32($v2->{px} - $v1->{px}))
                        + f32($v1->{normal}[$c] * f32($v0->{px} - $v2->{px})))
                        + f32($v2->{normal}[$c] * f32($v1->{px} - $v0->{px}))) / $det)
                } 0 .. 2;
            }
            $frag{_dFdxNormal} = \@dx;
            $frag{_dFdyNormal} = \@dy;
        }
        # Bounding box of the triangle, clamped to the viewport.
        my @px = map { $_->{px} } @verts;
        my @py = map { $_->{py} } @verts;
        my $min_x = _max(0, POSIX::floor(_min(@px) - 0.5));
        my $max_x = _min($width - 1, POSIX::ceil(_max(@px) - 0.5));
        my $min_y = _max(0, POSIX::floor(_min(@py) - 0.5));
        my $max_y = _min($height - 1, POSIX::ceil(_max(@py) - 0.5));
        for my $py_gl ($min_y .. $max_y) {
            # Surface rows are top-down; GL window y is bottom-up.
            my $row = $height - 1 - $py_gl;
            my $cy = f32($py_gl + 0.5);
            for my $px_gl ($min_x .. $max_x) {
                my $cx = f32($px_gl + 0.5);
                # Barycentric coordinates via edge functions; the division and
                # b2 stay f64, as in the JS.
                my $b0 = f32(f32(f32($v1->{px} - $v0->{px}) * f32($cy - $v0->{py}))
                    - f32(f32($v1->{py} - $v0->{py}) * f32($cx - $v0->{px}))) / $area;
                my $b1 = f32(f32(f32($v2->{px} - $v1->{px}) * f32($cy - $v1->{py}))
                    - f32(f32($v2->{py} - $v1->{py}) * f32($cx - $v1->{px}))) / $area;
                my $b2 = 1 - f32($b0 + $b1);
                next unless $b0 >= 0 && $b1 >= 0 && $b2 >= 0;
                my $z = f32(f32(f32($b0 * $v0->{z}) + f32($b1 * $v1->{z})) + f32($b2 * $v2->{z}));
                my $index = $row * $width + $px_gl;
                next unless $z < $depth[$index];    # depthFunc LESS
                $depth[$index] = $z;
                my @v_normal = map {
                    f32(f32(f32($b0 * $v0->{normal}[$_]) + f32($b1 * $v1->{normal}[$_]))
                        + f32($b2 * $v2->{normal}[$_]))
                } 0 .. 2;
                my $color = fragment_stage(\@v_normal, \%frag) // next;
                @$data[ $index * 4 .. $index * 4 + 3 ] = (@$color, 1);
                $covered++;
            }
        }
    }
    return { pixels => $covered };
}

register_adapter('render/meshRender:render', \&mesh_render_triangles);

1;
