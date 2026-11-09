use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Math::Fractal::Noisemaker::Renderer qw(render_dsl render_effect meta);

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
    my %params = (iterationCount => 1);
    # The smallest declared values keep the smoke test fast.
    for my $name (qw(iterations zoom)) {
        my $spec = meta()->{effects}{$effect_id}{params}{$name} or next;
        $params{$name} = $spec->{min} // 1;
    }
    my $surface = render_effect(
        $effect_id, \%params, {},
        width => 4, height => 4, seed => 1, time => 0.25,
    );
    assert_surface($surface, $effect_id);
}

for my $name (qw(attractor buddhabrot dla flock flow hydraulic lenia life physarum physical)) {
    my $program = "search synth, render, points\n"
        . "solid().pointsEmit(stateSize: 64, iterationCount: 1)"
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
        . "solid().pointsEmit(stateSize: 64, iterationCount: 1).$case->[0].write(o0)\n"
        . "render(o0)\n";
    assert_surface(
        render_dsl($program, width => 4, height => 4, seed => 1, time => 0.25),
        $case->[1],
    );
}

# The loop accumulator is chain-scoped (upstream scopes a global that
# different effects share by chain): a chain's second loopBegin/loopEnd region
# continues the first region's feedback surface instead of a zeroed one.
{
    my $single = render_dsl(
        "search synth, render\nperlin(seed: 1).loopBegin().loopEnd().write(o0)\nrender(o0)",
        width => 4, height => 4, seed => 1, time => 0.25,
    );
    my $pair = render_dsl(
        "search synth, render\nperlin(seed: 1).loopBegin().loopEnd().loopBegin().loopEnd().write(o0)\nrender(o0)",
        width => 4, height => 4, seed => 1, time => 0.25,
    );
    my $same = @{ $pair->data } == @{ $single->data }
        && !grep { $pair->data->[$_] != $single->data->[$_] } 0 .. $#{ $pair->data };
    ok($same, 'two loop regions in one chain share the chain-scoped accumulator');
}

{
    # A step between the two regions makes the shared feedback observable: the
    # second region reads the first region's accumulator, which still holds
    # the pre-invert image, so the chain is not the flattened
    # fresh-per-region form.
    my $shared = render_dsl(
        "search synth, filter, render\n"
            . "perlin(seed: 1).loopBegin(alpha: 100).loopEnd().invert().loopBegin(alpha: 100).loopEnd().write(o0)\nrender(o0)",
        width => 4, height => 4, seed => 1, time => 0.25,
    );
    my $fresh = render_dsl(
        "search synth, filter, render\n"
            . "perlin(seed: 1).loopBegin(alpha: 100).loopEnd().write(o1)\nread(o1).invert().loopBegin(alpha: 100).loopEnd().write(o0)\nrender(o0)",
        width => 4, height => 4, seed => 1, time => 0.25,
    );
    my $same = @{ $shared->data } == @{ $fresh->data }
        && !grep { $shared->data->[$_] != $fresh->data->[$_] } 0 .. $#{ $shared->data };
    ok(!$same,
        'a step between two loop regions reads the shared accumulator, not a fresh zeroed one');
}

# Different stateful effects in one chain size from their own zoom: the
# reactionDiffusion state keeps the chain-scoped size, the cellularAutomata
# instance gets its own. Each inline chain renders as its flattened
# per-instance form.
{
    my $inline = render_dsl(
        "search synth, mixer\n"
            . "reactionDiffusion(zoom: x4).blendMode(tex: cellularAutomata(zoom: x16)).write(o0)\nrender(o0)",
        width => 4, height => 4, seed => 1, time => 0.25,
    );
    my $flat = render_dsl(
        "search synth, mixer\n"
            . "cellularAutomata(zoom: x16).write(o2)\n"
            . "reactionDiffusion(zoom: x4).blendMode(tex: read(o2)).write(o0)\nrender(o0)",
        width => 4, height => 4, seed => 1, time => 0.25,
    );
    my $same = @{ $inline->data } == @{ $flat->data }
        && !grep { $inline->data->[$_] != $flat->data->[$_] } 0 .. $#{ $inline->data };
    ok($same, 'a stateful subchain renders as its flattened per-instance form');
}

