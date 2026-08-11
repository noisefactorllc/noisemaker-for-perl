use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP ();

use Math::Fractal::Noisemaker::DSL qw(tokenize_dsl parse_dsl compile_dsl);
use Math::Fractal::Noisemaker::Renderer qw(render_dsl);

# Port of the pure tokenizer/parser/compiler tests in noisemaker-python
# tests/test_dsl.py (rendering-oracle tests excluded), plus a few render_dsl
# integration checks. Compile tests run against the real bundle metadata,
# exactly as the Python tests pass _meta()["effects"].

my $effects = do {
    my $path = "$FindBin::Bin/../lib/Math/Fractal/Noisemaker/bundle/metadata.json";
    open my $fh, '<:raw', $path or die "cannot read bundle metadata $path: $!";
    local $/;
    JSON::PP->new->utf8->decode(scalar <$fh>)->{effects};
};

# Run $code, returning '' on success or the stringified exception.
sub err_str {
    my ($code) = @_;
    my $ok = eval { $code->(); 1 };
    return $ok ? '' : "$@";
}

# --- tokenizer: lexeme classification ---------------------------------------

{
    my $tokens = tokenize_dsl("search synth\nnoise(scaleX: 8).write(o0)");
    my %types = map { $_->{type} => 1 } @$tokens;
    ok($types{keyword}, 'tokenize: keyword classified (search)');
    ok($types{surface}, 'tokenize: surface classified (o0)');
    is($tokens->[-1]{type}, 'eof', 'tokenize: stream ends with eof');
    my $color = tokenize_dsl('#3af')->[0];
    is($color->{type},   'color', 'tokenize: color token type');
    is($color->{lexeme}, '#3af',  'tokenize: color token lexeme');
}

# --- parser: program shape ---------------------------------------------------

{
    my $ast = parse_dsl("search synth, filter\nsolid(color: #336699).invert().write(o0)\nrender(o0)");
    is_deeply($ast->{search}, ['synth', 'filter'], 'parse: search namespaces');
    is(scalar @{ $ast->{chains} }, 1, 'parse: one chain');
    is_deeply(
        [map { $_->{name} } @{ $ast->{chains}[0]{calls} }],
        ['solid', 'invert', 'write'],
        'parse: chain call names'
    );
    is($ast->{render}{name}, 'o0', 'parse: render surface');
}

{
    my $ast = parse_dsl("search render\nrender(o0)");
    is_deeply($ast->{search}, ['render'], 'parse: reserved render token is valid in search namespace list');
}

# --- compiler: resolution + surface split ------------------------------------

{
    my $plan = compile_dsl("search synth, mixer\nnoise().cellSplit(tex: o1).write(o0)\nrender(o0)", $effects);
    my $step = $plan->{chains}[0]{steps}[1];
    is($step->{effect_id}, 'mixer/cellSplit', 'compile: effect id resolved through search');
    is_deeply($step->{surfaces}{tex}, ['surface', 'o1'], 'compile: surface param split to marker');
}

{
    my $plan = compile_dsl("search synth\nsolid().write(o3)", $effects);
    is($plan->{render_surface}, 'o3', 'compile: render surface defaults to last write');
}

# --- error paths -------------------------------------------------------------

{
    my $ok = eval { compile_dsl("solid().write(o0)\nrender(o0)", $effects); 1 };
    my $err = $@;
    ok(!$ok, 'error: missing search directive dies');
    isa_ok($err, 'Math::Fractal::Noisemaker::DSL::Error', 'error object');
    like("$err", qr/^<dsl>:\d+:\d+: Missing required search directive\n$/,
        'error: located, newline-terminated message');
}

