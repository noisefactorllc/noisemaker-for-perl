package Math::Fractal::Noisemaker::ExternalInput;

# CPU external-input state for the reactive (MIDI/audio) and mesh (OBJ) effects.
#
# Port of noisemaker-cpu src/runtime/external-input.js (itself a port of the
# rendering-relevant subset of the upstream MidiState/AudioState and OBJ parser)
# and src/runtime/external-textures.js. Deterministic by design: no MIDI ports,
# no timing. Fixtures feed raw message bytes through MidiState->handle_message
# exactly as the authority capture harness does.
#
# Float32Array semantics: every array produced here is f32-rounded on store,
# as the JS writes these values into Float32Arrays.

use strict;
use warnings;
use Exporter 'import';
use Math::Fractal::Noisemaker::Surface;

our @EXPORT_OK = qw(parse_obj pack_mesh_data_for_textures flip_rgba_rows external_data_surface);

sub _f32 { unpack('f', pack('f', $_[0])) }

# JS Math.round: ties toward +infinity.
sub _js_round {
    my ($v) = @_;
    my $f = POSIX::floor($v);
    return ($v - $f) >= 0.5 ? $f + 1 : $f;
}

# JS parseInt / parseFloat over a token: the longest leading numeric prefix
# after whitespace. An unparsable index is -1 + 1 (NaN - 1 never indexes an
# array); an unparsable coordinate is 0, as the JS `|| 0` makes it.
sub _js_parse_int {
    my ($text) = @_;
    return defined $text && $text =~ /\A\s*([+-]?\d+)/ ? 0 + $1 : -1;
}

