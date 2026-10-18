use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../scripts";
use File::Spec;
use File::Temp qw(tempdir);
use ParityOracle qw(verify_oracle);
use Math::Fractal::Noisemaker::PNG qw(decode_png);
use Math::Fractal::Noisemaker::Renderer qw(render_dsl);

my $cpu = $ENV{NOISEMAKER_CPU_DIR};
plan skip_all => 'pinned CPU source required for sync image cases'
    unless $ENV{RELEASE_TESTING} || (defined $cpu && -f "$cpu/bin/noisemaker-cpu.js");
$cpu ||= File::Spec->rel2abs("$FindBin::Bin/../../noisemaker-for-cpu");
verify_oracle($cpu);
my $tmp = tempdir(CLEANUP => 1);
my @cases = (
    ['perlin 3D', 'search synth\nperlin(dimensions: 3)', 41, 23, 13, 0.25],
    ['reaction diffusion volume', 'search synth3d, render\nreactionDiffusion3d(volumeSize: x16, iterationCount: 1, iterations: 1).render3d()', 8, 8, 13, 0.25],
    ['cellular automata volume', 'search synth3d, render\ncellularAutomata3d(volumeSize: x16, iterationCount: 1).render3d()', 8, 8, 7, 0.25],
    ['seeded noise volume', 'search synth3d, render\nnoise3d(volumeSize: x16).render3d()', 7, 5, 13, 0.25],
    ['seeded cell volume', 'search synth3d, render\ncell3d(volumeSize: x16).render3d()', 7, 5, 4, 0.25],
    ['scatter', 'search synth, filter\nnoise().scatter()', 41, 23, 7, 0.75],
    ['extrude', 'search synth, filter\nnoise().extrude()', 41, 23, 7, 0.75],
    ['spooky ticker', 'search synth, filter\nnoise().spookyTicker()', 41, 23, 7, 0.75],
);
for my $case (@cases) {
    my ($name, $source, $width, $height, $seed, $time) = @$case;
    $source =~ s/\\n/\n/g;
    $source .= ".write(o0)\nrender(o0)\n";
    open my $dsl, '>', "$tmp/program.dsl" or die $!;
    print {$dsl} $source;
    close $dsl or die $!;
    my $status = system('node', "$cpu/bin/noisemaker-cpu.js", 'render', "$tmp/program.dsl",
        '--width', $width, '--height', $height, '--seed', $seed, '--time', $time,
        '--output', "$tmp/cpu.png");
    is($status, 0, "$name CPU render succeeds");
    next if $status;
    open my $fh, '<:raw', "$tmp/cpu.png" or die $!;
    my $png = do { local $/; <$fh> };
    close $fh;
    my $expected = decode_png($png)->to_rgba8;
    my $actual = render_dsl($source, width => $width, height => $height,
        seed => $seed, time => $time)->to_rgba8;
    my @expected = unpack('C*', $expected);
    my @actual = unpack('C*', $actual);
    my $differences = abs(@expected - @actual);
    for my $i (0 .. $#expected) {
        $differences++ if !defined $actual[$i] || $expected[$i] != $actual[$i];
    }
    is($differences, 0, "$name matches CPU RGBA8 bytes");
}
done_testing();
