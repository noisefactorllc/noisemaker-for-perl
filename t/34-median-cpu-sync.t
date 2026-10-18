use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Digest::SHA qw(sha256_hex);
use Math::Fractal::Noisemaker::Renderer qw(render_dsl);
use Math::Fractal::Noisemaker::Surface;

# Direct CpuRenderer captures at 4aeb3e1e028b2dc412401f7b7f17c014c603bf14.
# Input is the same procedural 6x5 surface as t/17, explicitly stored as f32;
# it enters through seedSurfaces, without PNG or RGBA8 input quantization.
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
@data = unpack('f<*', pack('f<*', @data));
my $input = Math::Fractal::Noisemaker::Surface->new($width, $height, \@data);
is(sha256_hex(pack('f<*', @data)),
   '55fd0944449d222b5fae63017007c82c3403d83c8fd3c085156a74b7a68082ff',
   'input bytes match the physical CPU Float32Array');
for my $radius (1 .. 3) {
    my $result = render_dsl(
        "search filter\nread(o0).median(radius: $radius).write(o7)\nrender(o7)",
        width => $width, height => $height, seed_surfaces => { o0 => $input },
    );
    open my $fh, '<:raw', "$FindBin::Bin/data/cpu-adapter-sync/median-radius-$radius.rgba" or die $!;
    local $/;
    my $expected = <$fh>;
    is_deeply([unpack('C*', $result->to_rgba8)], [unpack('C*', $expected)],
              "median radius $radius matches every CPU output byte");
}
# Direct medianFactory probes retain negative packed channels, threshold
# decisions and varying alpha, before render-target half-float quantization.
my @signed_data = unpack('f<*', pack('f<*', -0.5,0.25,0.5,0.3, 0.2,-0.125,0.75,0.6, 0.75,0.125,-0.25,0.9));
my $signed_input = Math::Fractal::Noisemaker::Surface->new(3, 1, \@signed_data);
for my $case (
    [0, [3204448256,1048576000,1056964608,1050253722,3204448256,1048576000,1056964608,1058642330,
         1061158912,1040187392,3196059648,1063675494]],
    [100, [3204448256,1048576000,1056964608,1050253722,1045220557,3187671040,1061158912,1058642330,
           1061158912,1040187392,3196059648,1063675494]],
) {
    my ($threshold, $expected_bits) = @$case;
    my $rt = Math::Fractal::Noisemaker::Runtime->new;
    my $ctx = Math::Fractal::Noisemaker::Ctx->new(
        rt => $rt, uniforms => { RADIUS => 3, threshold => $threshold },
        textures => { inputTex => $signed_input }, resolution => [3, 1],
    );
    my $adapter = Math::Fractal::Noisemaker::Adapters::get_adapter('filter/median', 'median')->($rt, {});
    my $actual = Math::Fractal::Noisemaker::PassRunner::run_pass($adapter, $ctx, 3, 1);
    is_deeply([unpack('L<*', pack('f<*', @{$actual->data}))], $expected_bits,
              "negative channels, threshold $threshold and original alpha match CPU bits");
}
done_testing;
