use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

# Render a representative slice of the catalog (no oracle needed): one
# generator and one filter per namespace, plus the native-adapter and
# draw-op effects. Checks dimensions, determinism, and that every pixel is
# finite.

use Math::Fractal::Noisemaker::Renderer qw(render_effect meta);

my @effects = qw(
    synth/solid synth/curl synth/noise
    filter/invert filter/vignette filter/crt filter/snow filter/palette
    filter/wormhole filter/stamp
    classicNoisedeck/noise classicNoisedeck/fractal
    mixer/blendMode
);

my $solid = render_effect('synth/solid', { color => '#4080c0' }, undef,
    width => 8, height => 8, seed => 1, time => 0.25);

for my $eid (@effects) {
    my $eff = meta()->{effects}{$eid};
    ok($eff, "$eid in bundle") or next;
    my $inputs = $eff->{kind} eq 'generator' ? {} : { inputTex => $solid };
    my $a = render_effect($eid, {}, $inputs, width => 8, height => 8, seed => 1, time => 0.25);
    is($a->width, 8, "$eid width");
    my $bad = grep { !($_ == $_) || $_ == 9**9**9 || $_ == -(9**9**9) } @{ $a->data };
    is($bad, 0, "$eid all pixels finite");
    my $b = render_effect($eid, {}, $inputs, width => 8, height => 8, seed => 1, time => 0.25);
    is($a->to_rgba8, $b->to_rgba8, "$eid deterministic");
}

# seed changes the look of seeded generators
my $s1 = render_effect('synth/noise', {}, undef, width => 8, height => 8, seed => 1, time => 0.25);
my $s2 = render_effect('synth/noise', {}, undef, width => 8, height => 8, seed => 2, time => 0.25);
isnt($s1->to_rgba8, $s2->to_rgba8, 'render seed threads into the seed param');

done_testing();
