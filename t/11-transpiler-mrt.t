use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Math::Fractal::Noisemaker::KernelCache;
use Math::Fractal::Noisemaker::PassRunner ();
use Math::Fractal::Noisemaker::Runtime;
use Math::Fractal::Noisemaker::Surface;
use Math::Fractal::Noisemaker::Transpiler::Codegen qw(emit_perl);
use Math::Fractal::Noisemaker::Transpiler::Parser qw(parse);
use Math::Fractal::Noisemaker::Transpiler::Preprocess qw(normalize);

my $glsl = <<'GLSL';
#version 300 es
precision highp float;
layout(location = 1) out vec4 outVel;
layout(location = 0) out vec4 outXYZ;
void main() {
    outXYZ = vec4(1.0, 2.0, 3.0, 4.0);
    outVel = vec4(10.0, 20.0, 30.0, 40.0);
}
GLSL

my $normalized = normalize($glsl, {});
is_deeply(
    $normalized->{outputs},
    ['outXYZ', 'outVel'],
    'layout outputs are ordered by numeric location, not declaration order',
);

my $source = emit_perl(parse($normalized->{source}), $normalized->{outputs}, $normalized->{varyings});
my $compiled = Math::Fractal::Noisemaker::KernelCache::load_kernel($source, 'mrt-test');
is_deeply($compiled->{output_names}, ['outXYZ', 'outVel'], 'compiled kernel advertises MRT output order');

my $ctx = Math::Fractal::Noisemaker::Ctx->new(
    rt => Math::Fractal::Noisemaker::Runtime->new,
    uniforms => {}, textures => {}, resolution => [1, 1],
    time => 0, seed => 1, blank => Math::Fractal::Noisemaker::Surface->new(1, 1),
);
my $out = [(0) x 8];
$compiled->{kernel}->($ctx, $out);
is_deeply($out, [1, 2, 3, 4, 10, 20, 30, 40], 'kernel writes one RGBA chunk per MRT output');

my $inout_glsl = <<'GLSL';
#version 300 es
precision highp float;
out vec4 fragColor;
float bump(inout float seed) {
    seed += 1.0;
    return seed * 2.0;
}
vec2 direction(inout float seed) {
    seed += 1.0;
    return vec2(seed, seed * 2.0);
}
void main() {
    float seed = 1.0;
    float scalarValue = bump(seed) + seed;
    seed = 1.0;
    vec2 vectorValue = vec2(1.0) + direction(seed) * 0.5;
    fragColor = vec4(scalarValue, vectorValue, seed);
}
GLSL
my $inout_normalized = normalize($inout_glsl, {});
my $inout_source = emit_perl(
    parse($inout_normalized->{source}),
    $inout_normalized->{outputs},
    $inout_normalized->{varyings},
);
my $inout_kernel = Math::Fractal::Noisemaker::KernelCache::load_kernel($inout_source, 'inout-expression-test');
my $inout_out = [(0) x 4];
$inout_kernel->{kernel}->($ctx, $inout_out);
is_deeply(
    $inout_out,
    [6, 2, 3, 2],
    'nested scalar and vector inout calls yield their return values and update their arguments',
);

my $navier_normalized = normalize(<<'GLSL', {}, 'synth/navierStokes:nsSplat');
vec2 hash22(vec2 p) {
    p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
    return p;
}
GLSL
like(
    $navier_normalized->{source},
    qr/p\.x = dot\(p, vec2\(127\.1, 311\.7\)\); p\.y = dot\(p, vec2\(269\.5, 183\.3\)\);/,
    'Navier-Stokes normalization preserves pinned CPU left-to-right vector assignment',
);

done_testing();
