use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP ();

use Math::Fractal::Noisemaker::DSL qw(tokenize_dsl parse_dsl compile_dsl);
use Math::Fractal::Noisemaker::Renderer qw(render_dsl);

my $effects = do {
    my $path = "$FindBin::Bin/../lib/Math/Fractal/Noisemaker/bundle/metadata.json";
    open my $fh, '<:raw', $path or die "cannot read bundle metadata $path: $!";
    local $/;
    JSON::PP->new->utf8->decode(scalar <$fh>)->{effects};
};

# Volume effects for the write3d/read3d forms (same shape as t/06-dsl.t).
my $typed_effects = {
    %$effects,
    'synth3d/noise3d' => {
        namespace => 'synth3d', func => 'noise3d', kind => 'generator',
        domain => 'volume-generator', params => {}, paramOrder => [], passes => [],
    },
    'synth3d/cellularAutomata3d' => {
        namespace => 'synth3d', func => 'cellularAutomata3d', kind => 'generator',
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
};

sub err_str {
    my ($code) = @_;
    my $ok = eval { $code->(); 1 };
    return $ok ? '' : "$@";
}

# Normalized steps for comparisons: effect_id + params, without loc. A subchain
# block splices its body calls into the parent chain, which shifts the source
# columns, so loc values legitimately differ between the two programs.
sub normalized_steps {
    my ($plan) = @_;
    return [
        map { [ $_->{effect_id}, $_->{params} // {} ] }
            grep { $_->{kind} eq 'effect' } @{ $plan->{chains}[0]{steps} }
    ];
}

# --- subchain: mid-chain subchain equals the plain program --------------------
# Port of upstream test/dsl-subchain.test.js: a subchain block compiles to the
# same steps and the same rendered bytes as its plain equivalent.
{
    my $with_subchain
        = "search synth, filter\nnoise().subchain() { .posterize(levels: 2) }.blur().write(o0)\nrender(o0)";
    my $plain
        = "search synth, filter\nnoise().posterize(levels: 2).blur().write(o0)\nrender(o0)";

    my $plan_with    = compile_dsl($with_subchain, $effects);
    my $plan_without = compile_dsl($plain, $effects);

    is_deeply(
        normalized_steps($plan_with),
        normalized_steps($plan_without),
        'compile: subchain program has the same effect_id and params as its plain equivalent',
    );

    my $render_with    = render_dsl($with_subchain,    width => 4, height => 4, seed => 1);
    my $render_without = render_dsl($plain,            width => 4, height => 4, seed => 1);
    is($render_with->to_rgba8, $render_without->to_rgba8,
        'render: subchain program renders the same bytes as its plain equivalent');
}

# --- write3d and read3d grammar forms ----------------------------------------
# Port of upstream test/dsl-grammar-forms.test.js REJECTED entries: every
# rejected form reports an existing message template.
{
    # One-argument write3d(vol) has no comma between the references.
    like(
        err_str(sub { parse_dsl("search synth3d, render\nnoise3d().write3d(vol0)\nrender(o0)") }),
        qr/Expected ","/,
        'reject: write3d(vol0) without a second reference reports Expected ","',
    );

    # Named arguments are not parseWriteCall's positional form.
    like(
        err_str(sub { parse_dsl("search synth3d, render\nnoise3d().write3d(tex3d: vol0, geo: geo0)\nrender(o0)") }),
        qr/Expected ","/,
        'reject: write3d(tex3d: vol0, geo: geo0) reports Expected ","',
    );

    # A non-identifier, non-surface first reference is rejected.
    like(
        err_str(sub { parse_dsl("search synth3d, render\nnoise3d().write3d(5, geo0)\nrender(o0)") }),
        qr/Expected surface reference/,
        'reject: write3d(5, geo0) reports Expected surface reference',
    );

    # A mid-chain read3d(vol, geo) is not a starter and is not an effect.
    like(
        err_str(sub {
            compile_dsl(
                "search synth3d, render\nnoise3d().write3d(vol0, geo0)\n"
                    . "noise3d().read3d(vol0, geo0).render3d().write(o0)\nrender(o0)",
                $typed_effects,
            );
        }),
        qr/Unknown effect "read3d" in search namespaces synth3d, render/,
        'reject: mid-chain read3d(vol0, geo0) reports Unknown effect "read3d"',
    );

    # Upstream's lexer reserves write3d, so it cannot start a chain.
    like(
        err_str(sub { compile_dsl("search synth3d, render\nwrite3d(vol0, geo0)\nrender(o0)", $typed_effects) }),
        qr/Expected effect or IO function name/,
        'reject: chain-start write3d(vol0, geo0) reports Expected effect or IO function name',
    );

    # A one-argument read3d(vol) mid-chain stays an unknown effect.
    like(
        err_str(sub {
            compile_dsl(
                "search synth3d, render\nnoise3d().write3d(vol0, geo0)\n"
                    . "read3d(vol0).render3d().write(o0)\nrender(o0)",
                $typed_effects,
            );
        }),
        qr/Unknown effect "read3d"/,
        'reject: one-argument mid-chain read3d(vol0) reports Unknown effect "read3d"',
    );

    # The accepted form: write3d(vol0, geo0) then read3d(vol0, geo0) restores it.
    my $plan = compile_dsl(
        "search synth3d, render\nnoise3d().write3d(vol0, geo0)\nread3d(vol0, geo0).render3d().write(o0)\nrender(o0)",
        $typed_effects,
    );
    is_deeply(
        [map { $_->{kind} } map { @{ $_->{steps} } } @{ $plan->{chains} }],
        ['effect', 'write3d', 'read3d', 'effect', 'write'],
        'accept: write3d(vol0, geo0) stores and read3d(vol0, geo0) restores the volume',
    );
}

# --- from() grammar forms -----------------------------------------------------
# Port of upstream test/dsl-grammar-forms.test.js: a from() call that resolves
# becomes the inner effect with its namespace; one the authority rejects stays a
# call named `from`, an unknown effect.
{
    # The accepted form: from(namespace, call()) resolves the inner effect.
    my $ast = parse_dsl("search synth\nnoise().from(filter, invert()).write(o0)\nrender(o0)");
    is($ast->{chains}[0]{calls}[1]{name},     'invert', 'accept: from(filter, invert()) resolves the inner effect');
    is($ast->{chains}[0]{calls}[1]{namespace}, 'filter', 'accept: from() records the namespace');

    # Named-argument form stays an unknown `from` call.
    like(
        err_str(sub { compile_dsl("search synth, filter\nfrom(ns: classicNoisedeck, call: noise()).write(o0)\nrender(o0)", $effects) }),
        qr/Unknown effect "from" in search namespaces synth, filter/,
        'reject: from(ns: ..., call: ...) reports Unknown effect "from"',
    );

    # A single-argument from() stays an unknown `from` call.
    like(
        err_str(sub { compile_dsl("search synth, filter\nfrom(classicNoisedeck).write(o0)\nrender(o0)", $effects) }),
        qr/Unknown effect "from" in search namespaces synth, filter/,
        'reject: from(classicNoisedeck) reports Unknown effect "from"',
    );

    # A string namespace is not an identifier.
    like(
        err_str(sub { compile_dsl("search synth, filter\nfrom(\"classicNoisedeck\", noise()).write(o0)\nrender(o0)", $effects) }),
        qr/Unknown effect "from" in search namespaces synth, filter/,
        'reject: from("classicNoisedeck", noise()) reports Unknown effect "from"',
    );

    # A bare identifier target is not a call.
    like(
        err_str(sub { compile_dsl("search synth, filter\nfrom(classicNoisedeck, noise).write(o0)\nrender(o0)", $effects) }),
        qr/Unknown effect "from" in search namespaces synth, filter/,
        'reject: from(classicNoisedeck, noise) reports Unknown effect "from"',
    );

    # A multi-call chain target is not a single call.
    like(
        err_str(sub { compile_dsl("search synth, filter\nfrom(classicNoisedeck, noise().invert()).write(o0)\nrender(o0)", $effects) }),
        qr/Unknown effect "from" in search namespaces synth, filter/,
        'reject: from(classicNoisedeck, noise().invert()) reports Unknown effect "from"',
    );

    # The namespace restricts resolution: noise is not in filter.
    like(
        err_str(sub { compile_dsl("search synth, filter\nfrom(filter, noise()).write(o0)\nrender(o0)", $effects) }),
        qr/Unknown effect "noise" in search namespaces filter/,
        'reject: from(filter, noise()) reports Unknown effect "noise" in search namespaces filter',
    );
}

done_testing();
