use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Math::Fractal::Noisemaker::Renderer qw(render_effect render_dsl);

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

# Catalog min/max and numeric choices describe UI controls, not API limits.
# Tiny state buffers and seeds outside slider ranges are supported CPU uses.
my $small = render_effect('synth/noise', {seed => 1000, scaleX => 0.5}, undef, width => 2, height => 2);
ok($small, 'finite numeric values outside slider bounds remain supported');

done_testing();
