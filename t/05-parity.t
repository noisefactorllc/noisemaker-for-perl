use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../scripts";
use ParityOracle qw(verify_oracle);
use File::Spec;
use File::Temp ();

# Cross-language parity: Perl renders must match the JS oracle byte-for-byte
# on a fast subset (the full 167-image-effect sweep lives in scripts/parity.pl).

use Math::Fractal::Noisemaker::PNG qw(decode_png encode_png);
use Math::Fractal::Noisemaker::Renderer qw(render_effect);
use Math::Fractal::Noisemaker::Surface;

my $CPU_DIR = $ENV{NOISEMAKER_CPU_DIR}
    || File::Spec->rel2abs(File::Spec->catdir($FindBin::Bin, '..', '..', 'noisemaker-for-cpu'));
my $CLI = File::Spec->catfile($CPU_DIR, 'bin', 'noisemaker-cpu.js');
my $PARITY_SCRIPT = File::Spec->catfile($FindBin::Bin, '..', 'scripts', 'parity.pl');

plan skip_all => 'JS oracle (node + noisemaker-cpu) not available'
    unless $ENV{RELEASE_TESTING} || (-e $CLI && system('node --version >/dev/null 2>&1') == 0);

my $verified = eval { verify_oracle($CPU_DIR); 1 };
BAIL_OUT("Reference verification failed: $@") unless $verified;
pass('reference runtime matches the recorded oracle pin');

my $TMP = File::Temp::tempdir(CLEANUP => 1);

{
    local $ENV{NOISEMAKER_CPU_DIR} = File::Spec->catdir($TMP, 'missing-oracle');
    my $status = system($^X, $PARITY_SCRIPT, '--only', 'synth/solid');
    isnt($status, 0, 'parity harness fails when the JS oracle is unavailable');
}

my $unknown_status = system($^X, $PARITY_SCRIPT, '--only', 'not/an-effect');
isnt($unknown_status, 0, 'parity harness fails when no requested effect exists');

my $mixed_status = system($^X, $PARITY_SCRIPT, '--only', 'synth/solid,not/an-effect');
isnt($mixed_status, 0, 'parity harness fails when any requested effect is unknown');

sub js_effect {
    my ($effect_id, @extra) = @_;
    my $out = File::Spec->catfile($TMP, 'js.png');
    my @cmd = (
        'node', $CLI, 'effect', $effect_id,
        '--width', 8, '--height', 8, '--seed', 1, '--time', 0.25,
        '--output', $out, @extra,
    );
    system(join(' ', map { quotemeta } @cmd) . ' >/dev/null 2>&1') == 0 or die "oracle failed\n";
    open my $fh, '<:raw', $out or die $!;
    local $/;
    return decode_png(scalar <$fh>);
}

sub js_apply {
    my ($effect_id, $input, @extra) = @_;
    my $in  = File::Spec->catfile($TMP, 'input.png');
    my $out = File::Spec->catfile($TMP, 'js-apply.png');
    open my $input_fh, '>:raw', $in or die $!;
    print {$input_fh} encode_png($input);
    close $input_fh;
    my @cmd = (
        'node', $CLI, 'apply', $effect_id, $in,
        '--width', 8, '--height', 8, '--seed', 1, '--time', 0.25,
        '--output', $out, @extra,
    );
    system(join(' ', map { quotemeta } @cmd) . ' >/dev/null 2>&1') == 0 or die "oracle failed\n";
    open my $output_fh, '<:raw', $out or die $!;
    local $/;
    return decode_png(scalar <$output_fh>);
}

