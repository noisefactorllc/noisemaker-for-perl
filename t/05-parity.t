use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Spec;
use File::Temp ();

# Cross-language parity: Perl renders must match the JS oracle byte-for-byte
# on a fast subset (the full 167-effect sweep lives in scripts/parity.pl).

use Math::Fractal::Noisemaker::PNG qw(decode_png encode_png);
use Math::Fractal::Noisemaker::Renderer qw(render_effect);

my $CPU_DIR = $ENV{NOISEMAKER_CPU_DIR}
    || File::Spec->rel2abs(File::Spec->catdir($FindBin::Bin, '..', '..', 'noisemaker-cpu'));
my $CLI = File::Spec->catfile($CPU_DIR, 'bin', 'noisemaker-cpu.js');

plan skip_all => 'JS oracle (node + noisemaker-cpu) not available'
    unless -e $CLI && system('node --version >/dev/null 2>&1') == 0;

my $TMP = File::Temp::tempdir(CLEANUP => 1);

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

# filter over the oracle's default solid
$js = js_effect('filter/invert');
my $solid = render_effect('synth/solid', {}, undef, width => 8, height => 8, seed => 1, time => 0.25);
$pl = render_effect('filter/invert', {}, { inputTex => $solid },
    width => 8, height => 8, seed => 1, time => 0.25);
is(max_diff($js, $pl), 0, 'filter/invert byte-exact');

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

done_testing();
