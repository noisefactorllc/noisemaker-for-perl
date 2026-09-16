package Math::Fractal::Noisemaker::Transpiler::ComputedDefs;

# Hand-ported definitions for effects whose CDN bundle builds globals/passes
# with real JavaScript (loops, spreads) rather than literals, so the static
# extractor can't read them. The GLSL programs are still transpiled from the
# CDN; only the definition (params/passes) is reproduced here.
#
# - mixer/mashup: layer0_tex..layer7_tex surface params (max 8), each with a
#   layerN_active colorModeUniform; wired with `source` into one render pass.
# - synth/remap: zone0_tex..zone7_tex surface params (max 8), each with a
#   zoneN_active colorModeUniform; the std140 `data` block is packed from the
#   params at render time by the Renderer.
# - render/pointsBillboardRender: the reference definition's `.flatMap()`
#   clones its deposit/depthKeys/depthMerge passes per compile-time
#   viewMode/blendMode/blurLayer variant (reference 0ed489ec, the
#   perspective+depth-sort+defocus round). This port keeps its PRE-ROUND
#   5-pass shape (diffuse/copy/deposit/deposit_alpha/blend) instead of
#   replicating the reference's ~25-pass clone structure: viewMode/shapeMode/
#   blendMode are dispatched as RUNTIME uniforms inside one Perl adapter
#   (DrawOps.pm's _billboard_deposit), not per-variant compiled kernels, so
#   compile-time cloning buys nothing here. depthKeys/depthMerge (the
#   22-stage depth-sort) and the aperture defocus precompute
#   (spriteMeanTiles/spriteMean/clearDefocus) are intentionally NOT included
#   as passes -- see DrawOps.pm's compute_clip_center for the documented gap.

use strict;
use warnings;
use Exporter 'import';
use JSON::PP ();

our @EXPORT_OK = qw(%COMPUTED_DEFS);

use constant _MASHUP_LAYERS => 8;
use constant _REMAP_ZONES   => 8;

sub _mashup {
    my %params = (
        source     => { type => 'surface', default => 'none' },
        layers     => { type => 'int',   default => 4,   uniform => 'layers' },
        smoothness => { type => 'float', default => 0.1, uniform => 'smoothness' },
    );
    my @order  = qw(source layers smoothness);
    my %inputs = (source => 'source');
    for my $e (0 .. _MASHUP_LAYERS - 1) {
        my $name = 'layer' . $e . '_tex';
        $params{$name} = { type => 'surface', default => 'none', colorModeUniform => 'layer' . $e . '_active' };
        $inputs{$name} = $name;
        push @order, $name;
    }
    return {
        namespace  => 'mixer',
        func       => 'mashup',
        params     => \%params,
        paramOrder => \@order,
        passes     => [
            { name => 'render', program => 'mashup', inputs => \%inputs, outputs => { fragColor => 'outputTex' } }
        ],
        textures        => {},
        externalTexture => undef,
    };
}

sub _remap {
    my %params = (
        zoneCount  => { type => 'int',   default => 0,         uniform => 'zoneCount' },
        bgColor    => { type => 'color', default => [0, 0, 0], uniform => 'bgColor' },
        bgAlpha    => { type => 'float', default => 1,         uniform => 'bgAlpha' },
        smoothEdge => { type => 'float', default => 0.04,      uniform => 'smoothEdge' },
    );
    my @order = qw(zoneCount bgColor bgAlpha smoothEdge);
    my %inputs;
    for my $z (0 .. _REMAP_ZONES - 1) {
        my $name = 'zone' . $z . '_tex';
        $params{$name} = { type => 'surface', default => 'none', colorModeUniform => 'zone' . $z . '_active' };
        $inputs{$name} = $name;
        push @order, $name;
    }
    return {
        namespace  => 'synth',
        func       => 'remap',
        params     => \%params,
        paramOrder => \@order,
        passes     => [
            { name => 'render', program => 'remap', inputs => \%inputs, outputs => { fragColor => 'outputTex' } }
        ],
        textures        => {},
        externalTexture => undef,
    };
}

