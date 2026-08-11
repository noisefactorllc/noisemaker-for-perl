use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use JSON::PP ();
use Math::Fractal::Noisemaker::Renderer qw(meta);
use Math::Fractal::Noisemaker::Transpiler::CDN ();
use Math::Fractal::Noisemaker::Transpiler::Build ();

my @volume_effects = qw(
    classicNoisedeck/noise3d
    classicNoisedeck/shapes3d
    filter3d/flow3d
    filter3d/palette3d
    render/loopBegin
    render/loopEnd
    render/render3d
    render/renderCubemap3d
    render/renderCubemapSurface
    render/renderLit3d
    synth3d/cell3d
    synth3d/cellularAutomata3d
    synth3d/flythrough3d
    synth3d/fractal3d
    synth3d/noise3d
    synth3d/reactionDiffusion3d
    synth3d/shape3d
);

is_deeply(
    Math::Fractal::Noisemaker::Transpiler::CDN::_json5_decode(
        q{{small:.1,negative:-.5,tolerance:1e-4,large:2E+3,rgb:[.83,.6,.63]}},
    ),
    {
        small    => 0.1,
        negative => -0.5,
        tolerance => 0.0001,
        large    => 2000,
        rgb      => [0.83, 0.6, 0.63],
    },
    'CDN extraction accepts JSON5 leading-decimal numbers',
);
is_deeply(
    Math::Fractal::Noisemaker::Transpiler::CDN::ordered_object_keys(
        q{{type:{type:"int",choices:{one:1,two:2}},octaves:{type:"int"},"seed":{type:"int"}}},
    ),
    [qw(type octaves seed)],
    'CDN extraction preserves bare and quoted top-level parameter order',
);
my $sanitized_literal = q{{tolerance:{min:1e-4,max:.01},reference:moduleConstant}};
is_deeply(
    Math::Fractal::Noisemaker::Transpiler::CDN::_read_literal(
        \$sanitized_literal, 0, 1,
    ),
    { tolerance => { min => 0.0001, max => 0.01 }, reference => 0 },
    'sanitized CDN globals preserve exponents while replacing module constants',
);

my $catalog = meta()->{effects};
is_deeply(
    $catalog->{'synth/noise'}{paramOrder},
    [qw(type octaves scaleX scaleY seed wrap ridges loopOffset loopScale speed colorMode)],
    'generated metadata retains authoritative positional parameter order',
);
my %iterated_volume_order = (
    'filter3d/flow3d' => [qw(
        volumeSize behavior density stride strideDeviation kink intensity
        inputIntensity lifetime iterationCount
    )],
    'render/loopBegin' => [qw(alpha intensity iterationCount)],
    'synth3d/cellularAutomata3d' => [qw(
        volumeSize seed ruleIndex neighborMode speed density colorMode
        resetState source geoSource weight iterationCount
    )],
    'synth3d/reactionDiffusion3d' => [qw(
        volumeSize seed iterations feed kill rate1 rate2 speed colorMode
        resetState source geoSource weight iterationCount
    )],
);
for my $effect_id (sort keys %iterated_volume_order) {
    is_deeply(
        $catalog->{$effect_id}{paramOrder},
        $iterated_volume_order{$effect_id},
        "$effect_id retains authoritative positional parameter order",
    );
}
my $eligible;
{
    no warnings 'redefine';
    local *Math::Fractal::Noisemaker::Transpiler::CDN::fetch_manifest = sub {
        return { map { $_ => {} } keys %$catalog };
    };
    $eligible = Math::Fractal::Noisemaker::Transpiler::CDN::eligible_ids();
}
my %eligible = map { $_ => 1 } @$eligible;
is(scalar(@$eligible), 184, 'CDN build selects 167 image effects and 17 volume effects');
is_deeply(
    [grep { $eligible{$_} } @volume_effects],
    \@volume_effects,
    'all 17 volume and loop effects are eligible for generation',
);
ok(!$eligible{'synth/reactionDiffusion'}, 'previously authored stateful effects remain excluded');
ok(!$eligible{'render/meshRender'}, 'unsupported mesh effects remain excluded');

