package ReactiveFixtures;

# Deterministic external-input fixtures for the five reactive/mesh authority
# cases (synth/roll, synth/scope, synth/spectrum, render/meshLoader,
# render/meshRender): a port of the pinned oracle's
# scripts/parity/reactive-fixtures.js, whose values the oracle side binds.
#
#   - MIDI: channel 1 C-major triad (60/64/67, velocities 100/80/90), channel 2
#     low C (48, velocity 64), then 24 clock pulses
#   - audio: waveform 0.5 + 0.5 sin(2 pi 3 i / 128) and spectrum (1 - i/127)^2,
#     128 samples, stored f32
#   - mesh: a 12-triangle cube OBJ packed into 256x256 RGBA mesh textures
#
# Both engines render the exact DSL program the oracle's parity fixtures run
# (parity/upstream-defaults/<case>.dsl) with these fixtures bound.

use strict;
use warnings;
use Exporter 'import';
use Math::Fractal::Noisemaker::ExternalInput qw(parse_obj pack_mesh_data_for_textures);
use Math::Fractal::Noisemaker::JsTrig qw(js_sin);

our @EXPORT_OK = qw(%EXTERNAL_INPUT_SOURCES external_inputs_for);

our %EXTERNAL_INPUT_SOURCES = (
    'synth/roll'        => "search synth\n\nroll()\n.write(o0)\n\nrender(o0)\n",
    'synth/scope'       => "search synth\n\nscope()\n.write(o0)\n\nrender(o0)\n",
    'synth/spectrum'    => "search synth\n\nspectrum()\n.write(o0)\n\nrender(o0)\n",
    'render/meshLoader' => "search render\n\nmeshLoader().write(o0)\n\nrender(o0)\n",
    'render/meshRender' => "search render\n\nmeshLoader()\n  .meshRender()\n  .write(o0)\n\nrender(o0)\n",
);

my @MIDI_MESSAGES = (
    [0x90, 60, 100], [0x90, 64, 80], [0x90, 67, 90],
    [0x91, 48, 64],
    map { [0xf8] } 1 .. 24,
);

my $CUBE_OBJ = join "\n",
    'v -0.7 -0.7 -0.7', 'v 0.7 -0.7 -0.7', 'v 0.7 0.7 -0.7', 'v -0.7 0.7 -0.7',
    'v -0.7 -0.7 0.7', 'v 0.7 -0.7 0.7', 'v 0.7 0.7 0.7', 'v -0.7 0.7 0.7',
    'vn 0 0 -1', 'vn 0 0 1', 'vn 0 -1 0', 'vn 0 1 0', 'vn -1 0 0', 'vn 1 0 0',
    'f 1//1 2//1 3//1 4//1', 'f 5//2 8//2 7//2 6//2', 'f 1//3 5//3 6//3 2//3',
    'f 2//4 6//4 7//4 3//4', 'f 3//5 7//5 8//5 4//5', 'f 4//6 8//6 5//6 1//6',
    '';

my ($MESH_TEX_WIDTH, $MESH_TEX_HEIGHT) = (256, 256);
my $PI = 4 * atan2(1, 1);

sub midi_fixture {
    my $midi = Math::Fractal::Noisemaker::ExternalInput::MidiState->new;
    $midi->handle_message($_) for @MIDI_MESSAGES;
    $midi->update_note_grid;
    return $midi;
}

sub audio_fixture {
    my $audio = Math::Fractal::Noisemaker::ExternalInput::AudioState->new;
    $audio->set_waveform([map { 0.5 + 0.5 * js_sin((2 * $PI * 3 * $_) / 128) } 0 .. 127]);
    $audio->set_spectrum([map { (1 - $_ / 127) ** 2 } 0 .. 127]);
    return $audio;
}

sub mesh_fixture {
    my $parsed = parse_obj($CUBE_OBJ);
    my $packed = pack_mesh_data_for_textures(
        @$parsed{qw(positions normals uvs)}, $MESH_TEX_WIDTH, $MESH_TEX_HEIGHT);
    return { %$packed, texWidth => $MESH_TEX_WIDTH, texHeight => $MESH_TEX_HEIGHT };
}

# External inputs for one parity case id, or undef when the case needs none.
sub external_inputs_for {
    my ($id) = @_;
    return { midiState => midi_fixture() } if $id eq 'synth/roll';
    return { audioState => audio_fixture() } if $id eq 'synth/scope' || $id eq 'synth/spectrum';
    return { meshData => mesh_fixture() } if $id eq 'render/meshLoader' || $id eq 'render/meshRender';
    return undef;
}

1;
