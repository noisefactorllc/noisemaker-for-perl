#!/usr/bin/env perl
use strict;
use warnings;
use lib 'lib';
use Test::More;

use Math::Fractal::Noisemaker::Runtime;

# Mirrors upstream be8ed4cd: a declared sampler that the pass lists no input
# for reads transparent black (the backends bind their default texture), and
# a binding that exists but is not a Surface stays an error.
subtest 'an unbound sampler reads transparent black' => sub {
    my $rt = Math::Fractal::Noisemaker::Runtime->new;
    is_deeply($rt->texture(undef, [0.25, 0.75]), [0.0, 0.0, 0.0, 0.0],
        'texture(undef) reads transparent black');
    # textureLod lowers to $rt->texture(...) (Transpiler/Codegen.pm), so the
    # same guard covers it; the second call below exercises that same path.
    is_deeply($rt->texture(undef, [0.25, 0.75]), [0.0, 0.0, 0.0, 0.0],
        'texture(undef) again (textureLod lowers to texture) reads transparent black');
    is_deeply($rt->texel_fetch(undef, [0, 0]), [0.0, 0.0, 0.0, 0.0],
        'texelFetch(undef) reads transparent black');
};

subtest 'a non-Surface sampler binding still fails' => sub {
    my $rt = Math::Fractal::Noisemaker::Runtime->new;
    my $fake = { width => 2 };

    eval { $rt->texture($fake, [0.25, 0.75]) };
    like($@, qr/GLSL texture sampler must be a Surface/,
        'texture(non-surface) throws');

    eval { $rt->texel_fetch($fake, [0, 0]) };
    like($@, qr/GLSL texelFetch sampler must be a Surface/,
        'texelFetch(non-surface) throws');
};

done_testing();