my $volume_noise = Math::Fractal::Noisemaker::Transpiler::CDN::_project_effect({
    namespace  => 'synth3d',
    params     => {},
    paramOrder => [],
    passes     => [{
        drawBuffers => 2,
        viewport => {
            height => { param => 'volumeSize', power => 2, default => 4096 },
        },
        outputs => { color => 'volumeCache', geoOut => 'geoBuffer' },
    }],
}, 'synth3d/noise3d');
is($volume_noise->{domain}, 'volume-generator', 'synth3d effects are volume generators');
is($volume_noise->{outputTex3d}, 'volumeCache', 'volume generator output texture is retained');
is($volume_noise->{outputGeo}, 'geoBuffer', 'volume generator geometry output is retained');
is_deeply(
    $volume_noise->{passes}[0]{viewport}{height},
    { param => 'volumeSize', power => 2, default => 4096 },
    'volume atlas viewport metadata is retained',
);
ok(
    exists $volume_noise->{passes}[0]{outputs}{fragColor},
    'MRT color output is projected to the shader fragColor name',
);

my $flow = Math::Fractal::Noisemaker::Transpiler::CDN::_project_effect({
    namespace => 'filter3d', params => {}, paramOrder => [], passes => [],
}, 'filter3d/flow3d');
is($flow->{domain}, 'volume-filter', 'filter3d effects are volume filters');
ok($flow->{iterated}, 'flow3d is iterated');
is_deeply(
    $flow->{params}{iterationCount},
    { type => 'int', default => 60, min => 0, max => 10_000, cpuOnly => JSON::PP::true },
    'iterated volume effects expose the CPU iteration count',
);
is($flow->{outputTex3d}, 'global_flow3d_blended', 'flow3d output texture is retained');
is($flow->{outputGeo}, 'geoBuffer', 'flow3d geometry output is retained');

my $renderer = Math::Fractal::Noisemaker::Transpiler::CDN::_project_effect({
    namespace => 'render', params => {}, paramOrder => [], passes => [],
}, 'render/render3d');
is($renderer->{domain}, 'volume-renderer', 'render3d is a volume renderer');
is($renderer->{outputTex3d}, 'inputTex3d', 'volume renderer passes its volume through');
is($renderer->{outputGeo}, 'screenGeoBuffer', 'volume renderer exposes screen geometry');

my $loop_begin = Math::Fractal::Noisemaker::Transpiler::CDN::_project_effect({
    namespace => 'render', params => {}, paramOrder => [], passes => [],
}, 'render/loopBegin');
is($loop_begin->{domain}, 'loop-begin', 'loopBegin has the loop-begin domain');
is($loop_begin->{loopRole}, 'begin', 'loopBegin carries its grouping role');
ok($loop_begin->{iterated}, 'loopBegin owns the iteration count');

my $loop_end = Math::Fractal::Noisemaker::Transpiler::CDN::_project_effect({
    namespace => 'render', params => {}, paramOrder => [], passes => [],
}, 'render/loopEnd');
is($loop_end->{domain}, 'loop-end', 'loopEnd has the loop-end domain');
is($loop_end->{loopRole}, 'end', 'loopEnd carries its grouping role');

is(
    $catalog->{'classicNoisedeck/shapes3d'}{kind},
    'mixer',
    'surface-fed classic effects retain mixer classification',
);
is($catalog->{'synth3d/noise3d'}{kind}, 'generator', 'synth3d builds as a generator');
is(
    $catalog->{'synth3d/noise3d'}{domain},
    'volume-generator',
    'generated metadata retains the volume domain',
);
is(
    $catalog->{'synth3d/noise3d'}{outputTex3d},
    'volumeCache',
    'generated metadata retains the volume output',
);
is(
    $catalog->{'synth3d/noise3d'}{outputGeo},
    'geoBuffer',
    'generated metadata retains the geometry output',
);

my @kind_warnings;
{
    local $SIG{__WARN__} = sub { push @kind_warnings, @_ };
    is(
        Math::Fractal::Noisemaker::Transpiler::Build::infer_kind({
            namespace => 'filter',
            textures => { partialTexture => { width => 1 } },
            passes => [{ inputs => { sourceTex => 'partialTexture' } }],
        }),
        'mixer',
        'partially sized textures are not mistaken for fixed internal lookups',
    );
}
is_deeply(\@kind_warnings, [], 'kind inference does not warn on partial texture dimensions');

done_testing();
