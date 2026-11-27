use strict;
use warnings;
use Test::More;
use Math::Fractal::Noisemaker::Renderer qw(render_effect render_dsl);
use Math::Fractal::Noisemaker::Surface;

my %effects;
my %kernels = (
    fill => sub { my ($ctx, $out) = @_; @$out = ($ctx->uniforms->{value}) x 4 },
    read => sub { my ($ctx, $out) = @_; @$out = @{ $ctx->texture_binding('src')->data }[0..3] },
    measure => sub {
        my ($ctx, $out) = @_;
        my $src = $ctx->texture_binding('src');
        @$out = ($src->data->[0], $src->width, $ctx->texture_binding('image')->data->[0], 1);
    },
    tick => sub { my ($ctx, $out) = @_; @$out = (($ctx->uniforms->{frame} + 1) * 0.25) x 4 },
    clock => sub {
        my ($ctx, $out) = @_;
        @$out = (@{ $ctx->texture_binding('prior')->data }[2, 3], @{ $ctx->uniforms }{qw(time deltaTime)});
    },
    sum => sub {
        my ($ctx, $out) = @_;
        @$out = ($ctx->texture_binding('state')->data->[0] + $ctx->texture_binding('prior')->data->[0]) x 4;
    },
    agents => sub { my ($ctx, $out) = @_; @$out = ((0.75) x 4, (0.625) x 4, (0.375) x 4) },
    channels => sub {
        my ($ctx, $out) = @_;
        @$out = ((map { $ctx->texture_binding($_)->data->[0] } qw(x v r)), $ctx->texture_binding('x')->width);
    },
    split => sub { my ($ctx, $out) = @_; @$out = (0.5) x 8 },
);
no warnings 'redefine';
local *Math::Fractal::Noisemaker::Renderer::meta = sub { { effects => \%effects } };
local *Math::Fractal::Noisemaker::Renderer::_kernel_for = sub {
    my $outputs = { split => [qw(a b)], agents => [qw(x v r)] }->{$_[0]};
    return { kernel => $kernels{$_[0]}, ($outputs ? (output_names => $outputs) : ()) };
};
my $tiny = { width => 1, height => 1, format => 'rgba32f' };
sub effect {
    my ($name, $kind, $passes, %args) = @_;
    $effects{"probe/$name"} = {
        namespace => 'probe', func => $name, kind => $kind, domain => 'image',
        params => { iterationCount => { type => 'int', default => 2 } }, paramOrder => ['iterationCount'],
        textures => {}, passes => $passes, %args,
    };
}
sub shader {
    my ($key, $out, $inputs, %args) = @_;
    return { key => $key, name => $key, program => $key, inputs => $inputs || {},
             outputs => { color => $out }, %args };
}
sub fill { shader('fill', $_[0], {}, uniforms => { value => $_[1] }) }
sub source { my ($chain) = @_; return "search probe\n$chain.write(o0)\nrender(o0)" }
sub pixels { my ($chain) = @_; return [@{ render_dsl(source($chain), width => 2, height => 2)->data }[0..3]] }

