#!/usr/bin/env perl

# Render this export's program on the CPU and write a PNG.
#
# Puts the vendored port in `engine/lib` on the module path and calls it
# directly, so nothing has to be installed: this file plus `engine/` is the
# whole program. `render_dsl` compiles the DSL and evaluates it pixel by pixel;
# `encode_png` turns the resulting surface into bytes.

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/engine/lib";

use Getopt::Long qw(GetOptionsFromArray);
use Math::Fractal::Noisemaker::Renderer qw(render_dsl);
use Math::Fractal::Noisemaker::PNG qw(encode_png);

my $USAGE = <<'END';
Usage: perl run.pl [PROGRAM.dsl] [options]

  --width N     output width in pixels (default: 512)
  --height N    output height in pixels (default: 512)
  --seed N      deterministic seed (default: 1)
  --time N      normalized time (default: 0)
  --output FILE PNG to write (default: art.png)
  --help        show this message
END

my @argv = @ARGV;
my ($width, $height, $seed, $time_value, $output, $help) = (512, 512, 1, 0.0, 'art.png', 0);
GetOptionsFromArray(
    \@argv,
    'width=i'  => \$width,
    'height=i' => \$height,
    'seed=i'   => \$seed,
    'time=f'   => \$time_value,
    'output=s' => \$output,
    'help'     => \$help,
) or die $USAGE;

if ($help) {
    print $USAGE;
    exit 0;
}

my $program = shift(@argv) || 'program.dsl';
open my $in, '<', $program or die "cannot read $program: $!\n";
my $source = do { local $/; <$in> };
close $in;

my $surface = render_dsl(
    $source,
    width  => $width,
    height => $height,
    seed   => $seed,
    time   => $time_value,
);

open my $out, '>:raw', $output or die "cannot write $output: $!\n";
print {$out} encode_png($surface);
close $out or die "cannot write $output: $!\n";

printf "Rendered %dx%d -> %s\n", $surface->width, $surface->height, $output;
