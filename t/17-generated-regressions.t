use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Digest::SHA qw(sha256_hex);

use Math::Fractal::Noisemaker::Renderer qw(render_dsl render_effect);
use Math::Fractal::Noisemaker::Surface;

my $dither = render_dsl(
    "search synth, filter\nnoise(seed: 1, ridges: true).dither(type: errorDiffusion).write(o0)\nrender(o0)",
    width => 8, height => 8, time => 0.25,
);
is(
    sha256_hex($dither->to_rgba8),
    '0665d7edb18d3e61a4e6731369c881b045145ca6d0a709ccf070319b0a6f8dc7',
    'error-diffusion dither matches the pinned CPU frame',
);

my ($width, $height) = (6, 5);
my @data;
for my $y (0 .. $height - 1) {
    for my $x (0 .. $width - 1) {
        push @data,
            (((31 * $x + 17 * $y + 7) % 97) + 1) / 101,
            (((13 * $x + 37 * $y + 11) % 89) + 2) / 97,
            (((43 * $x + 5 * $y + 3) % 83) + 3) / 91,
            1;
    }
}
my $input = Math::Fractal::Noisemaker::Surface->new($width, $height, \@data);
my %expected = (
    1 => 'c977bad100bc84f0c6d14246860ab5084b4ce23208701cf88c51322c51335bda',
    2 => 'a36571e1856f4e964b4f14f3957915dcee87a9381e944f6104df329e6914bcd7',
    3 => '73d5a67ab88331c89b89f6e95fbb4fa63101e340e92e94ecc2e15a12f9f57b69',
);
for my $radius (1 .. 3) {
    my $program = "search filter\nread(o0).median(radius: $radius).write(o7)\nrender(o7)";
    my $result = render_dsl(
        $program, width => $width, height => $height, seed_surfaces => { o0 => $input },
    );
    is(sha256_hex($result->to_rgba8), $expected{$radius}, "median radius $radius matches CPU");
}

my $negative = Math::Fractal::Noisemaker::Surface->new(3, 3)->clear([-0.5, 0.25, 0.5, 1]);
my $negative_result = render_effect(
    'filter/median', { radius => 3 }, { inputTex => $negative }, width => 3, height => 3,
);
is_deeply([@{ $negative_result->data }[0 .. 3]], [-0.5, 0.25, 0.5, 1], 'median preserves negative packed channels');

done_testing();
