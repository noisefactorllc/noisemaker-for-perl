use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP qw(decode_json);

use Math::Fractal::Noisemaker::KernelCache;
use Math::Fractal::Noisemaker::PassRunner ();
use Math::Fractal::Noisemaker::Runtime;
use Math::Fractal::Noisemaker::Surface;
use Math::Fractal::Noisemaker::Transpiler::Codegen qw(emit_perl);
use Math::Fractal::Noisemaker::Transpiler::Parser qw(parse);
use Math::Fractal::Noisemaker::Transpiler::Preprocess qw(normalize);

# Where the oracle's compiled JS rounds float vector arithmetic to f32: fused
# inline arithmetic, Float32Array#map, vecN.op, swizzles and spreads of calls,
# vector returns and arguments of user functions, declarations and indexed
# stores. The fixture holds each
# shader, its inputs and the oracle's float32 output bits (see its
# capturedFrom), in a form every port can load.
my $fixture = do {
    open my $fh, '<:raw', "$FindBin::Bin/data/rounding-model.json"
        or die "cannot read rounding-model.json: $!";
    local $/;
    decode_json(scalar <$fh>);
};

my $rt = Math::Fractal::Noisemaker::Runtime->new;
for my $case (@{ $fixture->{cases} }) {
    my $norm = normalize($case->{shader}, {});
    my $kernel = Math::Fractal::Noisemaker::KernelCache::load_kernel(
        emit_perl(parse($norm->{source}), $norm->{outputs}, $norm->{varyings}), 'rounding-model');
    my @got;
    for my $u (@{ $fixture->{inputs} }) {
        my %uniforms = map { $_ => (ref $u->{$_} ? [@{ $u->{$_} }] : $u->{$_}) } keys %$u;
        my $ctx = Math::Fractal::Noisemaker::Ctx->new(
            rt => $rt, uniforms => \%uniforms, textures => {}, resolution => [1, 1],
            time => 0, seed => 1, blank => Math::Fractal::Noisemaker::Surface->new(1, 1),
        );
        my $out = [(0) x 4];
        $kernel->{kernel}->($ctx, $out);
        push @got, [map { unpack('L', pack('f', $_)) } @$out[0 .. 2]];
    }
    is_deeply(\@got, $case->{expected}, $case->{label});
}

done_testing();