sub _points_billboard_render {
    my %params = (
        shapeMode => {
            type => 'int', default => 1, uniform => 'shapeMode',
            choices => { texture => 0, circle => 1, ring => 2, square => 3, diamond => 4, triangle => 5, star => 6, soft => 7 },
        },
        tex            => { type => 'surface', default => 'none' },
        blendMode      => { type => 'int', default => 0, uniform => 'blendMode', choices => { additive => 0, alpha => 1 } },
        depositOpacity => { type => 'float', default => 20, min => 1, max => 100, uniform => 'depositOpacity' },
        pointSize      => { type => 'float', default => 8, min => 1, max => 64, uniform => 'pointSize' },
        sizeVariation  => { type => 'float', default => 0, min => 0, max => 100, uniform => 'sizeVariation' },
        rotationVar    => { type => 'float', default => 0, min => 0, max => 100, uniform => 'rotationVar' },
        seed           => { type => 'int', default => 42, min => 0, max => 1000, uniform => 'seed' },
        density        => { type => 'float', default => 50, min => 0, max => 100, uniform => 'density' },
        intensity      => { type => 'float', default => 75, min => 0, max => 100, uniform => 'intensity' },
        inputIntensity => { type => 'float', default => 10.15, min => 0, max => 100, uniform => 'inputIntensity' },
        viewMode => {
            type => 'int', default => 0, uniform => 'viewMode',
            choices => { flat => 0, ortho => 1, perspective => 2 },
        },
        rotateX            => { type => 'float', default => 0.3, min => 0, max => 6.283185, uniform => 'rotateX' },
        rotateY            => { type => 'float', default => 0, min => 0, max => 6.283185, uniform => 'rotateY' },
        rotateZ            => { type => 'float', default => 0, min => 0, max => 6.283185, uniform => 'rotateZ' },
        viewScale          => { type => 'float', default => 0.8, min => 0.1, max => 10, uniform => 'viewScale' },
        posX               => { type => 'float', default => 0, min => -50, max => 50, uniform => 'posX' },
        posY               => { type => 'float', default => 0, min => -50, max => 50, uniform => 'posY' },
        posZ               => { type => 'float', default => 0, min => -200, max => 200, uniform => 'posZ' },
        fieldOfView        => { type => 'float', default => 60, min => 10, max => 150, uniform => 'fieldOfView' },
        sizeDistance       => { type => 'float', default => 0, min => 0, max => 500, uniform => 'sizeDistance' },
        brightnessDistance => { type => 'float', default => 0, min => 0, max => 500, uniform => 'brightnessDistance' },
        aperture           => { type => 'float', default => 0, min => 0, max => 20, uniform => 'aperture' },
        focalDistance      => { type => 'float', default => 80, min => 1, max => 500, uniform => 'focalDistance' },
    );
    my @order = qw(
        shapeMode tex blendMode depositOpacity pointSize sizeVariation rotationVar seed
        density intensity inputIntensity viewMode rotateX rotateY rotateZ viewScale
        posX posY posZ fieldOfView sizeDistance brightnessDistance aperture focalDistance
    );
    my %deposit_uniforms = (
        density => 'density', depositOpacity => 'depositOpacity', pointSize => 'pointSize',
        posX => 'posX', posY => 'posY', posZ => 'posZ', rotateX => 'rotateX', rotateY => 'rotateY',
        rotateZ => 'rotateZ', rotationVar => 'rotationVar', seed => 'seed', shapeMode => 'shapeMode',
        sizeVariation => 'sizeVariation', viewMode => 'viewMode', viewScale => 'viewScale',
        fieldOfView => 'fieldOfView', sizeDistance => 'sizeDistance',
        brightnessDistance => 'brightnessDistance', aperture => 'aperture', focalDistance => 'focalDistance',
    );
    my %deposit_inputs = (rgbaTex => 'global_rgba', spriteTex => 'tex', xyzTex => 'global_xyz');
    return {
        namespace  => 'render',
        func       => 'pointsBillboardRender',
        params     => \%params,
        paramOrder => \@order,
        passes     => [
            { name => 'diffuse', program => 'diffuse', inputs => { trailTex => 'global_billboard_trail' },
              outputs => { fragColor => 'global_billboard_trail' }, uniforms => { intensity => 'intensity' } },
            { name => 'copy', program => 'copy', inputs => { sourceTex => 'global_billboard_trail' },
              outputs => { fragColor => 'global_billboard_trail' }, uniforms => {} },
            { name => 'deposit', program => 'deposit', drawMode => 'billboards', count => 'input', blend => JSON::PP::true,
              key => undef, inputs => { %deposit_inputs }, outputs => { fragColor => 'global_billboard_trail' },
              uniforms => { %deposit_uniforms },
              conditions => { runIf => [ { uniform => 'blendMode', equals => 0 } ] } },
            { name => 'deposit_alpha', program => 'deposit', drawMode => 'billboards', count => 'input',
              blend => ['ONE', 'ONE_MINUS_SRC_ALPHA'], key => undef, inputs => { %deposit_inputs },
              outputs => { fragColor => 'global_billboard_trail' }, uniforms => { %deposit_uniforms },
              conditions => { runIf => [ { uniform => 'blendMode', equals => 1 } ] } },
            { name => 'blend', program => 'blend', inputs => { inputTex => 'inputTex', trailTex => 'global_billboard_trail' },
              outputs => { fragColor => 'outputTex' }, uniforms => { blendMode => 'blendMode', inputIntensity => 'inputIntensity' } },
        ],
        textures => {
            global_billboard_trail => { format => 'rgba16f', width => '100%', height => '100%' },
        },
        externalTexture => undef,
    };
}

our %COMPUTED_DEFS = (
    'mixer/mashup'                  => _mashup(),
    'synth/remap'                   => _remap(),
    'render/pointsBillboardRender'  => _points_billboard_render(),
);

1;
