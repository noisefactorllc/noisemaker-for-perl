use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Math::Fractal::Noisemaker::Renderer qw(render_effect render_dsl);
use Math::Fractal::Noisemaker::Surface;

for my $value (0, '', [], 'not a hash') {
    eval { render_effect('synth/solid', $value, undef, width => 2, height => 2) };
    like($@, qr/Parameters for synth\/solid must be a hash reference/,
        'only undef or a parameter hash is accepted');
}

for my $case (
    ['unknown name', { seeed => 3 }, qr/Unknown parameter.*seeed.*synth\/noise/],
    ['unknown enum', { type => 'not_a_noise_type' }, qr/Invalid parameter.*type.*synth\/noise.*choice/],
    ['bad number', { scaleX => 'banana' }, qr/Invalid parameter.*scaleX.*finite number/],
    ['infinity', { scaleX => 'Inf' }, qr/Invalid parameter.*scaleX.*finite number/],
    ['fractional integer', { octaves => 1.5 }, qr/Invalid parameter.*octaves.*integer/],
    ['bad boolean', { ridges => 'sometimes' }, qr/Invalid parameter.*ridges.*boolean/],
) {
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $ok = eval { render_effect('synth/noise', $case->[1], undef, width => 2, height => 2); 1 };
    ok(!$ok, "$case->[0] is rejected");
    like($@, $case->[2], "$case->[0] identifies the caller's mistake");
    is_deeply(\@warnings, [], "$case->[0] does not leak numeric conversion warnings");
}

for my $value ('#zzzzzz', [1, 0], [1, 'banana', 0]) {
    eval { render_effect('synth/solid', {color => $value}, undef, width => 2, height => 2) };
    like($@, qr/Invalid parameter.*color/, 'invalid color rejected before rendering');
}

eval { render_dsl("search synth\nnoise(type: not_a_noise_type).write(o0)\nrender(o0)", width => 2, height => 2) };
like($@, qr/Invalid parameter.*type/, 'DSL rendering uses the same value validation');

{
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    eval { render_effect('classicNoisedeck/noise', {loopOffset => 'Shapes:'},
        undef, width => 2, height => 2) };
    like($@, qr/Invalid parameter.*loopOffset/, 'dropdown group headings are not choices');
    is_deeply(\@warnings, [], 'invalid group headings produce no conversion warnings');
}

for my $entry (['source', []], ['geoSource', {}], ['source', 'vol99']) {
    eval { render_effect('synth3d/cellularAutomata3d',
        {$entry->[0] => $entry->[1], volumeSize => 2, iterationCount => 0},
        undef, width => 2, height => 2) };
    like($@, qr/Invalid parameter.*$entry->[0].*inputs hash/,
        'typed resources must be bound through the inputs hash');
}

my $rgb_solid = render_effect('synth/solid', {color => [1, 0, 0], alpha => 0.6},
    undef, width => 1, height => 1);
my $rgba_solid = render_effect('synth/solid', {color => [1, 0, 0, 0.1], alpha => 0.6},
    undef, width => 1, height => 1);
is($rgba_solid->to_rgba8, $rgb_solid->to_rgba8,
    'a fourth color component does not override the separate alpha parameter');

my $base = render_effect('synth/noise', {}, undef, width => 4, height => 4);
my $rotated = eval { render_effect('filter/palette', {rotation => 'fwd'},
    {inputTex => $base}, width => 4, height => 4, time => 0.25) };
ok($rotated, 'float dropdowns accept declared names') or diag($@);
my $rotation = render_effect('filter/palette', {rotation => 1},
    {inputTex => $base}, width => 4, height => 4, time => 0.25);
is($rotated ? $rotated->to_rgba8 : undef, $rotation->to_rgba8,
    'named float dropdowns equal their numeric values');

my $palette = render_effect('classicNoisedeck/noise', {palette => 10, colorMode => 4},
    undef, width => 2, height => 2);
for my $value ('1e1', ' 10 ') {
    my $actual = render_effect('classicNoisedeck/noise', {palette => $value, colorMode => 4},
        undef, width => 2, height => 2);
    is($actual->to_rgba8, $palette->to_rgba8, 'palette numeric strings select the same palette');
}

