use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Math::Fractal::Noisemaker::DrawOps ();
use Math::Fractal::Noisemaker::Surface;

sub close_to {
    my ($actual, $expected, $name) = @_;
    cmp_ok(abs($actual - $expected), '<=', 1e-12, $name);
}

is(
    Math::Fractal::Noisemaker::DrawOps::scatter_point_pixel(0, 0, 1, 3, 3),
    (1 * 3 + 1) * 4,
    'clip-space center maps to destination center pixel',
);
ok(
    !defined Math::Fractal::Noisemaker::DrawOps::scatter_point_pixel(2, 0, 1, 3, 3),
    'out-of-range point is discarded',
);

my $agent = Math::Fractal::Noisemaker::Surface->new(2, 2, [
    1, 0, 0, 1,  2, 0, 0, 1,
    3, 0, 0, 1,  4, 0, 0, 1,
]);
is_deeply(
    Math::Fractal::Noisemaker::DrawOps::texel_fetch_agent($agent, 0, 0),
    [3, 0, 0, 1],
    'agent texel fetch flips bottom-left GL rows into top-down storage',
);

my $dest = Math::Fractal::Noisemaker::Surface->new(1, 1);
my $xyz = Math::Fractal::Noisemaker::Surface->new(1, 1, [0.5, 0.5, 0, 1]);
my $lenia = Math::Fractal::Noisemaker::DrawOps::get_draw_op('points/lenia', 'deposit');
ok(ref $lenia eq 'CODE', 'lenia scatter adapter is registered');
$lenia->({
    pass        => { blend => 1 },
    uniforms    => { depositAmount => 0.25 },
    inputs      => { xyzTex => $xyz },
    destination => $dest,
    params      => {},
});
is_deeply($dest->data, [0.25, 0, 0, 1], 'lenia deposits one additive point');

my $flow3d = Math::Fractal::Noisemaker::DrawOps::get_draw_op('filter3d/flow3d', 'deposit');
ok(ref $flow3d eq 'CODE', 'flow3d scatter adapter is registered');
my $flow_state1 = Math::Fractal::Noisemaker::Surface->new(1, 1, [1, 1, 0, 1]);
my $flow_state2 = Math::Fractal::Noisemaker::Surface->new(1, 1, [0.2, 0.3, 0.4, 1]);
my $flow_dest = Math::Fractal::Noisemaker::Surface->new(2, 4);
my $flow_stats = $flow3d->({
    pass        => { count => 262_144, blend => 1 },
    uniforms    => { density => 10, volumeSize => 2 },
    inputs      => { stateTex1 => $flow_state1, stateTex2 => $flow_state2 },
    destination => $flow_dest,
});
is($flow_stats->{pixels}, 1, 'flow3d deposits the eligible agent');
is_deeply(
    [@{ $flow_dest->data }[20 .. 23]],
    [0.2, 0.3, 0.4, 1],
    'flow3d flattens voxel xyz into the canonical volume atlas pixel',
);

cmp_ok(
    abs(Math::Fractal::Noisemaker::DrawOps::billboard_shape_alpha(1, 0.5, 0.5) - 1),
    '<=',
    1e-12,
    'billboard circle is opaque at its center',
);

is_deeply(
    Math::Fractal::Noisemaker::DrawOps::compute_clip_center(
        0.5, 0.25, 999,
        { viewMode => 0 },
    ),
    [0, -0.5],
    'flat point projection ignores depth and maps normalized coordinates to clip space',
);

my $rgba = Math::Fractal::Noisemaker::Surface->new(1, 1, [0.2, 0.3, 0.4, 0.5]);
my $vel = Math::Fractal::Noisemaker::Surface->new(1, 1, [0, 1, 0, 0]);
my %scatter_inputs = (xyzTex => $xyz, rgbaTex => $rgba);

my $dla_dest = Math::Fractal::Noisemaker::Surface->new(1, 1);
my $dla = Math::Fractal::Noisemaker::DrawOps::get_draw_op('points/dla', 'depositGrid');
ok(ref $dla eq 'CODE', 'DLA scatter adapter is registered');
$dla->({
    uniforms    => { deposit => 2 },
    inputs      => { %scatter_inputs, velTex => $vel },
    destination => $dla_dest,
});
is_deeply($dla_dest->data, [0.04, 0.06, 0.08, 0.2], 'DLA deposits RGB times energy and energy alpha');

