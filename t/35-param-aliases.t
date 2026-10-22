use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../scripts";
use JSON::PP ();
use File::Temp ();

use Math::Fractal::Noisemaker::DSL qw(compile_dsl);
use Math::Fractal::Noisemaker::Renderer qw(render_dsl);

# Ports noisemaker-for-cpu test/param-aliases.test.js onto the DSL compiler:
# a deprecated alias migrates its value to the canonical name, the canonical
# name wins when both are supplied, every alias hit warns with the removal
# date, positional arguments stay untouched, and an unknown name still names
# the supplied spelling. Also regresses the two renderer behaviors this sync
# added: group-owner stateSize inheritance for inherit-sized base-color
# textures, and the source-order paramOrder of the regenerated points
# definitions against the pinned snapshot.

my $effects = do {
    my $path = "$FindBin::Bin/../lib/Math/Fractal/Noisemaker/bundle/metadata.json";
    open my $fh, '<:raw', $path or die "cannot read bundle metadata $path: $!";
    local $/;
    JSON::PP->new->utf8->decode(scalar <$fh>)->{effects};
};

my @warnings;
sub capture_warnings (&) {
    my ($code) = @_;
    @warnings = ();
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    return $code->();
}

sub dla_surfaces {
    my ($args) = @_;
    my $program = "search points, synth\nsolid().dla($args).write(o0)\nrender(o0)";
    my $plan = compile_dsl($program, $effects);
    return $plan->{chains}[0]{steps}[1];
}

# --- alias migration ---------------------------------------------------------

{
    my $step = capture_warnings { dla_surfaces('fieldTex: o1') };
    is_deeply($step->{surfaces}{heightTex}, ['surface', 'o1'],
        'alias: fieldTex migrates to the canonical heightTex surface binding');
    ok(!exists $step->{surfaces}{fieldTex}, 'alias: the alias name is consumed');
    like($warnings[0], qr/param 'fieldTex' is deprecated, use 'heightTex' instead\. Aliases will be removed on 2027-06-01\./,
        'alias: the deprecation warning carries the removal date');
}

# --- canonical name wins -----------------------------------------------------

{
    my $step = capture_warnings { dla_surfaces('heightTex: o1, fieldTex: o2') };
    is_deeply($step->{surfaces}{heightTex}, ['surface', 'o1'],
        'alias: the canonical name wins when both names are supplied');
    ok(!exists $step->{surfaces}{fieldTex}, 'alias: the alias is still consumed');
    like($warnings[0], qr/param 'fieldTex' is deprecated/,
        'alias: the alias hit still warns when the canonical name wins');
}

# --- positional arguments unchanged ------------------------------------------

{
    my $step = capture_warnings { dla_surfaces('o1') };
    is_deeply($step->{surfaces}{heightTex}, ['surface', 'o1'],
        'alias: positional arguments bind by paramOrder, untouched by aliases');
    is(scalar @warnings, 0, 'alias: positional arguments never warn');
}

# --- unknown names still fail naming the supplied spelling -------------------

{
    my $ok = eval { dla_surfaces('fieldTexx: o1'); 1 };
    my $err = $@ || '';
    ok(!$ok, 'alias: an unknown parameter name still fails');
    like($err, qr/Unknown parameter "fieldTexx" for points\/dla/,
        'alias: the error names the supplied spelling');
}

# --- source-order paramOrder for the regenerated points definitions ----------

SKIP: {
    my $oracle = eval {
        require ParityOracle;
        ParityOracle::resolve_oracle();
    };
    skip 'pinned noisemaker-for-cpu oracle required for the paramOrder source check', 9
        unless defined $oracle && -f "$oracle/src/effects/generated/upstream-snapshot.js";
    my $tmp = File::Temp->newdir;
    my $probe = "$tmp/snap-probe.mjs";
    my $snap_js = "$oracle/src/effects/generated/upstream-snapshot.js";
    $snap_js =~ s{'}{\\'}g;
    open my $fh, '>', $probe or die "cannot write $probe: $!";
    print {$fh} <<"EOP";
import { effectRecords } from 'file://$snap_js';
import { writeFileSync } from 'node:fs';
const ids = [
    'points/attractor', 'points/buddhabrot', 'points/dla', 'points/flock',
    'points/flow', 'points/hydraulic', 'points/lenia', 'points/physarum',
    'points/physical',
];
const out = {};
for (const id of ids) {
    const record = effectRecords.find((r) => r.id === id);
    out[id] = Object.keys(record.params);
}
writeFileSync(process.argv[2], JSON.stringify(out));
EOP
    close $fh or die $!;
    my $out = "$tmp/param-order.json";
    my $rc = system('node', $probe, $out);
    skip 'node unavailable for the paramOrder source check', 9 if $rc != 0;
    open my $json_fh, '<:raw', $out or die "cannot read $out: $!";
    local $/;
    my $source_order = JSON::PP->new->utf8->decode(scalar <$json_fh>);
    for my $eid (sort keys %$source_order) {
        is_deeply($effects->{$eid}{paramOrder}, $source_order->{$eid},
            "paramOrder matches the source definition order for $eid");
    }
}

# --- inherit-sized base-color textures resolve without throwing --------------

# A joined behavior's base-color memory sizes from the group owner's stateSize;
# a standalone inherit-sized behavior falls back to the shared particle size;
# a behavior with its own stateSize keeps its default. A destination-dimension
# mismatch inside the group makes the render throw, so the quiet joined render
# exercises the sizing path end to end, and the init-time param view pins the
# injected value on both paths.
{
    my $joined = "search points, render, synth\n"
        . "solid().pointsEmit(stateSize: 64, iterationCount: 1).flock().write(o0)\nrender(o0)";
    my $ok = eval { render_dsl($joined, width => 8, height => 8); 1 };
    ok($ok, "inherit-sized base-color texture: the joined render resolves without throwing ($@)");

    my $prepare = \&Math::Fractal::Noisemaker::Renderer::_prepare_state;
    my $joined_state = $prepare->(
        { effect_id => 'points/flock', params => {} }, 8, 8, 1, 64, {}, 0.0);
    is($joined_state->{params}{stateSize}, 64,
        'inherit-sized base-color texture: a joined step binds the owner stateSize');

    my $standalone_state = $prepare->(
        { effect_id => 'points/flock', params => {} }, 8, 8, 1, undef, {}, 0.0);
    is($standalone_state->{params}{stateSize}, 256,
        'inherit-sized base-color texture: a standalone step falls back to the shared particle size');

    my $own_state = $prepare->(
        { effect_id => 'points/dla', params => {} }, 8, 8, 1, undef, {}, 0.0);
    is($own_state->{params}{stateSize}, 256,
        'inherit-sized base-color texture: an effect with its own stateSize keeps its default');
}

done_testing();
