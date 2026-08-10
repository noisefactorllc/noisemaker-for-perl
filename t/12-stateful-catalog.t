use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use File::Spec;
use JSON::PP ();
use Math::Fractal::Noisemaker::DrawOps ();
use Math::Fractal::Noisemaker::Renderer qw(bundle_dir meta);
use Math::Fractal::Noisemaker::Transpiler::Build ();

my @stateful = qw(
    filter/convolutionFeedback
    filter/feedback
    filter/motionBlur
    filter/temporalAberration
    points/attractor
    points/buddhabrot
    points/dla
    points/flock
    points/flow
    points/hydraulic
    points/lenia
    points/life
    points/physarum
    points/physical
    render/pointsBillboardRender
    render/pointsEmit
    render/pointsRender
    synth/cellularAutomata
    synth/mnca
    synth/navierStokes
    synth/reactionDiffusion
);

my $effects = meta()->{effects};
is(scalar(keys %$effects), 188, 'bundle exposes the 188-effect canonical catalog');
is_deeply(
    [sort grep { $effects->{$_}{iterated} } keys %$effects],
    \@stateful,
    'the exact 21 new definitions are marked iterated',
);

for my $effect_id (@stateful) {
    my $effect = $effects->{$effect_id};
    ok($effect, "$effect_id is present");
    ok(exists $effect->{params}{iterationCount}, "$effect_id exposes iterationCount");
    for my $pass (@{ $effect->{passes} || [] }) {
        if ($pass->{drawMode}) {
            ok(
                Math::Fractal::Noisemaker::DrawOps::get_draw_op($effect_id, $pass->{program}),
                "$effect_id:$pass->{program} has a native scatter adapter",
            );
            next;
        }
        ok($pass->{key}, "$effect_id:$pass->{program} has a kernel key");
        (my $file = $pass->{key}) =~ s{[/:]}{__}g;
        ok(
            -f File::Spec->catfile(bundle_dir(), 'kernels', 'perl', "$file.pl"),
            "$effect_id:$pass->{program} has a generated Perl kernel",
        );
    }
}

is(
    $effects->{'synth/navierStokes'}{passes}[3]{repeat},
    'iterations',
    'pass repeat metadata is preserved',
);
is_deeply(
    $effects->{'render/pointsBillboardRender'}{passes}[2]{conditions},
    { runIf => [{ uniform => 'blendMode', equals => 0 }] },
    'pass condition metadata is preserved',
);
is(
    $effects->{'points/life'}{passes}[1]{drawBuffers},
    4,
    'MRT draw-buffer count is preserved',
);

my $old_bundle = {
    provenance => {
        statefulRevision => $Math::Fractal::Noisemaker::Transpiler::Build::STATEFUL_REVISION,
    },
    effects => {
        'synth/statefulFixture' => { iterated => JSON::PP::true, passes => [] },
        'synth/legacyFixture'   => { passes => [] },
    },
};
my $rebuilt = { provenance => {}, effects => {} };
is(
    Math::Fractal::Noisemaker::Transpiler::Build::_preserve_stateful($rebuilt, $old_bundle),
    $Math::Fractal::Noisemaker::Transpiler::Build::STATEFUL_REVISION,
    'bundle rebuild preserves the authored stateful revision',
);
is_deeply(
    [sort keys %{ $rebuilt->{effects} }],
    ['synth/statefulFixture'],
    'bundle rebuild carries only pinned stateful definitions forward',
);
is(
    $rebuilt->{provenance}{statefulRevision},
    $Math::Fractal::Noisemaker::Transpiler::Build::STATEFUL_REVISION,
    'bundle rebuild emits the stateful revision in metadata',
);

my $stale = {
    provenance => { statefulRevision => 'stale' },
    effects    => { 'synth/statefulFixture' => { iterated => JSON::PP::true } },
};
eval {
    Math::Fractal::Noisemaker::Transpiler::Build::_preserve_stateful(
        { provenance => {}, effects => {} }, $stale,
    );
};
like($@, qr/expected \Q$Math::Fractal::Noisemaker::Transpiler::Build::STATEFUL_REVISION\E/,
    'bundle rebuild rejects stateful definitions from a different revision');

done_testing();
