use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Math::Fractal::Noisemaker::Renderer qw(render_dsl render_effect);

sub assert_surface {
    my ($surface, $name) = @_;
    is($surface->width, 4, "$name renders at the requested width");
    is($surface->height, 4, "$name renders at the requested height");
    my $bad = grep { !($_ == $_) || abs($_) == 9**9**9 } @{ $surface->data };
    is($bad, 0, "$name produces finite pixels");
}

my $solid = render_effect(
    'synth/solid', {}, undef,
    width => 4, height => 4, seed => 1, time => 0.25,
);

my $temporal_input = Math::Fractal::Noisemaker::Surface->new(1, 1, [0.2, 0.4, 0.6, 1]);
my $temporal = render_effect(
    'filter/temporalAberration', { iterationCount => 2 }, { inputTex => $temporal_input },
    width => 1, height => 1, seed => 1, time => 0.25,
);
is_deeply(
    $temporal->data,
    [0.199951171875, 0, 0, 1],
    'temporal history initialization matches the pinned CPU kernel at two iterations',
);

for my $effect_id (qw(
    filter/convolutionFeedback
    filter/feedback
    filter/motionBlur
    filter/temporalAberration
)) {
    my $surface = render_effect(
        $effect_id, { iterationCount => 1 }, { inputTex => $solid },
        width => 4, height => 4, seed => 1, time => 0.25,
    );
    assert_surface($surface, $effect_id);
}

for my $effect_id (qw(
    synth/cellularAutomata
    synth/mnca
    synth/navierStokes
    synth/reactionDiffusion
)) {
    my $surface = render_effect(
        $effect_id, { iterationCount => 1, iterations => 1, zoom => 1 }, {},
        width => 4, height => 4, seed => 1, time => 0.25,
    );
    assert_surface($surface, $effect_id);
}

for my $name (qw(attractor buddhabrot dla flock flow hydraulic lenia life physarum physical)) {
    my $program = "search synth, render, points\n"
        . "solid().pointsEmit(stateSize: 2, iterationCount: 1)"
        . ".$name(iterationCount: 1)"
        . ".pointsRender(iterationCount: 1).write(o0)\n"
        . "render(o0)\n";
    assert_surface(
        render_dsl($program, width => 4, height => 4, seed => 1, time => 0.25),
        "points/$name",
    );
}

for my $case (
    ['pointsRender(iterationCount: 1)', 'render/pointsRender'],
    ['pointsBillboardRender(shapeMode: 3, pointSize: 1, iterationCount: 1)',
        'render/pointsBillboardRender'],
) {
    my $program = "search synth, render\n"
        . "solid().pointsEmit(stateSize: 2, iterationCount: 1).$case->[0].write(o0)\n"
        . "render(o0)\n";
    assert_surface(
        render_dsl($program, width => 4, height => 4, seed => 1, time => 0.25),
        $case->[1],
    );
}

done_testing();
