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

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(%COMPUTED_DEFS);

use constant _MASHUP_LAYERS => 8;
use constant _REMAP_ZONES   => 8;

sub _mashup {
    my %params = (
        source     => { type => 'surface', default => 'none' },
        layers     => { type => 'int',   default => 4,   uniform => 'layers' },
        smoothness => { type => 'float', default => 0.1, uniform => 'smoothness' },
    );
    my %inputs = (source => 'source');
    for my $e (0 .. _MASHUP_LAYERS - 1) {
        $params{"layer${e}_tex"} =
            { type => 'surface', default => 'none', colorModeUniform => "layer${e}_active" };
        $inputs{"layer${e}_tex"} = "layer${e}_tex";
    }
    return {
        namespace => 'mixer',
        func      => 'mashup',
        params    => \%params,
        passes    => [
            { name => 'render', program => 'mashup', inputs => \%inputs, outputs => { fragColor => 'outputTex' } }
        ],
        textures        => {},
        externalTexture => undef,
    };
}

sub _remap {
    my %params = (
        zoneCount  => { type => 'int',   default => 0,        uniform => 'zoneCount' },
        bgColor    => { type => 'color', default => [0, 0, 0], uniform => 'bgColor' },
        bgAlpha    => { type => 'float', default => 1,        uniform => 'bgAlpha' },
        smoothEdge => { type => 'float', default => 0.04,     uniform => 'smoothEdge' },
    );
    my %inputs;
    for my $z (0 .. _REMAP_ZONES - 1) {
        $params{"zone${z}_tex"} =
            { type => 'surface', default => 'none', colorModeUniform => "zone${z}_active" };
        $inputs{"zone${z}_tex"} = "zone${z}_tex";
    }
    return {
        namespace => 'synth',
        func      => 'remap',
        params    => \%params,
        passes    => [
            { name => 'render', program => 'remap', inputs => \%inputs, outputs => { fragColor => 'outputTex' } }
        ],
        textures        => {},
        externalTexture => undef,
    };
}

our %COMPUTED_DEFS = (
    'mixer/mashup' => _mashup(),
    'synth/remap'  => _remap(),
);

1;
