use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../scripts";
use ParityOracle qw(resolve_oracle);
use File::Spec;
use File::Temp ();

# Cross-language parity: renderLandscape3d's two filtering renders are the
# heavy tail of the cross-language parity harness (scripts/parity.pl runs
# minutes of Perl each), so they live in this sibling test file, which the
# sharded entrypoint runs as its own bounded shard.

use Math::Fractal::Noisemaker::PNG qw(decode_png);
use Math::Fractal::Noisemaker::Renderer qw(render_dsl);

# The oracle resolves in the same order scripts/parity-summary uses:
# NOISEMAKER_CPU_DIR when it verifies, then a sibling checkout, then the
# exact scripts/oracle-lock.json revision installed in the provisioning
# cache root, verified against the recorded runtime digest.
# An explicitly configured NOISEMAKER_CPU_DIR must verify: a wrong or
# tampered oracle stops the run. Without any configured oracle the parity
# cases skip until the environment provisions the pinned runtime.
my $configured = defined $ENV{NOISEMAKER_CPU_DIR};
my $CPU_DIR = eval { resolve_oracle() };
if ($configured && !$CPU_DIR) {
    BAIL_OUT('Reference verification failed: ' . ($@ || 'unknown resolution error'));
}
plan skip_all => 'pinned noisemaker-for-cpu oracle could not be resolved and verified: '
    . ($@ || 'no pinned noisemaker-for-cpu available')
    unless $CPU_DIR;
my $CLI = File::Spec->catfile($CPU_DIR, 'bin', 'noisemaker-cpu.js');

plan skip_all => 'JS oracle (node + noisemaker-cpu) not available'
    unless _quiet_system(undef, 'node', '--version') == 0;
pass('reference runtime matches the recorded oracle pin');

my $TMP = File::Temp::tempdir(CLEANUP => 1);

sub _quiet_system {
    my ($input, @cmd) = @_;
    open my $saved_in,  '<&', \*STDIN  or die "cannot save STDIN: $!\n";
    open my $saved_out, '>&', \*STDOUT or die "cannot save STDOUT: $!\n";
    open my $saved_err, '>&', \*STDERR or die "cannot save STDERR: $!\n";
    my $status;
    my $ok = eval {
        if (defined $input) {
            open STDIN, '<', $input or die "cannot redirect STDIN: $!\n";
        }
        open STDOUT, '>', File::Spec->devnull or die "cannot redirect STDOUT: $!\n";
        open STDERR, '>', File::Spec->devnull or die "cannot redirect STDERR: $!\n";
        $status = system { $cmd[0] } @cmd;
        1;
    };
    my $error = $@;
    open STDIN,  '<&', $saved_in  or die "cannot restore STDIN: $!\n";
    open STDOUT, '>&', $saved_out or die "cannot restore STDOUT: $!\n";
    open STDERR, '>&', $saved_err or die "cannot restore STDERR: $!\n";
    die $error unless $ok;
    return $status;
}

sub js_dsl {
    my ($source) = @_;
    my $in  = File::Spec->catfile($TMP, 'program.dsl');
    my $out = File::Spec->catfile($TMP, 'js-dsl.png');
    open my $program_fh, '>', $in or die $!;
    print {$program_fh} $source;
    close $program_fh;
    my @cmd = (
        'node', $CLI, 'render', '-',
        '--width', 8, '--height', 8, '--seed', 1, '--time', 0.25,
        '--output', $out,
    );
    _quiet_system($in, @cmd) == 0 or die "oracle failed\n";
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

# renderLandscape3d's isosurface filtering renders byte-exact against the
# reference. The voxel filtering case lives in t/05c-landscape3d-voxel.t:
# each case takes minutes of Perl, so they are separate bounded shards.
my $source = "search synth3d, render\nnoise3d(volumeSize: x16)"
    . ".renderLandscape3d(filtering: isosurface).write(o0)\nrender(o0)";
my $js = js_dsl($source);
my $pl = render_dsl($source, width => 8, height => 8, seed => 1, time => 0.25);
is(max_diff($js, $pl), 0, 'renderLandscape3d filtering: isosurface is CPU byte-exact');

done_testing();