my $physarum_dest = Math::Fractal::Noisemaker::Surface->new(1, 1);
my $physarum = Math::Fractal::Noisemaker::DrawOps::get_draw_op('points/physarum', 'deposit');
ok(ref $physarum eq 'CODE', 'physarum scatter adapter is registered');
$physarum->({
    uniforms    => { deposit => 2 },
    inputs      => \%scatter_inputs,
    destination => $physarum_dest,
});
is_deeply($physarum_dest->data, [0.4, 0.6, 0.8, 1], 'physarum deposits scaled agent color');

my %view_uniforms = (
    density => 100, viewMode => 0, viewScale => 1,
    rotateX => 0, rotateY => 0, rotateZ => 0,
    posX => 0, posY => 0,
);
my $points_dest = Math::Fractal::Noisemaker::Surface->new(1, 1);
my $points = Math::Fractal::Noisemaker::DrawOps::get_draw_op('render/pointsRender', 'deposit');
ok(ref $points eq 'CODE', 'point-render scatter adapter is registered');
$points->({
    uniforms    => \%view_uniforms,
    inputs      => \%scatter_inputs,
    destination => $points_dest,
});
is_deeply($points_dest->data, [0.2, 0.3, 0.4, 0.5], 'point renderer deposits unscaled agent color');

close_to(
    Math::Fractal::Noisemaker::DrawOps::billboard_hash(0, 42),
    0.07695067745562426,
    'billboard size hash matches uint32 shader arithmetic',
);
close_to(
    Math::Fractal::Noisemaker::DrawOps::billboard_hash(1234.5, 42),
    0.9033963931499507,
    'billboard rotation hash matches uint32 shader arithmetic',
);
for my $case (
    [1, 0.95, 0.5, 0.5, 'circle feather'],
    [2, 0.85, 0.5, 1, 'ring body'],
    [3, 0.9, 0.5, 0.5, 'square feather'],
    [4, 0.5, 0.5, 1, 'diamond center'],
    [5, 0.5, 0.5, 1, 'triangle center'],
    [6, 0.5, 0.5, 1, 'star center'],
    [7, 0.75, 0.5, 0.6065306597126334, 'soft gaussian'],
    [99, 0.75, 0.5, 0.6065306597126334, 'unknown shape uses soft gaussian'],
) {
    close_to(
        Math::Fractal::Noisemaker::DrawOps::billboard_shape_alpha(@$case[0 .. 2]),
        $case->[3],
        "billboard $case->[4] alpha",
    );
}

my $billboard_xyz = Math::Fractal::Noisemaker::Surface->new(1, 1, [0.4375, 0.5625, 0, 1]);
my $billboard_rgba = Math::Fractal::Noisemaker::Surface->new(1, 1, [1, 0, 0, 1]);
my $sprite = Math::Fractal::Noisemaker::Surface->new(1, 1, [1, 1, 1, 1]);
my $billboard_dest = Math::Fractal::Noisemaker::Surface->new(8, 8);
my $billboard = Math::Fractal::Noisemaker::DrawOps::get_draw_op('render/pointsBillboardRender', 'deposit');
ok(ref $billboard eq 'CODE', 'billboard scatter adapter is registered');
$billboard->({
    pass        => { blend => 1 },
    uniforms    => {
        %view_uniforms,
        seed => 42, shapeMode => 3, depositOpacity => 100,
        sizeVariation => 0, rotationVar => 0, pointSize => 1,
    },
    inputs      => { xyzTex => $billboard_xyz, rgbaTex => $billboard_rgba, spriteTex => $sprite },
    destination => $billboard_dest,
});
my $billboard_offset = (3 * 8 + 3) * 4;
is_deeply(
    [@{ $billboard_dest->data }[$billboard_offset .. $billboard_offset + 3]],
    [1, 0, 0, 1],
    'billboard rasterizer shades the covered pixel',
);

done_testing();