like(
    err_str(sub { compile_dsl("search synth\nwat().write(o0)\nrender(o0)", $effects) }),
    qr/Unknown effect "wat" in search namespaces synth/,
    'error: unknown effect'
);
like(
    err_str(sub { compile_dsl("search synth\nnoise(bogus: 1).write(o0)\nrender(o0)", $effects) }),
    qr/Unknown parameter "bogus" for synth\/noise; accepted: type, octaves, scaleX, scaleY, seed, wrap, ridges, loopOffset, loopScale, speed, colorMode/,
    'error: unknown parameter lists accepted params in paramOrder'
);
like(
    err_str(sub { compile_dsl("search synth\nnoise()\nrender(o0)", $effects) }),
    qr/Generator chain must end with write/,
    'error: generator chain must end with write'
);
like(
    err_str(sub { parse_dsl("search synth\nnoise(4, seed: 2).write(o0)") }),
    qr/Cannot mix positional and named arguments/,
    'error: cannot mix positional and named arguments'
);
like(
    err_str(sub { parse_dsl("search synth\nnoise().write(o9)") }),
    qr/Surface reference must be o0 through o7/,
    'error: surface reference out of range'
);
like(
    err_str(sub { tokenize_dsl("noise(scaleX: 1e)") }),
    qr/Invalid numeric literal "1e"/,
    'error: malformed numeric literal is a DslError'
);

# --- typed volume and loop chains ------------------------------------------

my $typed_effects = {
    %$effects,
    'synth3d/noise3d' => {
        namespace => 'synth3d', func => 'noise3d', kind => 'generator',
        domain => 'volume-generator', params => {}, paramOrder => [], passes => [],
    },
    'synth3d/reactionDiffusion3d' => {
        namespace => 'synth3d', func => 'reactionDiffusion3d', kind => 'generator',
        domain => 'volume-generator', iterated => 1,
        params => { iterationCount => { type => 'int', default => 60 } },
        paramOrder => ['iterationCount'], passes => [],
    },
    'synth3d/shape3d' => {
        namespace => 'synth3d', func => 'shape3d', kind => 'generator',
        domain => 'volume-generator', params => {}, paramOrder => [], passes => [],
    },
    'filter3d/palette3d' => {
        namespace => 'filter3d', func => 'palette3d', kind => 'filter',
        domain => 'volume-filter', params => {}, paramOrder => [], passes => [],
    },
    'render/render3d' => {
        namespace => 'render', func => 'render3d', kind => 'filter',
        domain => 'volume-renderer', params => {}, paramOrder => [], passes => [],
    },
    'render/loopBegin' => {
        namespace => 'render', func => 'loopBegin', kind => 'filter',
        domain => 'loop-begin', loopRole => 'begin', iterated => 1,
        params => { iterationCount => { type => 'int', default => 60 } },
        paramOrder => ['iterationCount'], passes => [],
    },
    'render/loopEnd' => {
        namespace => 'render', func => 'loopEnd', kind => 'filter',
        domain => 'loop-end', loopRole => 'end', params => {}, paramOrder => [], passes => [],
    },
};

{
    my $plan = compile_dsl(
        "search synth3d, filter3d, render\n"
            . "noise3d().palette3d().render3d().write(o0)\nrender(o0)",
        $typed_effects,
    );
    is_deeply(
        [map { $_->{effect_id} } grep { $_->{kind} eq 'effect' } @{ $plan->{chains}[0]{steps} }],
        ['synth3d/noise3d', 'filter3d/palette3d', 'render/render3d'],
        'compile: typed volume generator/filter/renderer chain',
    );
}

{
    my $plan = compile_dsl(
        "search synth3d, render\n"
            . "noise3d().reactionDiffusion3d(iterationCount: 1).render3d().write(o0)\nrender(o0)",
        $typed_effects,
    );
    is($plan->{chains}[0]{steps}[1]{effect_id}, 'synth3d/reactionDiffusion3d',
        'compile: iterated volume generator can consume an upstream volume');
}

like(
    err_str(sub { compile_dsl("search synth3d\nnoise3d().shape3d().write(o0)", $typed_effects) }),
    qr/Generator synth3d\/shape3d must begin a chain/,
    'compile: ordinary volume generator cannot consume an upstream volume',
);
like(
    err_str(sub { compile_dsl("search synth, filter3d\nsolid().palette3d().write(o0)", $typed_effects) }),
    qr/volume filter filter3d\/palette3d requires a volume input/,
    'compile: volume filter requires a volume',
);
like(
    err_str(sub { compile_dsl("search synth3d\nnoise3d().write(o0)", $typed_effects) }),
    qr/write\(surface\) requires a current image/,
    'compile: volume-only chain cannot be written as an image',
);