for my $iterated (0, 1) {
    effect('emit', 'generator', [fill('work', 0.25)], iterated => $iterated,
        outputTex => 'work', outputVel => 'work', textures => { work => $tiny, outputTex => {} });
    effect('forward', 'filter', [shader('read', 'private', { src => 'inputTex' })], outputTex => 'inputTex', outputXyz => 'inputVel');
    effect('edit', 'filter', [fill('inputXyz', 0.75), shader('measure', 'outputTex', { image => 'inputTex', src => 'inputVel' })]);
    is_deeply(pixels('emit().forward().edit()'), [0.75, 1, 0.75, 1], "transitive image/agent bindings (iterated=$iterated)");

    my $store = sub {
        shader('fill', undef, {}, uniforms => { value => $_[0] },
            outputs => {}, storageTextures => { dst => $_[1] // 'global_work' });
    };
    effect('emit', 'generator', [$store->(0.25)], iterated => $iterated, textures => { global_work => $tiny }, outputTex => 'global_work');
    effect('edit', 'filter', [$store->(0.75), shader('measure', 'outputTex', { src => 'global_work', image => 'inputTex' })], iterated => $iterated);
    is_deeply(pixels('emit().edit()'), [0.75, 1, 0.75, 1], "shared storage owns the published image (iterated=$iterated)");
    my $target = $store->(0.5, 'work');
    effect('quantized', 'generator', [$target, shader('read', 'outputTex', { src => 'work' })],
        iterated => $iterated, textures => { work => { %$tiny, format => 'rgba8unorm' }, outputTex => { format => 'rgba32f' } });
    is(pixels('quantized()')->[0], unpack('f', pack('f', 128/255)), "storage write rounds before the next pass (iterated=$iterated)");
    effect('reader', 'filter', [shader('read', 'outputTex', { src => 'global_work' })]);
    eval { pixels("emit().write(o1)\nread(o1).reader()") };
    like($@, qr/requires texture "global_work"/, 'shared storage ends with its chain');

    effect('colors', 'generator', [fill('_left', 0.25), fill('_right', 0.75),
        shader('split', undef, {}, drawBuffers => 2, outputs => { a => '_left', b => '_right' }, blend => ['DST_COLOR', 0]),
        shader('measure', 'outputTex', { src => '_left', image => '_right' }),
        { %{ fill('outputTex', 0.5) }, blend => [0, 1] }], iterated => $iterated);
    is_deeply(pixels('colors()'), [0.125, 2, 0.375, 1], "MRT blends the prior contents of each attachment (iterated=$iterated)");
    effect('owned', 'generator', [fill('fallback', 0.125), fill('outputTex', 0.25), fill('outputRgba', 0.5)],
        iterated => $iterated, textures => { outputRgba => $tiny }, outputTex => 'fallback', outputRgba => 'fallback');
    effect('inspect', 'filter', [shader('measure', 'outputTex', { src => 'inputRgba', image => 'inputTex' })]);
    is_deeply(pixels('owned().inspect()'), [0.5, 1, 0.25, 1], "written publication names override fallback (iterated=$iterated)");

    effect('scratch', 'generator', [fill('anchor', 0.75), shader('measure', 'outputTex', { src => 'aux', image => 'anchor' })],
        iterated => $iterated, textures => { anchor => { width => 3, height => 1 }, aux => { width => { inputOverride => 'anchor', param => 'size', default => 1 } } });
    is_deeply(pixels('scratch()'), [0, 1, 0.75, 1], "scratch is allocated before the first pass (iterated=$iterated)");

    for my $declared_first (0, 1) {
        my ($anchor, $aux) = $declared_first ? qw(zAnchor aAux) : qw(aAnchor zAux);
        effect('scratch', 'generator', [shader('measure', 'outputTex', {src => $aux, image => $anchor})],
            iterated => $iterated, textureOrder => [$declared_first ? ($anchor, $aux) : ($aux, $anchor)],
            textures => {$anchor => {width => 3, height => 1}, $aux => {width => {inputOverride => $anchor, param => 'n', default => 1}}});
        is(pixels('scratch()')->[1], $declared_first && !$iterated ? 3 : 1,
            "scratch dimensions use earlier declarations in ordinary mode (anchor first=$declared_first, iterated=$iterated)");
    }

    for my $control (qw(D U)) {
        my $pass = { %{ fill('outputTex', 0.75) },
            conditions => { runIf => [{ uniform => $control, equals => 1 }] } };
        effect('define', 'generator', [fill('outputTex', 0.125), $pass], iterated => $iterated,
            params => { mode => { type => 'int', default => 1, define => 'D', uniform => 'U' },
                iterationCount => { type => 'int', default => 2 } }, paramOrder => [qw(mode iterationCount)]);
        is(pixels('define()')->[0], $control eq 'D' ? 0.75 : 0.125,
            "a scalar with define and uniform binds only its define (control=$control, iterated=$iterated)");
    }

    my $guarded = sub {
        my ($value, $gate, $uniform) = @_;
        return { %{ fill('outputTex', $value) }, conditions => { $gate => [{ uniform => $uniform, equals => 0 }] } };
    };
    effect('controls', 'generator', [fill('outputTex', 0.25), $guarded->(0.375, 'skipIf', 'missing'),
        $guarded->(0.5, 'runIf', 'missing'), $guarded->(0.75, 'runIf', 'frame'),
        { %{ fill('outputTex', 0.125) }, repeat => '2', blend => [1, 1] },
        { %{ fill('outputTex', 0.0625) }, repeat => 1.5, blend => [1, 1] }], iterated => $iterated);
    is_deeply(pixels('controls()'), [(0.625) x 4], "gates and repetition use bound uniforms and literal types (iterated=$iterated)");
}
# Shared storage sizing sees targets discovered earlier in the chain. A later
# writer of the same target updates its owner without changing that order.
my $storage_pass = sub {
    my ($names, $order) = @_;
    return shader('fill', undef, {}, outputs => {}, storageTextures => $names,
        defined $order ? (storageTextureOrder => $order) : (),
        conditions => { runIf => [{ uniform => 'enabled', equals => 1 }] });
};
my $first = $storage_pass->({ a => 'global_a' });
my $second = $storage_pass->({ b => 'global_b' });
my $multi = { z => 'global_a', a => 'global_b' };
my $declarations = {
    global_a => { width => 3, height => 1 },
    global_b => { width => { inputOverride => 'global_a', param => 'n', default => 1 }, height => 1 },
};
for my $case (
    ['separate passes', [$first, $second, $first], [], 3],
    ['separate steps', [$first], [$second, $first], 3],
    ['multi-target authored order', [$storage_pass->($multi, [qw(z a)])], [], 3],
    ['multi-target reverse order', [$storage_pass->($multi, [qw(a z)])], [], 1],
    ['multi-target sorted fallback', [$storage_pass->($multi)], [], 1],
) {
    my ($label, $writer, $next, $width) = @$case;
    effect('writer', 'generator', [@$writer, fill('outputTex', 0)], textures => $declarations);
    effect('nextWriter', 'filter', [@$next, fill('outputTex', 0)]);
    effect('reader', 'filter', [shader('measure', 'outputTex', { src => 'global_b', image => 'global_a' })]);
    is(pixels('writer().nextWriter().reader()')->[1], $width, "shared storage allocation order across $label");
}

{
    my $paint = sub { $_[0]{destination}->clear([(0.25) x 4]) };
    local *Math::Fractal::Noisemaker::MeshRender::get_adapter = sub { $paint };
    local *Math::Fractal::Noisemaker::DrawOps::get_draw_op = sub { $paint };
    my $targets = { z => 'first', a => 'second' };
    for my $case (
        ['fragment outputs', 'fill', undef, { outputs => $targets, outputOrder => [qw(z a)] }],
        ['storage outputs without an MRT kernel', 'fill', undef,
            { outputs => {}, storageTextures => $targets, storageTextureOrder => [qw(z a)], drawBuffers => 2 }],
        ['MRT kernel with one draw buffer', 'split', undef, { outputs => $targets, outputOrder => [qw(z a)], drawBuffers => 1 }],
        ['scatter outputs', 'fill', 'points', { outputs => $targets, outputOrder => [qw(z a)] }],
        ['triangle outputs', 'fill', 'triangles', { outputs => $targets, outputOrder => [qw(z a)] }],
    ) {
        my ($label, $key, $mode, $attrs) = @$case;
        my $pass = shader($key, undef, {}, uniforms => { value => 0.25 }, %$attrs);
        $pass->{drawMode} = $mode if $mode;
        for my $iterated (0, 1) {
            next if $iterated && defined $mode && $mode eq 'triangles';
            effect('single', 'generator', [fill('first', 0.125), fill('second', 0.75), $pass,
                shader('measure', 'outputTex', { src => 'second', image => 'first' })], iterated => $iterated);
            my $written = $key eq 'split' ? 0.5 : 0.25;
            is_deeply(pixels('single()'), [0.75, 2, $written, 1],
                "only the first attachment receives $label (iterated=$iterated)");
        }
    }
    effect('single', 'generator', [shader('split', undef, {}, outputs => $targets, outputOrder => [qw(z a)]),
        shader('measure', 'outputTex', { src => 'second', image => 'first' })]);
    my $direct = render_effect('probe/single', {}, {}, width => 2, height => 2);
    is_deeply([@{ $direct->data }[0..3]], [0.5, 2, 0.5, 1], 'standalone retains its multiple-output fallback');
}

for my $physical (0, 1) {
    my @local = qw(global_xyz global_vel global_rgba);
    my @input = qw(inputXyz inputVel inputRgba);
    effect('agents', 'generator', [map(fill($_, 0.25), @local), fill('outputTex', 0)], iterated => 1,
        textures => {map { $_ => $tiny } @local}, outputXyz => $local[0], outputVel => $local[1], outputRgba => $local[2]);
    my @targets = $physical ? @local : @input;
    effect('move', 'filter', [shader('agents', undef, {}, outputs => {x => $targets[0], v => $targets[1], r => $targets[2]}, drawBuffers => 3),
        fill('outputTex', 0)], textures => {outputXyz => {width => 3, height => 1}});
    effect('channels', 'filter', [shader('channels', 'outputTex', {x => $input[0], v => $input[1], r => $input[2]})]);
    is_deeply(pixels('agents().move().channels()'), [0.75, 0.625, 0.375, 1],
        "MRT updates all handed-on channels across a reserved output (physical targets=$physical)");
}
effect('emit', 'generator', [shader('tick', 'global_xyz'), fill('outputTex', 0)], iterated => 1,
    textures => {global_xyz => $tiny}, outputVel => 'global_xyz');
effect('sum', 'filter', [shader('sum', 'outputTex', {state => 'inputVel', prior => 'selfTex'})]);
is_deeply(pixels('emit().sum()'), [(0.75) x 4], 'agent readers run every tick');
effect('nextEmit', 'filter', [fill('outputTex', 0)], iterated => 1, textures => {global_xyz => $tiny});
eval { pixels('emit().nextEmit().sum()') };
like($@, qr/requires texture "inputVel"/, 'new emitter clears prior agent channels');

effect('floatImage', 'generator', [fill('outputTex', 0.25)], textures => {outputTex => {format => 'rgba32f'}});
effect('bypass', 'filter', [fill('outputTex', 0.5)], iterated => 1);
my $cloned = render_dsl(source('floatImage().bypass(iterationCount: 0)'), width => 2, height => 2);
is($cloned->format, 'rgba32f', 'zero-tick bypass preserves the image attachment format');

effect('blend', 'generator', [fill('outputTex', 0.5), { %{fill('outputTex', 0.25)}, blend => [770, 771] }]);
is_deeply(pixels('blend()'), [(0.4375) x 4], 'numeric GL enums use source alpha through all four channels');
effect('blend', 'generator', [fill('outputTex', 0.5), { %{fill('outputTex', 0.25)}, blend => ['770', '0'] }]);
is_deeply(pixels('blend()'), [(0.75) x 4], 'unknown blend factor strings default to one');

effect('clock', 'generator', [shader('clock', 'outputTex', {prior => 'selfTex'})], iterated => 1,
    textures => {outputTex => $tiny});
my @seam = map { unpack 'f', pack 'f', $_ } (599/600, 1/600, 0, 1/600);
is_deeply(pixels('clock()'), \@seam, 'two simulation ticks keep their delta and wrap time through zero');

effect('emit', 'generator', [fill('global_xyz', 0.25), fill('outputTex', 0.5)], iterated => 1,
    params => {stateSize => {type => 'int', default => 1}, iterationCount => {type => 'int', default => 2}},
    paramOrder => [qw(stateSize iterationCount)], textures => {global_xyz => $tiny}, outputXyz => 'global_xyz');
effect('inherit', 'filter', [shader('measure', 'outputTex', {src => 'aux', image => 'inputXyz'})],
    textures => {aux => {width => {inherit => 1, param => 'stateSize'}, height => 1}});
is_deeply(pixels('emit().inherit()'), [0, 1, 0.25, 1], 'joined scope inherits an omitted owner stateSize from its default');

effect('image', 'generator', [fill('outputTex', 0.25)]);
effect('parallel', 'filter', [fill('private', 0)],
    outputTex => 'inputTex', outputXyz => 'first', outputVel => 'second',
    params => { map { $_ => { type => 'surface', default => 'inputTex' } } qw(first second) },
    paramOrder => [qw(first second)]);
effect('moveVel', 'filter', [fill('inputVel', 0.75), shader('read', 'outputTex', { src => 'inputTex' })]);
is(pixels('image().parallel().moveVel()')->[0], 0.75, 'the last channel publishing the same raw image owns its alias');
effect('map', 'filter', [shader('measure', 'outputTex', {src => 'slot', image => 'inputTex'})],
    params => {inputTex => {type => 'surface', texture => 'slot', default => 'inputTex'}}, paramOrder => ['inputTex']);
is_deeply(pixels('image().map(inputTex: none)'), [0, 1, 0.25, 1], 'explicit none leaves the surface parameter blank while the chain image remains bound');

# Public render_effect accepts resources by parameter, attachment or sampler name.
my $a = Math::Fractal::Noisemaker::Surface->new(1, 1)->clear([(0.125) x 4]);
my $b = Math::Fractal::Noisemaker::Surface->new(1, 1)->clear([(0.375) x 4]);
my %param = (params => { map => { type => 'surface', texture => 'slot', default => 'none' } }, paramOrder => ['map']);
effect('direct', 'generator', [shader('read', 'outputTex', {src => 'slot'})], %param);
my $direct = sub { render_effect('probe/direct', {}, $_[0], width => 1, height => 1)->data->[0] };
is($direct->({map => $a, src => $b}), 0.125, 'standalone declared surface wins over raw sampler');
is($direct->({src => $b}), 0, 'standalone unbound optional surface shadows a raw sampler fallback');
effect('direct', 'generator', [shader('read', 'outputTex', {src => 'inputTex'}), fill('other', 0.75)]);
is($direct->({inputTex => $a, src => $b}), 0.125, 'standalone resolves raw source before sampler and publishes outputTex');
is($direct->({src => $b}), 0.375, 'standalone accepts direct sampler bindings');
effect('direct', 'generator', [fill('prior', 0.5), shader('read', 'outputTex', {src => 'missing'})]);
eval { $direct->({}) };
like($@, qr/requires texture "missing"/, 'standalone rejects missing sources after a prior pass');

effect('direct', 'generator', [fill('slot', 0.75), shader('read', 'outputTex', {src => 'slot'})], %param);
is($direct->({map => $a, src => $b}), 0.75, 'standalone pass output supersedes a supplied resource');
effect('direct', 'generator', [shader('read', 'outputTex', {src => '_private'}), fill('_private', 0.75)],
    textures => {_private => $tiny});
is($direct->({_private => $b}), 0.375, 'standalone preserves explicitly supplied private scratch');
effect('direct', 'generator', [fill('work', 0.75)], outputTex => 'work');
is($direct->({outputTex => $b}), 0.75, 'standalone configured publication wins over a caller-supplied outputTex');

done_testing;
