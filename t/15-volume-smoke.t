use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Math::Fractal::Noisemaker::Renderer qw(meta render_dsl);

my @new_effects = qw(
    classicNoisedeck/noise3d
    classicNoisedeck/shapes3d
    filter3d/flow3d
    filter3d/palette3d
    render/loopBegin
    render/loopEnd
    render/render3d
    render/renderCubemap3d
    render/renderCubemapSurface
    render/renderLit3d
    synth3d/cell3d
    synth3d/cellularAutomata3d
    synth3d/flythrough3d
    synth3d/fractal3d
    synth3d/noise3d
    synth3d/reactionDiffusion3d
    synth3d/shape3d
);

my $effects = meta()->{effects};
is_deeply(
    [grep { exists $effects->{$_} } @new_effects],
    \@new_effects,
    'all 17 newly ported effects are present',
);

sub call_for {
    my ($effect_id) = @_;
    my $effect = $effects->{$effect_id};
    my @args;
    push @args, 'volumeSize: 2' if exists(($effect->{params} || {})->{volumeSize});
    push @args, 'iterationCount: 1' if exists(($effect->{params} || {})->{iterationCount});
    push @args, 'type: 1' if $effect_id eq 'synth3d/flythrough3d';
    return $effect->{func} . '(' . join(', ', @args) . ')';
}

sub program_for {
    my ($effect_id) = @_;
    my $effect = $effects->{$effect_id};
    my $call = call_for($effect_id);
    my $domain = $effect->{domain} || 'image';
    if ($domain eq 'loop-begin' || $domain eq 'loop-end') {
        my $begin = $domain eq 'loop-begin' ? $call : 'loopBegin(iterationCount: 1)';
        my $end = $domain eq 'loop-end' ? $call : 'loopEnd()';
        return "search synth, render\nsolid().$begin.$end.write(o0)\nrender(o0)";
    }
    if ($domain eq 'volume-generator') {
        return "search synth3d, render\n$call.render3d().write(o0)\nrender(o0)";
    }
    if ($domain eq 'volume-filter') {
        return "search synth3d, filter3d, render\n"
            . "noise3d(volumeSize: 2).$call.render3d().write(o0)\nrender(o0)";
    }
    if ($domain eq 'volume-renderer') {
        return "search synth3d, render\nnoise3d(volumeSize: 2).$call.write(o0)\nrender(o0)";
    }
    return "search synth, classicNoisedeck\n$call.write(o0)\nrender(o0)"
        if $effect->{kind} eq 'generator';
    return "search synth, classicNoisedeck\nsolid().$call.write(o0)\nrender(o0)";
}

for my $effect_id (@new_effects) {
    my $surface = eval {
        render_dsl(program_for($effect_id), width => 2, height => 2, seed => 1, time => 0.25);
    };
    ok($surface, "$effect_id renders") or do {
        diag($@);
        next;
    };
    is_deeply([$surface->width, $surface->height], [2, 2], "$effect_id output dimensions");
    my $bad = grep { !($_ == $_) || abs($_) == 9**9**9 } @{ $surface->data };
    is($bad, 0, "$effect_id output is finite");
}

done_testing();