{
    my $plan = compile_dsl(
        "search synth, filter, render\n"
            . "solid().loopBegin(iterationCount: 3).blur().loopEnd().write(o0)\nrender(o0)",
        $typed_effects,
    );
    is_deeply(
        [map { $typed_effects->{ $_->{effect_id} }{loopRole} || '' }
            grep { $_->{kind} eq 'effect' } @{ $plan->{chains}[0]{steps} }],
        ['', 'begin', '', 'end'],
        'compile: balanced loop region',
    );
}
like(
    err_str(sub { compile_dsl("search synth, render\nsolid().loopEnd().write(o0)", $typed_effects) }),
    qr/loopEnd has no matching loopBegin/,
    'compile: unmatched loopEnd is rejected',
);
like(
    err_str(sub { compile_dsl("search synth, render\nsolid().loopBegin().write(o0)", $typed_effects) }),
    qr/loopBegin must be closed by loopEnd before write/,
    'compile: open loop cannot cross write',
);
like(
    err_str(sub {
        compile_dsl(
            "search synth, render\nsolid().loopBegin().loopBegin().loopEnd().loopEnd().write(o0)",
            $typed_effects,
        );
    }),
    qr/nested loopBegin regions are not supported/,
    'compile: nested accumulator loops are rejected',
);

# --- render_dsl integration --------------------------------------------------

{
    my $surface = render_dsl("search synth\nsolid(color: #336699).write(o0)\nrender(o0)",
        width => 4, height => 4);
    my @bytes = unpack('C*', $surface->to_rgba8);
    is_deeply([@bytes[0 .. 3]], [0x33, 0x66, 0x99, 0xFF], 'render: solid exact color bytes');
}

{
    my $surface = render_dsl(
        "search synth, filter\nnoise(seed: 3, scaleX: 8, scaleY: 8).vignette().write(o0)\nrender(o0)",
        width => 8, height => 8, seed => 3);
    is($surface->width,  8, 'render: generator+filter chain width');
    is($surface->height, 8, 'render: generator+filter chain height');
}

like(
    err_str(sub {
        render_dsl("search synth, filter\nread(o5).invert().write(o0)\nrender(o0)",
            width => 4, height => 4);
    }),
    qr/Surface o5 has not been written/,
    'render: read of unwritten surface dies'
);

# let value + partial bindings merge into a chain call (python: test_render_let_value_and_partial_bindings)
{
    my $program = "search synth, filter\n"
        . "let amt = 3\n"
        . "let base = noise(scaleX: 7, scaleY: 7)\n"
        . "base(seed: 11).posterize(levels: amt).write(o0)\n"
        . "render(o0)\n";
    my $plan = compile_dsl($program, $effects);
    my $step = $plan->{chains}[0]{steps}[0];
    is($step->{effect_id}, 'synth/noise', 'partial resolves to the bound effect');
    is($step->{params}{seed}, 11, 'call args merge over partial args');
    is($step->{params}{scaleX}, 7, 'partial args survive the merge');
    my $post = $plan->{chains}[0]{steps}[1];
    is($post->{params}{levels}, 3, 'let value binding substitutes into args');
    my $surface = render_dsl($program, width => 8, height => 8, seed => 1);
    is($surface->width, 8, 'let/partial program renders');
}

# arithmetic + vector/array values (python: test_arithmetic_and_array_values_render)
{
    my $plan = compile_dsl(
        "search synth\nnoise(scaleX: 4 * 2, scaleY: 16 / 2, seed: 3).write(o0)\nrender(o0)", $effects);
    my $step = $plan->{chains}[0]{steps}[0];
    is($step->{params}{scaleX}, 8, 'binary arithmetic evaluates');
    is($step->{params}{scaleY}, 8, 'division evaluates');
    my $surface = render_dsl(
        "search synth\nsolid(color: [0.2, 0.4, 0.6]).write(o0)\nrender(o0)",
        width => 2, height => 2);
    my @px = unpack 'C4', $surface->to_rgba8;
    is_deeply([@px[0 .. 2]], [51, 102, 153], 'array color value renders');
}

done_testing();
