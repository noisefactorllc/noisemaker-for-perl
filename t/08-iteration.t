use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Math::Fractal::Noisemaker::Iteration qw(
    compute_iteration_groups
    is_particle_state_name
    iteration_delta_time
    wrap01
);

sub effect_step {
    my ($effect_id, $params) = @_;
    return { kind => 'effect', effect_id => $effect_id, params => ($params || {}) };
}

my $effects = {
    'render/pointsEmit' => {
        iterated => 1,
        textures => { global_xyz => {}, global_vel => {}, global_rgba => {} },
        passes => [{
            inputs  => { xyzTex => 'global_xyz' },
            outputs => { outXYZ => 'global_xyz', fragColor => 'outputTex' },
        }],
    },
    'points/flock' => {
        iterated => 1,
        textures => {},
        passes => [{
            inputs  => { xyzTex => 'global_xyz' },
            outputs => { outXYZ => 'global_xyz' },
        }],
    },
    'filter/blur' => {
        iterated => 0,
        textures => {},
        passes => [{ inputs => { inputTex => 'inputTex' }, outputs => { fragColor => 'outputTex' } }],
    },
    'synth/reactionDiffusion' => {
        iterated => 1,
        textures => { global_rd_state => {} },
        passes => [{
            inputs  => { bufTex => 'global_rd_state' },
            outputs => { fragColor => 'global_rd_state' },
        }],
    },
    'render/loopBegin' => {
        iterated => 1,
        loopRole => 'begin',
        textures => {},
        passes => [{
            inputs  => { inputTex => 'inputTex', accumTex => 'global_accum' },
            outputs => { fragColor => 'outputTex' },
        }],
    },
    'render/loopEnd' => {
        loopRole => 'end',
        textures => {},
        passes => [{
            inputs  => { inputTex => 'inputTex' },
            outputs => { fragColor => 'global_accum' },
        }],
    },
};

ok(is_particle_state_name('global_xyz'), 'global_xyz is shared particle state');
ok(is_particle_state_name('global_life_data'), 'global_life_data is shared particle state');
ok(is_particle_state_name('global_color_trail'), 'global_*_trail is shared particle state');
ok(!is_particle_state_name('global_rd_state'), 'private global state is not particle state');
ok(!is_particle_state_name('outputTex'), 'ordinary output is not particle state');

my $groups = compute_iteration_groups([
    effect_step('render/pointsEmit', { iterationCount => 5 }),
    effect_step('points/flock'),
    effect_step('filter/blur'),
    effect_step('synth/reactionDiffusion'),
], $effects);
is_deeply(
    [map { [$_->{iterated} ? 1 : 0, scalar @{ $_->{steps} }] } @$groups],
    [[1, 2], [0, 1], [1, 1]],
    'particle segment groups while ordinary and private-state effects stay isolated',
);

$groups = compute_iteration_groups([
    effect_step('render/pointsEmit'),
    effect_step('render/pointsEmit'),
    effect_step('points/flock'),
], $effects);
is_deeply(
    [map { [$_->{iterated} ? 1 : 0, scalar @{ $_->{steps} }] } @$groups],
    [[1, 1], [1, 2]],
    'each pointsEmit opens a fresh particle group',
);

$groups = compute_iteration_groups([
    effect_step('render/pointsEmit'),
    { kind => 'write', surface => 'o1' },
    { kind => 'read', surface => 'o1' },
    effect_step('points/flock'),
], $effects);
is_deeply(
    [map { [$_->{iterated} ? 1 : 0, scalar @{ $_->{steps} }] } @$groups],
    [[1, 1], [0, 1], [0, 1], [1, 1]],
    'read and write steps close particle groups',
);

$groups = compute_iteration_groups([
    effect_step('filter/blur'),
    effect_step('render/loopBegin', { iterationCount => 3 }),
    effect_step('filter/blur'),
    effect_step('render/loopEnd'),
    effect_step('filter/blur'),
], $effects);
is_deeply(
    [map { [$_->{iterated} ? 1 : 0, $_->{loop} ? 1 : 0, scalar @{ $_->{steps} }] } @$groups],
    [[0, 0, 1], [1, 1, 3], [0, 0, 1]],
    'balanced loop region becomes one iteration-owned group',
);

eval { compute_iteration_groups([effect_step('render/loopEnd')], $effects) };
like($@, qr/loopEnd has no matching loopBegin/, 'iteration grouping rejects unmatched loopEnd');
eval {
    compute_iteration_groups([
        effect_step('render/loopBegin'),
        { kind => 'write', surface => 'o0' },
    ], $effects);
};
like($@, qr/Loop iteration group cannot cross a read\/write boundary/,
    'iteration grouping rejects read/write inside a loop');
eval {
    compute_iteration_groups([
        effect_step('render/loopBegin'),
        effect_step('render/loopBegin'),
        effect_step('render/loopEnd'),
    ], $effects);
};
like($@, qr/Nested loop iteration groups are not supported/,
    'iteration grouping rejects nested loops');
eval { compute_iteration_groups([effect_step('render/loopBegin')], $effects) };
like($@, qr/loopBegin has no matching loopEnd/, 'iteration grouping rejects unmatched loopBegin');

cmp_ok(abs(iteration_delta_time() - 1 / 600), '<', 1e-15, 'fixed iteration delta is 1/600');
cmp_ok(abs(wrap01(-0.25) - 0.75), '<', 1e-15, 'wrap01 wraps negative values');
cmp_ok(abs(wrap01(1.25) - 0.25), '<', 1e-15, 'wrap01 wraps values above one');

done_testing();
