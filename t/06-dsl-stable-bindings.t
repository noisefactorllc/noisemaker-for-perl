use strict;
use warnings;
use Test::More;
use Math::Fractal::Noisemaker::DSL qw(compile_dsl parse_dsl);
use Math::Fractal::Noisemaker::Renderer qw(meta);

my $effects = meta()->{effects};
my $header = "search synth, synth3d, filter, mixer, render\n";
sub compile_body { compile_dsl($header . $_[0], $_[1] // $effects, { sourceName => 'saved.dsl' }) }
sub steps { compile_body(@_)->{chains}[0]{steps} }
sub rejects {
    my ($body, $pattern, $name) = @_;
    my $ok = eval { compile_body($body); 1 };
    like($ok ? '' : "$@", $pattern, $name);
}

subtest 'saved effect and I/O metadata' => sub {
    my $plan = eval { compile_body(<<'DSL') };
let base = noise(seed: 1, _id: "base_2")
base().subchain(name: "base", id: "block") { .invert(_id: 'flip') }.write(o1, _id: "w")
read(o1, _id: "r",).blendMode(tex: base(_id: "over")).write(o0)
read(surface: o1, _id: "again", _skip: true).write(o2)
noise3d().write3d(vol0, geo0, _id: "w3")
read3d(vol0, geo0, _id: "r3").render3d().write(o3)
read3d(_id: "named3", _skip: true, tex3d: vol0, geo: geo0).render3d().write(o4)
base().write(o5)
DSL
    is("$@", '', 'saved program compiles') or return;
    my @chains = map { $_->{steps} } @{ $plan->{chains} };
    is_deeply([map { [map { $_->{_id} } @$_] } @chains], [
        [qw(base_2 flip w)], ['r', undef, undef], ['again', undef], [undef, 'w3'],
        ['r3', undef, undef], ['named3', undef, undef], ['base_2', undef],
    ], 'metadata follows its authored step');
    ok($chains[2][0]{_skip} && $chains[5][0]{_skip}, 'both read types retain a true skip');
    my $inline = $chains[1][1]{inline_chains}[0]{chain}{steps}[0];
    is($inline->{_id}, 'over', 'an inline call overrides the stored ID');
    is_deeply($inline->{params}, {seed => 1}, 'metadata stays out of parameters');
    is_deeply(steps("noise().blendMode(tex: read(_id: 'r', tex: o1, _skip: true)).write(o0)")->[1]{surfaces}{tex},
              ['surface', 'o1'], 'a bare read with metadata supplies its texture');
    for my $value ('5', '1e999', '""', '"9a"', '"a-b"', '"_a"', 'alias', 'unknown()', 'true') {
        my $steps = steps("let alias = 'valid'\nlet n = noise(_id: 'base')\nn(_id: $value).write(o0, _id: $value)");
        ok(!grep(exists $_->{_id}, @$steps), "invalid ID $value is dropped without evaluating it");
    }
    is(steps("noise(_id: ('true'), _skip: (false)).write(o0)")->[0]{_id}, 'true', 'quoted boolean spelling is an ID');
    is(steps("let label = 'true'\nnoise().text(text: label).write(o0)")->[1]{params}{text}, 'true',
       'a quoted keyword stays a string through a let binding');
    ok(!exists steps('read(tex: o1, _skip: "true").write(o0)')->[0]{_skip}, 'quoted spelling is not the read skip flag');
    rejects('noise(_skip: 0).write(o0)', qr/Unknown parameter "_skip"/, 'numeric zero is not false metadata');
};

subtest 'commas and IO syntax' => sub {
    for my $case (
        ['solid(color: [1, 0.25, 0.5, /* end */],)', 'color', [1, 0.25, 0.5]],
        ['solid([1, 0.25, 0.5,],)', 'color', [1, 0.25, 0.5]],
        ['noise(3,)', 'type', 3], ['media(imageSize: vec2(32, 24,))', 'imageSize', [32, 24]],
        ['solid(color: vec3(1,0,0,))', 'color', [1,0,0]],
        ['solid(color: vec4(1,0,0,1,))', 'color', [1,0,0,1]],
    ) {
        my ($call, $name, $expected) = @$case;
        my $actual = eval { steps("$call.write(o0)")->[0]{params}{$name} };
        is_deeply($actual, $expected, $call) or diag "$@";
    }
    for my $call ('solid([1,,0])', 'solid([,1,0])', 'solid([1,0,,])', 'noise(,)', 'noise(12,,)', 'noise(scaleX: ,)') {
        rejects("$call.write(o0)", qr/Expected DSL value/, "missing element: $call");
    }
    for my $body ('noise(1, _id: "n").write(o0)', 'noise(seed: 1, 2).write(o0)', 'noise({seed: 1}).write(o0)',
                  q{noise(1 '+' 2).write(o0)},
                  'noise().write(o0,)', 'noise().write(surface: o0, _id: "x")', 'noise().write(o0, _id: "x",)',
                  'noise().write(o0, other: "x")', 'noise3d().write3d(vol0, geo0, other: "x")',
                  'read(o0, other: "x").write(o0)', 'read3d(vol0, geo0, other: "x").render3d().write(o0)') {
        rejects($body, qr/saved\.dsl:\d+:\d+:/, "rejects $body");
    }
    rejects('read3d(vol0, geo0, _id: "vol").write(o0)', qr/write\(surface\) requires a current image/,
            'a volume read alone does not produce an image');
};

subtest 'stable partial arguments keep their indexed slots' => sub {
    for my $case (
        ["let n = noise(seed: 7)\nlet alias = n", 'alias(3, 4)', {type => 3, octaves => 4, seed => 7}],
        ['let n = noise(3, 4)', 'n(seed: 7)', {type => 3, octaves => 4, seed => 7}],
        ['let n = noise(type: 11)', 'n(unknown(), 4)', {type => 11, octaves => 4}],
        ['let n = noise(noise(), 4)', 'n(type: 11)', {type => 11, octaves => 4}],
        ["let n = noise(seed: 7)\nlet tuned = n(3, 4)", 'tuned(type: 11)', {type => 11, octaves => 4, seed => 7}],
    ) {
        my ($prefix, $call, $expected) = @$case;
        my $step = eval { steps("$prefix\n$call.write(o0)")->[0] };
        is_deeply($step && $step->{params}, $expected, $call) or diag "$@";
        ok(!$step || !exists $step->{inline_chains}, 'overridden expressions do not create an inline surface');
    }
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    for my $call ('solid(#f00, 1, unknown())', "let red = solid(#f00)\nred(1, noise())") {
        my $step = eval { steps("$call.write(o0)")->[0] };
        is_deeply($step && $step->{params}, {color => [1,0,0], alpha => 1}, 'excess value is discarded') or diag "$@";
        ok(!$step || !exists $step->{inline_chains}, 'excess argument never creates a chain');
    }
    is_deeply(\@warnings, [("Too many positional arguments for solid(): 'solid' takes 2\n") x 2], 'warns once per excess call');
    my $step = steps("let n = from(classicNoisedeck, noise())\nlet tuned = n(seed: 1)\ntuned().write(o0)")->[0];
    is($step->{effect_id}, 'classicNoisedeck/noise', 'nested partial preserves its explicit namespace');
};

subtest 'chain diagnostics identify the parameter at its original expression' => sub {
    for my $case (
        ['noise().blendMode(tex: ', 'read(o1).invert()', ').write(o0)'],
        ['noise().blendMode(', 'read3d(vol0, geo0).render3d()', ').write(o0)'],
        ['noise().blendMode(tex: ', 'noise().subchain("s") { .invert() }', ').write(o0)'],
        ['let mix = blendMode(tex: ', 'read(o1).invert()', ")\nnoise().mix().write(o0)"],
        ['let layer = ', 'read(o1).invert()', "\nlet alias = layer\nnoise().blendMode(tex: alias).write(o0)"],
    ) {
        my ($prefix, $expression, $suffix) = @$case;
        eval { compile_body("noise().write(o1)\n$prefix$expression$suffix") };
        my $e = $@;
        like("$e", qr/Chain for argument 'tex' in blendMode\(\) may contain only effect calls/, $expression);
        is_deeply($e && $e->can('code') ? [$e->code, $e->source_name, $e->line, $e->column] : [],
                  ['S001', 'saved.dsl', 3, length($prefix) + 1], 'code and location');
    }
};

subtest 'hex capture and indexed RGB expansion' => sub {
    my @names = qw(r g b a x);
    my %registry = (%$effects, 'filter/rgbprobe' => {
        kind => 'filter', paramOrder => \@names, params => {map { $_ => {type => 'float', default => 1} } @names},
    });
    for my $case (
        ["let first = #f00\nlet color = first\nlet first = #0f0", 'rgbprobe(color, 0.5, 0.6, 0.7)', {r=>1,g=>0,b=>0,a=>0.7}],
        ["let color = #f00\nlet t = rgbprobe(color)\nlet color = #0f0", 't(_skip: false)', {r=>1,g=>0,b=>0}],
        ["let t = rgbprobe(#f00)\nlet u = t(g: 0.25)", "u(_id: 'u')", {r=>1,g=>0.25,b=>0}],
        ["let t = rgbprobe(r: 0.25)\nlet u = t(#f00, 0.6)", "u(_id: 'u')", {r=>0.25,g=>0.6}],
        ["let t = rgbprobe(_id: 't')", 't(#f00)', {r=>1,g=>0,b=>0}],
    ) {
        my ($prefix, $call, $expected) = @$case;
        my $actual = eval { steps("$prefix\nnoise().$call.write(o0)", \%registry)->[1]{params} };
        is_deeply($actual, $expected, $call) or diag "$@";
    }
    for my $case (['noise().rgbprobe(color)', {r=>1,g=>0,b=>0}], ['solid(color: color)', {color=>[1,0,0]}]) {
        my ($expr, $expected) = @$case;
        my $actual = eval { steps("let color = #f00\nlet t = blendMode(tex: $expr)\nlet color = #0f0\nnoise().t().write(o0)", \%registry)
                              ->[1]{inline_chains}[0]{chain}{steps}[-1]{params} };
        is_deeply($actual, $expected, "capture inside $expr") or diag "$@";
    }
    eval { steps('noise().rgbprobe([1,0,0]).write(o0)', \%registry) };
    like("$@", qr/Parameter "r" must be a finite number/, 'an array literal does not expand into scalar RGB slots');
    is(ref(parse_dsl('search synth; solid(#f00).write(o0)')->{chains}[0]{calls}[0]{args}[0]{value}), 'ARRAY',
       'hex literal remains a plain array reference in the public AST');
};

done_testing;