# Port of the remaining stateful-chain-instances cases: every stateful
# instance in a chain keeps its own state and zoom size, so a chain with
# repeated stateful instances renders the same bytes as its flattened
# per-instance program.
sub flat_same {
    my ($inline_src, $flat_src, $name) = @_;
    my $inline = render_dsl($inline_src, width => 8, height => 8, seed => 1, time => 0.25);
    my $flat   = render_dsl($flat_src,   width => 8, height => 8, seed => 1, time => 0.25);
    my $same = @{ $inline->data } == @{ $flat->data }
        && !grep { $inline->data->[$_] != $flat->data->[$_] } 0 .. $#{ $inline->data };
    ok($same, $name);
}

flat_same(
    "search synth, mixer\n"
        . "reactionDiffusion(zoom: x4).blendMode(tex: reactionDiffusion(zoom: x16)).write(o0)\nrender(o0)",
    "search synth, mixer\n"
        . "reactionDiffusion(zoom: x16).write(o2)\n"
        . "reactionDiffusion(zoom: x4).blendMode(tex: read(o2)).write(o0)\nrender(o0)",
    'two reactionDiffusion instances keep their own state and zoom',
);

flat_same(
    "search synth, mixer\n"
        . "noise(seed: 1).blendMode(tex: reactionDiffusion(zoom: x4)).blendMode(tex: reactionDiffusion(zoom: x16)).write(o0)\nrender(o0)",
    "search synth, mixer\n"
        . "reactionDiffusion(zoom: x4).write(o2)\n"
        . "reactionDiffusion(zoom: x16).write(o3)\n"
        . "noise(seed: 1).blendMode(tex: read(o2)).blendMode(tex: read(o3)).write(o0)\nrender(o0)",
    'two reactionDiffusion chain arguments keep their own state',
);

flat_same(
    "search synth, mixer\n"
        . "reactionDiffusion(zoom: x4).blendMode(tex: reactionDiffusion()).blendMode(tex: reactionDiffusion(zoom: x16)).write(o0)\nrender(o0)",
    "search synth, mixer\n"
        . "reactionDiffusion().write(o2)\n"
        . "reactionDiffusion(zoom: x16).write(o3)\n"
        . "reactionDiffusion(zoom: x4).blendMode(tex: read(o2)).blendMode(tex: read(o3)).write(o0)\nrender(o0)",
    'repeated state preserves each explicit or default zoom',
);

flat_same(
    "search synth, filter\n"
        . "noise(seed: 1).watercolor().watercolor().write(o0)\nrender(o0)",
    "search synth, filter\n"
        . "noise(seed: 1).watercolor().write(o1)\n"
        . "read(o1).watercolor().write(o0)\nrender(o0)",
    'repeated stateful filters keep independent ping-pong state',
);

flat_same(
    "search synth, mixer\n"
        . "noise(seed: 1).blendMode(tex: reactionDiffusion(zoom: x4)).blendMode(tex: cellularAutomata(zoom: x16)).write(o0)\nrender(o0)",
    "search synth, mixer\n"
        . "cellularAutomata(zoom: x16).write(o2)\n"
        . "reactionDiffusion(zoom: x4).write(o3)\n"
        . "noise(seed: 1).blendMode(tex: read(o3)).blendMode(tex: read(o2)).write(o0)\nrender(o0)",
    'mixed stateful chain arguments size from their own zoom',
);

flat_same(
    "search render\n"
        . "meshLoader().meshRender().meshRender().write(o0)\nrender(o0)",
    "search render\n"
        . "meshLoader().meshRender().write(o1)\n"
        . "read(o1).meshRender().write(o0)\nrender(o0)",
    'repeated mesh renderers keep the loader mesh',
);

{
    my $out = render_dsl(
        "search render\n"
            . "meshLoader().write(o0)\n"
            . "read(o0).meshRender().meshRender().write(o1)\nrender(o1)",
        width => 8, height => 8, seed => 1, time => 0.25,
    );
    my $bad = grep { !($_ == $_) || abs($_) == 9**9**9 } @{ $out->data };
    is($bad, 0, 'the loader works with a repeated meshRender in another chain');
}

done_testing();