sub max_diff {
    my ($a, $b) = @_;
    my @x = unpack 'C*', $a->to_rgba8;
    my @y = unpack 'C*', $b->to_rgba8;
    my $d = 0;
    for my $i (0 .. $#x) { my $v = abs($x[$i] - $y[$i]); $d = $v if $v > $d }
    return $d;
}

# generator with params
my $js = js_effect('synth/solid', '--param', 'color=#4080c0');
my $pl = render_effect('synth/solid', { color => '#4080c0' }, undef,
    width => 8, height => 8, seed => 1, time => 0.25);
is(max_diff($js, $pl), 0, 'synth/solid byte-exact');

$js = js_effect('synth/solid', '--param', 'color=[1,0,0,0.1]', '--param', 'alpha=0.6');
$pl = render_effect('synth/solid', { color => [1, 0, 0, 0.1], alpha => 0.6 }, undef,
    width => 8, height => 8, seed => 1, time => 0.25);
is(max_diff($js, $pl), 0, 'RGBA color retains the separate alpha parameter and matches CPU bytes');

# filter over the oracle's default solid
$js = js_effect('filter/invert');
my $solid = render_effect('synth/solid', {}, undef, width => 8, height => 8, seed => 1, time => 0.25);
$pl = render_effect('filter/invert', {}, { inputTex => $solid },
    width => 8, height => 8, seed => 1, time => 0.25);
is(max_diff($js, $pl), 0, 'filter/invert byte-exact');

# A varying input exercises octaveWarp's coordinate hash conversion; a solid
# input does not expose a warp difference.
my @pattern;
for my $y (0 .. 7) {
    for my $x (0 .. 7) {
        push @pattern, ($x * 32) / 255, ($y * 31) / 255,
            ((($x * 3 + $y * 5) % 8) * 29) / 255, 1;
    }
}
my $pattern = Math::Fractal::Noisemaker::Surface->new(8, 8, \@pattern);
$js = js_apply('filter/octaveWarp', $pattern,
    '--seed', '3', '--param', 'displacement=0.35', '--param', 'antialias=false');
$pl = render_effect('filter/octaveWarp', { seed => 3, displacement => 0.35, antialias => 0 },
    { inputTex => $pattern }, width => 8, height => 8, seed => 3, time => 0.25);
is(max_diff($js, $pl), 0, 'filter/octaveWarp varying-input warp is CPU byte-exact');

$js = js_apply('filter/degauss', $pattern,
    '--param', 'displacement=0.2');
$pl = render_effect('filter/degauss', { displacement => 0.2 },
    { inputTex => $pattern }, width => 8, height => 8, seed => 1, time => 0.25);
is(max_diff($js, $pl), 0, 'filter/degauss varying-input warp is CPU byte-exact');

# seeded generator (uint hash path)
$js = js_effect('synth/noise');
$pl = render_effect('synth/noise', {}, undef, width => 8, height => 8, seed => 1, time => 0.25);
is(max_diff($js, $pl), 0, 'synth/noise byte-exact');

# Stateful generator with an omitted nullable surface. The CPU runtime binds
# the canonical zero surface rather than inheriting a prior pass result.
$js = js_effect(
    'synth/navierStokes',
    '--param', 'iterationCount=1', '--param', 'iterations=4', '--param', 'zoom=1',
);
$pl = render_effect(
    'synth/navierStokes', { iterationCount => 1, iterations => 4, zoom => 1 }, {},
    width => 8, height => 8, seed => 1, time => 0.25,
);
cmp_ok(max_diff($js, $pl), '<=', 2, 'synth/navierStokes nullable input matches CPU');

# e86e1c6-era upstream semantics: for effects whose passes carry `repeat`
# (synth/navierStokes, synth/reactionDiffusion, synth3d/reactionDiffusion3d)
# the pass repeat IS the per-frame iteration count, so the group loop must not
# multiply it again — iterationCount 1 and 4 must render byte-identically
# (a requested 0 still bypasses all passes).
my $ns_one = render_effect(
    'synth/navierStokes', { iterationCount => 1, iterations => 2, zoom => 1 }, {},
    width => 8, height => 8, seed => 1, time => 0.25,
);
my $ns_four = render_effect(
    'synth/navierStokes', { iterationCount => 4, iterations => 2, zoom => 1 }, {},
    width => 8, height => 8, seed => 1, time => 0.25,
);
is(max_diff($ns_one, $ns_four), 0, 'navierStokes group loop does not multiply pass repeat');

# The pinned generated CPU kernel intentionally leaves empty history slots at
# zero; this is a source-compatibility check for the canonical artifact.
my $temporal_input = render_effect(
    'synth/solid', { color => '#336699' }, undef,
    width => 8, height => 8, seed => 1, time => 0.25,
);
$js = js_apply(
    'filter/temporalAberration', $temporal_input,
    '--param', 'iterationCount=2',
);
$pl = render_effect(
    'filter/temporalAberration', { iterationCount => 2 }, { inputTex => $temporal_input },
    width => 8, height => 8, seed => 1, time => 0.25,
);
is(max_diff($js, $pl), 0, 'filter/temporalAberration history is CPU byte-exact');

for my $effect_id (qw(filter/mosaicTiles filter/stipple filter/strokes)) {
    $js = js_effect($effect_id);
    $pl = render_effect($effect_id, {}, { inputTex => $solid },
        width => 8, height => 8, seed => 1, time => 0.25);
    is(max_diff($js, $pl), 0, "$effect_id canonical rounding byte-exact");
}

done_testing();