my $named = render_effect('synth/noise', {type => 'noise.simplex', ridges => 'true', scaleX => '7.5'},
    undef, width => 2, height => 2);
my $numeric = render_effect('synth/noise', {type => 10, ridges => 1, scaleX => 7.5},
    undef, width => 2, height => 2);
is($named->to_rgba8, $numeric->to_rgba8, 'valid CLI values and named enums retain their rendering');

my $string_false = render_effect('synth/noise', {ridges => ' 0 ', seed => '1e1'},
    undef, width => 2, height => 2);
my $false = render_effect('synth/noise', {ridges => 0, seed => 10},
    undef, width => 2, height => 2);
is($string_false->to_rgba8, $false->to_rgba8, 'numeric strings and whitespace around booleans normalize correctly');

# As in the reference (src/effects/definition.js), a numeric value outside the
# parameter's declared min/max is rejected; the bounds themselves are valid.
for my $case (
    ['an int above its maximum', 'synth/curl', {seed => 1001},
        qr/Invalid parameter 'seed' for synth\/curl: must be at most 1000 \(declared range 0 to 1000\)/],
    ['an int below its minimum', 'synth/noise', {seed => 0},
        qr/Invalid parameter 'seed' for synth\/noise: must be at least 1 \(declared range 1 to 100\)/],
    ['a float below its minimum', 'synth/noise', {scaleX => 0.5},
        qr/Invalid parameter 'scaleX' for synth\/noise: must be at least 1/],
) {
    eval { render_effect($case->[1], $case->[2], undef, width => 2, height => 2) };
    like($@, $case->[3], "$case->[0] is rejected");
}
for my $seed (0, 1000) {
    ok(render_effect('synth/curl', {seed => $seed}, undef, width => 2, height => 2),
        "seed $seed, a declared bound, renders");
}
eval { render_dsl("search synth\ncurl(seed: 5000).write(o0)\nrender(o0)", width => 2, height => 2) };
like($@, qr/'seed' for synth\/curl: must be at most 1000/, 'an explicit DSL seed is range-checked');
ok(render_effect('synth/curl', {}, undef, width => 2, height => 2, seed => 5000),
    'the render seed is not a parameter value and is not range-checked, as in the reference');

# A four-component color keeps the separate alpha parameter (reference bytes).
for my $case ([1, [51, 102, 153, 255]], [undef, [51, 102, 153, 255]], [0.8, [41, 82, 122, 204]]) {
    my %params = (color => [0.2, 0.4, 0.6, 0.3]);
    $params{alpha} = $case->[0] if defined $case->[0];
    is_deeply([unpack 'C4', render_effect('synth/solid', \%params, undef, width => 2, height => 2)->to_rgba8],
        $case->[1], 'RGBA color with alpha ' . ($case->[0] // 'omitted') . ' keeps the alpha parameter');
}

# renderLandscape3d accepts its filtering parameter by value and by name. A
# synthetic nonuniform 16^3 volume and geometry keep this fast (t/05 compares
# both choices with the reference over a noise3d volume).
{
    my $n = 16;
    my (@volume, @geometry);
    for my $row (0 .. $n * $n - 1) {
        for my $x (0 .. $n - 1) {
            my ($y, $z) = ($row % $n, int($row / $n));
            my $v = (($x * 3 + $y * 5 + $z * 7) % 16) / 15;
            push @volume, $v, 1 - $v, ($x + $z) / 30, $v;
            push @geometry, 0.5, 1, 0.5, $v;
        }
    }
    my %inputs = (
        inputTex3d => Math::Fractal::Noisemaker::Surface->new($n, $n * $n, \@volume),
        inputGeo   => Math::Fractal::Noisemaker::Surface->new($n, $n * $n, \@geometry),
    );
    my %landscape;
    for my $filtering (0, 1, 'voxel') {
        my $out = render_effect('render/renderLandscape3d', {filtering => $filtering, volumeSize => $n},
            \%inputs, width => 4, height => 4);
        $landscape{$filtering} = (ref $out eq 'HASH' ? $out->{image} : $out)->to_rgba8;
    }
    isnt($landscape{0}, $landscape{1}, 'the isosurface and voxel filtering choices render differently');
    is($landscape{voxel}, $landscape{1}, 'a named filtering choice selects its value');
}

done_testing();