sub _js_parse_float {
    my ($text) = @_;
    return defined $text && $text =~ /\A\s*([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)/ ? 0 + $1 : 0.0;
}

package Math::Fractal::Noisemaker::ExternalInput::MidiChannelState;

sub new {
    my ($class) = @_;
    my $self = bless {}, $class;
    $self->reset;
    $self->{program} = 0;
    return $self;
}

sub note_on {
    my ($self, $key, $velocity) = @_;
    $self->{key}      = $key;
    $self->{velocity} = $velocity;
    $self->{gate}     = 1;
    $self->{keys}[$key] = $velocity;
}

sub note_off {
    my ($self, $key) = @_;
    $self->{gate} = 0;
    if (!defined $key) {
        $self->{keys} = [(0) x 128];
        return;
    }
    $self->{keys}[$key] = 0;
    $self->{poly_pressure}[$key] = 0;
}

sub control_change {
    my ($self, $controller, $value) = @_;
    return unless _is_int($controller) && $controller >= 0 && $controller <= 127
        && _is_int($value) && $value >= 0 && $value <= 127;
    $self->{cc}[$controller] = $value;
    if ($controller == 120 || $controller == 123) {
        $self->{gate} = 0;
        $self->{keys} = [(0) x 128];
    }
    elsif ($controller == 121) {
        $self->{cc} = [map { $_ == 11 ? 127 : 0 } 0 .. 127];
        $self->{pitch_bend} = 8192;
        $self->{pressure}   = 0;
        $self->{poly_pressure} = [(0) x 128];
    }
}

sub reset {
    my ($self) = @_;
    $self->{key}           = 0;
    $self->{velocity}      = 0;
    $self->{gate}          = 0;
    $self->{keys}          = [(0) x 128];
    $self->{cc}            = [(0) x 128];
    $self->{pitch_bend}    = 8192;
    $self->{pressure}      = 0;
    $self->{poly_pressure} = [(0) x 128];
    $self->{program}       = 0;
}

sub _is_int { defined $_[0] && $_[0] =~ /\A-?\d+\z/ }

package Math::Fractal::Noisemaker::ExternalInput::MidiState;

use constant UNROUTED => 0;

sub new {
    my ($class) = @_;
    my $self = bless {
        channels    => { map { $_ => Math::Fractal::Noisemaker::ExternalInput::MidiChannelState->new } 1 .. 16 },
        # MIDI clock pulse count (24 PPQ).
        clock_count => 0,
        # Note grid texture data: 128 keys x 16 channels x RGBA. Row 0 is
        # channel 1; R = velocity (0-1), G = gate, B = A = 0.
        note_grid   => [(0.0) x (128 * 16 * 4)],
    }, $class;
    return $self;
}

sub clock_count { $_[0]{clock_count} }
sub note_grid   { $_[0]{note_grid} }

sub get_channel {
    my ($self, $channel) = @_;
    return undef unless Math::Fractal::Noisemaker::ExternalInput::MidiChannelState::_is_int($channel)
        && $channel >= 1 && $channel <= 16;
    return $self->{channels}{$channel};
}

sub update_note_grid {
    my ($self) = @_;
    for my $ch (0 .. 15) {
        my $keys = $self->{channels}{ $ch + 1 }{keys};
        my $row_offset = $ch * 128 * 4;
        for my $k (0 .. 127) {
            my $v = $keys->[$k];
            my $offset = $row_offset + $k * 4;
            $self->{note_grid}[$offset]     = $v > 0 ? Math::Fractal::Noisemaker::ExternalInput::_f32($v / 127) : 0.0;
            $self->{note_grid}[$offset + 1] = $v > 0 ? 1.0 : 0.0;
        }
    }
}

sub reset {
    my ($self) = @_;
    $_->reset for values %{ $self->{channels} };
    $self->{clock_count} = 0;
    $self->{note_grid} = [(0.0) x (128 * 16 * 4)];
}

# Process a raw MIDI message [status, data1, data2]. Mirrors the upstream
# routing for the message types that reach rendered state. Returns 0 when
# routed, -1 when the status byte or data is unhandled.
sub handle_message {
    my ($self, $data) = @_;
    return UNROUTED if !defined $data || !@$data;
    my $status = $data->[0];
    if ($status == 0xf8) {
        $self->{clock_count}++;
        return 0;
    }
    if ($status == 0xff) {
        $self->reset;
        return 0;
    }
    my ($key, $velocity) = @$data[1, 2];
    my $channel = ($status & 0x0f) + 1;
    my $type = $status & 0xf0;
    my $is_int = \&Math::Fractal::Noisemaker::ExternalInput::MidiChannelState::_is_int;
    return -1 if $type == 0xf0;
    return -1 unless $is_int->($key) && $key >= 0 && $key <= 127;
    return -1 if $type != 0xd0 && !($is_int->($velocity) && $velocity >= 0 && $velocity <= 127);
    my $state = $self->get_channel($channel) // return -1;
    if ($type == 0x90 && $velocity > 0) { $state->note_on($key, $velocity); return 0 }
    if ($type == 0x80 || ($type == 0x90 && $velocity == 0)) { $state->note_off($key); return 0 }
    if ($type == 0xa0) { $state->{poly_pressure}[$key] = $velocity; return 0 }
    if ($type == 0xb0) { $state->control_change($key, $velocity); return 0 }
    if ($type == 0xc0) { $state->{program} = $key; return 0 }
    if ($type == 0xd0) { $state->{pressure} = $key; return 0 }
    if ($type == 0xe0) { $state->{pitch_bend} = $key | ($velocity << 7); return 0 }
    return -1;
}

package Math::Fractal::Noisemaker::ExternalInput::AudioState;

# Audio analysis state for the reactive synth effects: 128-float waveform and
# spectrum arrays normalized to 0-1.
sub new {
    my ($class) = @_;
    return bless { waveform => [(0.0) x 128], spectrum => [(0.0) x 128] }, $class;
}

sub waveform { $_[0]{waveform} }
sub spectrum { $_[0]{spectrum} }

sub set_waveform {
    my ($self, $values) = @_;
    die "audio waveform requires exactly 128 samples\n" unless @$values == 128;
    $self->{waveform} = [map { Math::Fractal::Noisemaker::ExternalInput::_f32($_) } @$values];
}

sub set_spectrum {
    my ($self, $values) = @_;
    die "audio spectrum requires exactly 128 bins\n" unless @$values == 128;
    $self->{spectrum} = [map { Math::Fractal::Noisemaker::ExternalInput::_f32($_) } @$values];
}

package Math::Fractal::Noisemaker::ExternalInput;

use POSIX ();

# Parse Wavefront OBJ text into de-indexed triangle-soup vertex data: fan
# triangulation for faces with more than three vertices, reversed winding (OBJ
# CW to GL CCW), smooth normals when the file has no `vn` lines. Returns
# f32-rounded arrays like the JS Float32Array conversion.
sub parse_obj {
    my ($text) = @_;
    my (@raw_positions, @raw_normals, @raw_uvs, @positions, @normals, @uvs);
    for my $raw_line (split /\n/, $text) {
        (my $line = $raw_line) =~ s/\A\s+|\s+\z//g;
        next if $line eq '' || $line =~ /\A#/;
        my @parts = split /\s+/, $line;
        my $cmd = $parts[0];
        if ($cmd eq 'v') {
            push @raw_positions, [map { _js_parse_float($parts[$_]) } 1 .. 3];
        }
        elsif ($cmd eq 'vn') {
            push @raw_normals, [map { _js_parse_float($parts[$_]) } 1 .. 3];
        }
        elsif ($cmd eq 'vt') {
            push @raw_uvs, [map { _js_parse_float($parts[$_]) } 1 .. 2];
        }
        elsif ($cmd eq 'f') {
            my @face;
            for my $i (1 .. $#parts) {
                my @idx = split m{/}, $parts[$i], -1;
                push @face, {
                    v  => _js_parse_int($idx[0]) - 1,
                    vt => (defined $idx[1] && length $idx[1]) ? _js_parse_int($idx[1]) - 1 : -1,
                    vn => (defined $idx[2] && length $idx[2]) ? _js_parse_int($idx[2]) - 1 : -1,
                };
            }
            # Fan triangulation, reversed winding: OBJ CW to OpenGL CCW.
            for my $i (1 .. $#face - 1) {
                for my $vertex ($face[0], $face[ $i + 1 ], $face[$i]) {
                    _add_vertex($vertex, \@raw_positions, \@raw_normals, \@raw_uvs,
                        \@positions, \@normals, \@uvs);
                }
            }
        }
    }
    _compute_smooth_normals(\@positions, \@normals) if !@raw_normals && @positions;
    return {
        positions   => [map { _f32($_) } @positions],
        normals     => [map { _f32($_) } @normals],
        uvs         => [map { _f32($_) } @uvs],
        vertexCount => int(@positions / 3),
    };
}

sub _add_vertex {
    my ($v, $raw_positions, $raw_normals, $raw_uvs, $positions, $normals, $uvs) = @_;
    push @$positions, ($v->{v} >= 0 && $v->{v} < @$raw_positions)
        ? @{ $raw_positions->[ $v->{v} ] } : (0.0, 0.0, 0.0);
    push @$normals, ($v->{vn} >= 0 && $v->{vn} < @$raw_normals)
        ? @{ $raw_normals->[ $v->{vn} ] } : (0.0, 0.0, 1.0);
    push @$uvs, ($v->{vt} >= 0 && $v->{vt} < @$raw_uvs)
        ? @{ $raw_uvs->[ $v->{vt} ] } : (0.0, 0.0);
}

# Smooth vertex normals for an OBJ without normals: face normals of the
# reversed-winding triangles, averaged per position rounded to 1e-4. JS
# arithmetic is f64; the result is stored f32 by the caller.
sub _compute_smooth_normals {
    my ($positions, $normals) = @_;
    my $vertex_count = int(@$positions / 3);
    my $triangle_count = int($vertex_count / 3);
    my @face;
    for my $tri (0 .. $triangle_count - 1) {
        my ($ax, $ay, $az, $bx, $by, $bz, $cx, $cy, $cz) = @$positions[ $tri * 9 .. $tri * 9 + 8 ];
        my ($e1x, $e1y, $e1z) = ($bx - $ax, $by - $ay, $bz - $az);
        my ($e2x, $e2y, $e2z) = ($cx - $ax, $cy - $ay, $cz - $az);
        my $nx = $e1y * $e2z - $e1z * $e2y;
        my $ny = $e1z * $e2x - $e1x * $e2z;
        my $nz = $e1x * $e2y - $e1y * $e2x;
        my $len = sqrt($nx * $nx + $ny * $ny + $nz * $nz);
        @face[ $tri * 3 .. $tri * 3 + 2 ] = $len > 0.0001 ? ($nx / $len, $ny / $len, $nz / $len) : (0, 0, 1);
    }
    # The JS keys are template strings of numbers, which print -0 as "0".
    my $key = sub {
        join ',', map { my $r = _js_round($_ * 10_000) / 10_000; $r == 0 ? '0' : $r } @_;
    };
    my %acc;
    for my $v (0 .. $vertex_count - 1) {
        my $k = $key->(@$positions[ $v * 3 .. $v * 3 + 2 ]);
        my $tri = int($v / 3);
        my $a = $acc{$k} ||= [0.0, 0.0, 0.0];
        $a->[$_] += $face[ $tri * 3 + $_ ] for 0 .. 2;
    }
    for my $a (values %acc) {
        my $len = sqrt($a->[0] ** 2 + $a->[1] ** 2 + $a->[2] ** 2);
        @$a = $len > 0.0001 ? map { $_ / $len } @$a : (0, 0, 1);
    }
    for my $v (0 .. $vertex_count - 1) {
        @$normals[ $v * 3 .. $v * 3 + 2 ] = @{ $acc{ $key->(@$positions[ $v * 3 .. $v * 3 + 2 ]) } };
    }
}

# Pack triangle-soup mesh data into texture-sized RGBA arrays: one texel per
# vertex; position w = 1 marks a valid vertex, the remaining texels keep w = 0.
sub pack_mesh_data_for_textures {
    my ($positions, $normals, $uvs, $tex_width, $tex_height) = @_;
    my $pixels = $tex_width * $tex_height;
    my $vertex_count = int(@$positions / 3);
    my $used = $vertex_count < $pixels ? $vertex_count : $pixels;
    my @position_data = (0.0) x ($pixels * 4);
    my @normal_data   = (0.0) x ($pixels * 4);
    my @uv_data       = (0.0) x ($pixels * 4);
    for my $i (0 .. $used - 1) {
        my ($pi, $v3, $v2) = ($i * 4, $i * 3, $i * 2);
        @position_data[ $pi .. $pi + 3 ] = ((map { _f32($positions->[ $v3 + $_ ]) } 0 .. 2), 1.0);
        @normal_data[ $pi .. $pi + 3 ]   = ((map { _f32($normals->[ $v3 + $_ ]) } 0 .. 2), 0.0);
        @uv_data[ $pi .. $pi + 3 ]       = (_f32($uvs->[$v2]), _f32($uvs->[ $v2 + 1 ]), 0.0, 0.0);
    }
    return {
        positionData => \@position_data,
        normalData   => \@normal_data,
        uvData       => \@uv_data,
        vertexCount  => $used,
    };
}

# Data textures uploaded from arrays place array row 0 at GL texture y = 0
# (bottom-left origin). CPU surfaces store rows top-down and the samplers flip
# y, so a data-texture surface stores the uploaded rows reversed. The mesh
# triangles adapter reads the raw arrays directly (no flip) through the
# external inputs.
sub flip_rgba_rows {
    my ($data, $width, $height) = @_;
    my $row_len = $width * 4;
    my @flipped;
    for my $row (0 .. $height - 1) {
        my $source = ($height - 1 - $row) * $row_len;
        push @flipped, @$data[ $source .. $source + $row_len - 1 ];
    }
    return \@flipped;
}

# The rgba32f data texture an external array uploads as, sampled nearest.
sub external_data_surface {
    my ($data, $width, $height) = @_;
    my $surface = Math::Fractal::Noisemaker::Surface->new(
        $width, $height, [map { _f32($_ // 0) } @{ flip_rgba_rows($data, $width, $height) }]);
    $surface->filter('nearest');
    return $surface;
}

1;
