package Math::Fractal::Noisemaker::Renderer;

# Render a bundled effect: load metadata + transpiled kernel, run the pass(es).
#
# Faithful port of the (167/167 parity-proven) Python renderer: canonical
# uniforms matching createCanonicalBindings, seed threading into an effect's
# own `seed` param, texture-filter model (only the declared externalTexture is
# 'linear'; pooled surfaces stay 'nearest'), per-pass quantization to the
# attachment's texture format, multi-pass named-attachment tracking, and
# pass-level uniform aliases.

use strict;
use warnings;
use File::Basename ();
use File::Spec     ();
use JSON::PP       ();
use Exporter 'import';
use POSIX          ();
use Scalar::Util qw(looks_like_number);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

use Math::Fractal::Noisemaker::CpuFrameExportAdapter;
use Math::Fractal::Noisemaker::DSL qw(compile_dsl);
use Math::Fractal::Noisemaker::FrameExportQueue;
use Math::Fractal::Noisemaker::KernelCache;
use Math::Fractal::Noisemaker::Iteration qw(
    compute_iteration_groups
    is_particle_state_name
    iteration_delta_time
    wrap01
);
use Math::Fractal::Noisemaker::PassRunner qw(run_pass run_pass_deriv run_pass_mrt);
use Math::Fractal::Noisemaker::Runtime;
use Math::Fractal::Noisemaker::Surface;
use Math::Fractal::Noisemaker::SinkManager;
use Math::Fractal::Noisemaker::TextureFormat qw(quantize_texture);
use Math::Fractal::Noisemaker::Adapters      ();
use Math::Fractal::Noisemaker::DrawOps       ();
use Math::Fractal::Noisemaker::OverlayGen    ();
use Math::Fractal::Noisemaker::PaletteData   ();

our @EXPORT_OK = qw(render_effect render_dsl meta bundle_dir);

my $_JSON = JSON::PP->new->utf8;
my $META;
my $CACHE = Math::Fractal::Noisemaker::KernelCache->new;

sub f32 { unpack('f', pack('f', $_[0])) }

sub _is_chain_bundle {
    my ($value) = @_;
    return ref $value eq 'HASH' && exists $value->{image};
}

sub _chain_bundle {
    my ($value) = @_;
    return $value if _is_chain_bundle($value);
    return { image => $value, volume => undef, geometry => undef, volumeSize => undef };
}

sub _bundle_output {
    my ($name, $input, $resources) = @_;
    return $input unless defined $name;
    return $input if $name eq 'inputTex' || $name eq 'inputTex3d' || $name eq 'inputGeo';
    return $resources->{$name};
}

sub bundle_dir {
    return $ENV{NOISEMAKER_BUNDLE}
        || File::Spec->catdir(File::Basename::dirname(__FILE__), 'bundle');
}

sub meta {
    if (!$META) {
        my $path = File::Spec->catfile(bundle_dir(), 'metadata.json');
        open my $fh, '<:raw', $path or die "cannot read bundle metadata $path: $!\n";
        local $/;
        $META = $_JSON->decode(scalar <$fh>);
    }
    return $META;
}

sub _kernel_for {
    my ($key) = @_;
    return $CACHE->get(
        $key,
        sub {
            (my $fname = $key) =~ s{[/:]}{__}g;
            my $path = File::Spec->catfile(bundle_dir(), 'kernels', 'perl', "$fname.pl");
            open my $fh, '<:raw', $path or die "cannot read kernel $path: $!\n";
            local $/;
            return scalar <$fh>;
        }
    );
}

sub _parse_hex {
    my ($s) = @_;
    $s =~ s/^#//;
    $s = join '', map { $_ x 2 } split //, $s if length($s) == 3;
    my @rgb = map { hex(substr($s, $_ * 2, 2)) / 255.0 } 0 .. 2;
    if (length($s) >= 8) {
        push @rgb, hex(substr($s, 6, 2)) / 255.0;
    }
    return \@rgb;
}

sub _choice_value {
    my ($spec, $value) = @_;
    return undef if !defined $value || ref $value || ref $spec->{choices} ne 'HASH';
    my ($key) = $value =~ /([^.]+)$/;
    my $choices = $spec->{choices};
    my $choice = exists $choices->{$value} ? $choices->{$value}
        : defined $key ? $choices->{$key} : undef;
    # Catalog dropdowns also contain non-selectable group headings (null).
    return _finite_number($choice) ? $choice : undef;
}

sub _coerce {
    my ($spec, $value) = @_;
    my $t = $spec->{type} || '';
    $value = $spec->{default} unless defined $value;
    if ($t =~ /\A(?:float|int|enum|member|palette)\z/
        && defined $value && !looks_like_number($value)) {
        my $choice = _choice_value($spec, $value);
        $value = $choice if defined $choice;
    }
    if ($t eq 'color') {
        $value = _parse_hex($value) if defined $value && !ref $value;
        return [map { f32($_) } @{ $value || [0, 0, 0] }];
    }
    if ($t eq 'vec2' || $t eq 'vec3' || $t eq 'vec4' || $t eq 'mat3') {
        if (defined $value && !ref $value) {    # CLI --param: "0.1,0.2,0.3"
            $value = [map { 0 + $_ } split /,/, $value];
        }
        return [map { f32($_) } @{ $value || [] }];
    }
    if ($t eq 'float') {
        return f32(defined $value ? $value : 0);
    }
    if ($t eq 'int' || $t eq 'enum' || $t eq 'member' || $t eq 'palette') {
        if (defined $value && !looks_like_number($value)) {    # enum name lookup
            return 0;    # CDN member with no inline choices: 0th member
        }
        return int(defined $value ? $value : 0);
    }
    if ($t eq 'bool' || $t eq 'boolean') {
        if (defined $value && $value =~ /^\s*(?:1|true|yes|on)\s*$/i) { return 1 }
        if (defined $value && $value =~ /^\s*(?:0|false|no|off)\s*$/i) { return 0 }
        return (defined $value && $value) ? 1 : 0;
    }
    return $value;
}

sub _finite_number {
    my ($value) = @_;
    return defined $value && !ref $value && looks_like_number($value)
        && POSIX::isfinite(0 + $value);
}

# Slider ranges and numeric dropdown choices are UI hints: callers also use
# small CPU state buffers and seeds outside those ranges. Reject malformed
# values without clamping or changing valid numeric rendering behavior.
sub _validate_parameters {
    my ($effect_id, $effect, $params) = @_;
    die "Parameters for $effect_id must be a hash reference\n" unless ref $params eq 'HASH';
    my $specs = $effect->{params} || {};
    for my $name (sort keys %$params) {
        die "Unknown parameter '$name' for $effect_id; accepted: "
            . join(', ', @{ $effect->{paramOrder} || [sort keys %$specs] }) . "\n"
            unless exists $specs->{$name};
        my $value = $params->{$name};
        next unless defined $value;    # undef requests the catalog default
        my $spec = $specs->{$name};
        my $type = $spec->{type} || '';
        my $bad = sub { die "Invalid parameter '$name' for $effect_id: $_[0]\n" };
        if ($type =~ /\A(?:float|int|enum|member|palette)\z/ && !_finite_number($value)) {
            my $choice = _choice_value($spec, $value);
            $value = $choice if defined $choice;
        }
        if ($type eq 'float') {
            $bad->('expected a finite number') unless _finite_number($value);
        }
        elsif ($type =~ /\A(?:int|enum|member|palette)\z/) {
            if (_finite_number($value)) {
                $bad->('expected an integer') unless $value == int($value);
            }
            else {
                my $choices = ref $spec->{choices} eq 'HASH' ? $spec->{choices} : {};
                # Some shared enums have only their default in the bundle.
                next if !keys %$choices && !ref $value && defined $spec->{default} && !ref $spec->{default}
                    && $value eq $spec->{default};
                my @names = sort grep { _finite_number($choices->{$_}) } keys %$choices;
                $bad->('expected an integer or a named choice'
                    . (@names ? '; choices: ' . join(', ', @names) : ''));
            }
        }
        elsif ($type eq 'bool' || $type eq 'boolean') {
            next if JSON::PP::is_bool($value);
            $bad->('expected a boolean (0, 1, true, false, yes, no, on, off)')
                unless !ref $value && $value =~ /\A\s*(?:0|1|true|false|yes|no|on|off)\s*\z/i;
        }
        elsif ($type eq 'color') {
            if (!ref $value) {
                $bad->('expected #RGB, #RRGGBB, #RRGGBBAA, or an RGB/RGBA array')
                    unless $value =~ /\A\#?(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})\z/;
            }
            else {
                $bad->('expected three or four finite color components')
                    unless ref $value eq 'ARRAY' && (@$value == 3 || @$value == 4)
                        && !grep { !_finite_number($_) } @$value;
            }
        }
        elsif ($type =~ /\Avec([234])\z/ || $type eq 'mat3') {
            my $length = $type eq 'mat3' ? 9 : substr($type, -1);
            my $items = ref $value ? $value : [split /,/, $value, -1];
            $bad->("expected $length finite components")
                unless ref $items eq 'ARRAY' && @$items == $length
                    && !grep { !_finite_number($_) } @$items;
        }
        elsif ($type eq 'string') {
            $bad->('expected a string') if ref $value;
        }
        elsif ($type eq 'surface') {
            $bad->('bind surfaces in the inputs hash, not the parameters hash');
        }
        elsif ($type eq 'volume' || $type eq 'geometry') {
            # These catalog markers describe the chain input. They do not
            # select arbitrary resources; actual surfaces use the inputs hash.
            next if !ref $value && defined $spec->{default} && $value eq $spec->{default};
            my $binding = $type eq 'volume' ? 'inputTex3d' : 'inputGeo';
            $bad->("bind $type resources using $binding in the inputs hash");
        }
    }
}

# Pack synth/remap's std140 data[267] block from the bound uniforms — port of
# the reference remapUniformData. At zoneCount=0 this yields the background
# color for every pixel.
sub _remap_uniform_data {
    my ($u, $width, $height) = @_;
    my $g = sub { my ($name, $default) = @_; defined $u->{$name} ? $u->{$name} : $default };
    my @data = map { [0.0, 0.0, 0.0, 0.0] } 1 .. 267;
    my $bg = $g->('bgColor', [0, 0, 0]);
    # Elements snap to f32 — the reference packs a Float32Array (numpy F32).
    $data[0] = [map { f32($_) } $bg->[0], $bg->[1], $bg->[2], $g->('bgAlpha', 1)];
    $data[1] = [map { f32($_) } $g->('zoneCount', 0), $g->('smoothEdge', 0.04), 0, $g->('time', 0)];
    for my $zone (0 .. 7) {
        $data[ 2 + $zone ] = [
            map { f32($_) } $g->("zone${zone}_count", 0), $g->("zone${zone}_active", 0),
            0, $g->("zone${zone}_alpha", 1),
        ];
        for my $pair (0 .. 31) {
            my $v = $g->("zone${zone}_v${pair}", [0, 0, 0, 0]);
            $data[ 10 + $zone * 32 + $pair ] = [map { f32($_) } @$v];
        }
    }
    $data[266] = [0.0 + $width, 0.0 + $height, 0, 0];
    return \@data;
}

# Match the reference engine's createCanonicalBindings.
sub _canonical_uniforms {
    my ($width, $height, $time, $seed, $effect_uniforms, $frame, $delta_time, $full_width, $full_height) = @_;
    $frame = 0 unless defined $frame;
    $delta_time = 0 unless defined $delta_time;
    $full_width = $width unless defined $full_width;
    $full_height = $height unless defined $full_height;
    my $res    = [0.0 + $width, 0.0 + $height];
    my $full   = [0.0 + $full_width, 0.0 + $full_height];
    my $aspect = f32($width / $height);
    my %u = (
        renderScale => f32(1.0),
        speed       => 0,
        seed        => f32($seed),
        centerLoX   => 0,
        centerLoY   => 0,
        size        => [0.0, 0.0, 0.0, 0.0],
        motion      => [0.0, 0.0, 0.0, 0.0],
    );
    %u = (%u, %$effect_uniforms);    # effect params override base defaults
    %u = (
        %u,
        resolution     => $res,      # canonical values always win
        fullResolution => $full,
        tileOffset     => [0.0, 0.0],
        aspectRatio    => $aspect,
        aspect         => $aspect,
        time           => f32($time),
        globalTime     => f32($time),
        deltaTime      => f32($delta_time),
        frame          => int($frame),
    );
    return \%u;
}

sub _normalized_params {
    my ($eff, $params, $seed) = @_;
    my %normalized;
    for my $name (sort keys %{ $eff->{params} || {} }) {
        my $spec = $eff->{params}{$name};
        next unless ref $spec eq 'HASH';
        next if ($spec->{type} || '') eq 'surface';
        my $value = ($name eq 'seed' && !exists $params->{seed}) ? $seed : $params->{$name};
        $normalized{$name} = _coerce($spec, $value);
    }
    return \%normalized;
}

sub _effect_bindings {
    my ($eff, $normalized, $inputs, $blank) = @_;
    my (%uniforms, %surfaces);
    for my $name (sort keys %{ $eff->{params} || {} }) {
        my $spec = $eff->{params}{$name};
        next unless ref $spec eq 'HASH';
        if (($spec->{type} || '') eq 'surface') {
            my $sampler = $spec->{uniform} || $spec->{texture} || $name;
            my $provided = defined $inputs->{$sampler} ? $inputs->{$sampler} : $inputs->{$name};
            $surfaces{$sampler} = defined $provided ? $provided : $blank;
            $uniforms{ $spec->{colorModeUniform} } = defined $provided ? 1 : 0
                if defined $spec->{colorModeUniform};
            next;
        }
        my $value = $normalized->{$name};
        $uniforms{ $spec->{uniform} } = $value if defined $spec->{uniform};
        $uniforms{ $spec->{define} }  = $value if defined $spec->{define};
    }

    if (($eff->{namespace} || '') eq 'classicNoisedeck') {
        my ($palette_name) = grep {
            ref $eff->{params}{$_} eq 'HASH' && ($eff->{params}{$_}{type} || '') eq 'palette'
        } sort keys %{ $eff->{params} || {} };
        if (defined $palette_name) {
            my $index = $normalized->{$palette_name};
            my $table = \@Math::Fractal::Noisemaker::PaletteData::PALETTE_DATA;
            if (defined $index && $index =~ /^\d+$/ && $index > 0 && $index <= @$table) {
                my $entry = $table->[ $index - 1 ];
                $uniforms{paletteAmp}    = [@{$entry}[0 .. 2]];
                $uniforms{paletteFreq}   = [@{$entry}[4 .. 6]];
                $uniforms{paletteOffset} = [@{$entry}[8 .. 10]];
                $uniforms{palettePhase}  = [@{$entry}[12 .. 14]];
                $uniforms{paletteMode}   = $entry->[3] == 0 ? 3 : int($entry->[3]);
            }
        }
    }
    return (\%uniforms, \%surfaces);
}

sub _texture_dimension {
    my ($spec, $axis, $params, $width, $height, $resources) = @_;
    my $fallback = $axis eq 'width' ? $width : $height;
    return $fallback if !defined $spec || (!ref $spec && $spec =~ /\A(?:input|screen|resolution|100%)\z/);
    if (!ref $spec && $spec =~ /\A\d+(?:\.\d+)?%\z/) {
        (my $percent = $spec) =~ s/%\z//;
        my $value = int($fallback * $percent / 100 + 0.5);
        return $value > 0 ? $value : 1;
    }
    if (!ref $spec) {
        my $value = int($spec + 0.5);
        return $value > 0 ? $value : 1;
    }
    if (ref $spec eq 'HASH' && exists $spec->{inputOverride}) {
        my $input = ($resources || {})->{ $spec->{inputOverride} };
        return $axis eq 'width' ? $input->width : $input->height if defined $input;
    }
    if (ref $spec eq 'HASH' && exists $spec->{param}) {
        my $value = defined $params->{ $spec->{param} }
            ? $params->{ $spec->{param} }
            : defined $spec->{paramDefault} ? $spec->{paramDefault} : $spec->{default};
        $value = 1 unless defined $value;
        $value = $value ** $spec->{power} if defined $spec->{power};
        $value = int($value + 0.5);
        return $value > 0 ? $value : 1;
    }
    if (ref $spec eq 'HASH' && exists $spec->{screenDivide}) {
        my $divisor = defined $params->{ $spec->{screenDivide} }
            ? $params->{ $spec->{screenDivide} } : $spec->{default};
        $divisor = 1 unless defined $divisor && $divisor > 0;
        my $value = int(($fallback + $divisor - 1) / $divisor);
        return $value > 0 ? $value : 1;
    }
    die "Unsupported canonical texture dimension\n";
}

sub _destination {
    my ($eff, $name, $params, $width, $height, $pass, $resources) = @_;
    my $spec = ($eff->{textures} || {})->{$name} || {};
    my $viewport = ($pass || {})->{viewport} || {};
    my $dest_width  = _texture_dimension(
        $viewport->{width} // $spec->{width},
        'width', $params, $width, $height, $resources,
    );
    my $dest_height = _texture_dimension(
        $viewport->{height} // $spec->{height},
        'height', $params, $width, $height, $resources,
    );
    return Math::Fractal::Noisemaker::Surface->new($dest_width, $dest_height);
}

sub _format_for {
    my ($eff, $name) = @_;
    return (($eff->{textures} || {})->{$name} || {})->{format} || 'rgba16f';
}

sub _prepare_state {
    my ($step, $width, $height, $seed, $owner_state_size, $input_bundle) = @_;
    my $eff = meta()->{effects}{ $step->{effect_id} }
        or die "unknown effect '$step->{effect_id}' (not in bundle)\n";
    _validate_parameters($step->{effect_id}, $eff, $step->{params});
    my %raw = %{ $step->{params} };
    $raw{stateSize} = $owner_state_size
        if defined $owner_state_size && exists(($eff->{params} || {})->{stateSize});
    my $normalized = _normalized_params($eff, \%raw, $seed);
    my $domain = $eff->{domain} || 'image';
    my $input_volume = ($input_bundle || {})->{volume};
    if (defined $input_volume && exists(($eff->{params} || {})->{volumeSize})
        && $domain =~ /\Avolume-(?:generator|filter|renderer)\z/) {
        my $volume_size = $input_volume->width;
        my $expected_height = $volume_size * $volume_size;
        die "$step->{effect_id} input volume atlas expected ${volume_size}x${expected_height}, received "
            . $input_volume->width . 'x' . $input_volume->height . "\n"
            if $input_volume->height != $expected_height;
        $normalized->{volumeSize} = $volume_size;
    }
    my $state = {
        step        => $step,
        effect_id   => $step->{effect_id},
        eff         => $eff,
        params      => $normalized,
        attachments => {},
        overlay_initialized => 0,
    };
    my $uses_self = grep {
        my $pass = $_;
        scalar grep { defined $_ && ($_ eq 'selfTex' || $_ eq 'feedback') }
            values %{ $pass->{inputs} || {} };
    } @{ $eff->{passes} || [] };
    if ($uses_self) {
        $state->{self_tex} = _destination($eff, 'outputTex', $normalized, $width, $height);
        $state->{self_tex}->clear;
    }
    return $state;
}

sub _particle_definition_state {
    my ($name, $states) = @_;
    for my $state (@$states) {
        return $state if exists(($state->{eff}{textures} || {})->{$name});
    }
    return undef;
}

sub _particle_destination {
    my ($name, $referencing_state, $states, $width, $height) = @_;
    my $owner = _particle_definition_state($name, $states);
    return _destination($owner->{eff}, $name, $owner->{params}, $width, $height) if $owner;
    my %format = (
        global_xyz       => 'rgba32f',
        global_vel       => 'rgba32f',
        global_rgba      => 'rgba8',
        global_life_data => 'rgba16f',
    );
    my $fallback = {
        textures => {
            $name => {
                width  => { param => 'stateSize', default => 256 },
                height => { param => 'stateSize', default => 256 },
                format => $format{$name} || 'rgba16f',
            },
        },
    };
    return _destination($fallback, $name, $referencing_state->{params}, $width, $height);
}

sub _output_destination {
    my ($name, $state, $states, $width, $height, $pass, $resources) = @_;
    return is_particle_state_name($name)
        ? _particle_destination($name, $state, $states, $width, $height)
        : _destination($state->{eff}, $name, $state->{params}, $width, $height, $pass, $resources);
}

sub _output_format {
    my ($name, $state, $states) = @_;
    if (is_particle_state_name($name)) {
        my $owner = _particle_definition_state($name, $states);
        return _format_for($owner->{eff}, $name) if $owner;
        return 'rgba32f' if $name eq 'global_xyz' || $name eq 'global_vel';
        return 'rgba8' if $name eq 'global_rgba';
        return 'rgba16f';
    }
    return _format_for($state->{eff}, $name);
}

sub _resolve_particle_input {
    my ($name, $state, $states, $group_resources, $width, $height) = @_;
    if (!defined $group_resources->{$name}) {
        $group_resources->{$name} = _particle_destination($name, $state, $states, $width, $height);
        $group_resources->{$name}->clear;
    }
    return $group_resources->{$name};
}

sub _store_output {
    my ($name, $surface, $state, $group_resources) = @_;
    if (is_particle_state_name($name) || $name eq 'global_accum') {
        $group_resources->{$name} = $surface;
    }
    else {
        $state->{attachments}{$name} = $surface;
    }
}

sub _pass_is_active {
    my ($pass, $uniforms) = @_;
    my $conditions = $pass->{conditions} || return 1;
    for my $entry (@{ $conditions->{runIf} || [] }) {
        return 0 if 0 + ($uniforms->{ $entry->{uniform} } || 0) != 0 + $entry->{equals};
    }
    for my $entry (@{ $conditions->{skipIf} || [] }) {
        return 0 if 0 + ($uniforms->{ $entry->{uniform} } || 0) == 0 + $entry->{equals};
    }
    return 1;
}

sub _repeat_count {
    my ($pass, $uniforms) = @_;
    my $repeat = $pass->{repeat};
    $repeat = defined $repeat && !ref $repeat && $repeat !~ /^-?\d+(?:\.\d+)?$/
        ? (defined $uniforms->{$repeat} ? $uniforms->{$repeat} : 1)
        : (defined $repeat ? $repeat : 1);
    $repeat = int($repeat);
    return $repeat > 0 ? $repeat : 0;
}

sub _pass_uniforms {
    my ($pass, $base, $params) = @_;
    my %uniforms = %$base;
    for my $name (sort keys %{ $pass->{uniforms} || {} }) {
        my $source = $pass->{uniforms}{$name};
        if (!ref $source && exists $params->{$source}) {
            $uniforms{$name} = $params->{$source};
        }
        elsif (!ref $source && exists $base->{$source}) {
            $uniforms{$name} = $base->{$source};
        }
        elsif (!(defined $source && !ref $source && $source eq $name && exists $uniforms{$name})) {
            $uniforms{$name} = $source;
        }
    }
    return \%uniforms;
}

sub _initialize_overlay {
    my ($state, $inputs, $width, $height) = @_;
    return if $state->{overlay_initialized}++;
    my $effect_id = $state->{effect_id};
    return unless Math::Fractal::Noisemaker::OverlayGen::is_overlay_effect($effect_id);
    my %produced;
    $produced{$_} = 1 for map { values %{ $_->{outputs} || {} } } @{ $state->{eff}{passes} || [] };
    return if $produced{overlayTex} || exists $inputs->{overlayTex};
    my %gen = map { $_ => $state->{params}{$_} } grep { exists $state->{params}{$_} } qw(seed density);
    $state->{attachments}{overlayTex} =
        Math::Fractal::Noisemaker::OverlayGen::render_worm_overlay($effect_id, $width, $height, \%gen);
}

sub _ensure_iteration_scratch {
    my ($state, $inputs, $width, $height) = @_;
    for my $name (sort keys %{ $state->{eff}{textures} || {} }) {
        next if is_particle_state_name($name);
        next if defined $state->{attachments}{$name} || defined $inputs->{$name};
        $state->{attachments}{$name} = _destination($state->{eff}, $name, $state->{params}, $width, $height);
        $state->{attachments}{$name}->clear;
    }
}

sub _seed_typed_inputs {
    my ($state, $input_bundle, $effective_inputs, $width, $height) = @_;
    for my $name (sort keys %{ $state->{eff}{params} || {} }) {
        my $spec = $state->{eff}{params}{$name};
        next unless ref $spec eq 'HASH';
        my $type = $spec->{type} || '';
        next unless $type eq 'volume' || $type eq 'geometry';
        my $input = $type eq 'volume' ? $input_bundle->{volume} : $input_bundle->{geometry};
        if (defined $input) {
            $effective_inputs->{$name} = $input;
            next;
        }
        if (defined $state->{attachments}{$name}) {
            $effective_inputs->{$name} = $state->{attachments}{$name};
            next;
        }
        my $output_name = $type eq 'volume'
            ? $state->{eff}{outputTex3d} : $state->{eff}{outputGeo};
        die "$state->{effect_id} parameter \"$name\" requires a $type input\n"
            unless defined $output_name
                && exists(($state->{eff}{textures} || {})->{$output_name});
        my $surface = _destination(
            $state->{eff}, $output_name, $state->{params}, $width, $height,
        );
        $surface->clear;
        $state->{attachments}{$name} = $surface;
        $effective_inputs->{$name} = $surface;
    }
}

sub _run_state_once {
    my ($state, $inputs, $states, $group_resources, %opt) = @_;
    my ($width, $height, $seed, $time) = @opt{qw(width height seed time)};
    my $input_bundle = $opt{input_bundle} || _chain_bundle($inputs->{inputTex});
    my $blank = Math::Fractal::Noisemaker::Surface->new(1, 1);
    my ($effect_uniforms, $surface_params) =
        _effect_bindings($state->{eff}, $state->{params}, $inputs, $blank);
    my %effective_inputs = (%$inputs, %$surface_params);
    $effective_inputs{inputTex3d} = $input_bundle->{volume} if defined $input_bundle->{volume};
    $effective_inputs{inputGeo}   = $input_bundle->{geometry} if defined $input_bundle->{geometry};
    _seed_typed_inputs($state, $input_bundle, \%effective_inputs, $width, $height);
    _initialize_overlay($state, \%effective_inputs, $width, $height);
    _ensure_iteration_scratch($state, \%effective_inputs, $width, $height) if $opt{iterated};
    my $uniforms = _canonical_uniforms(
        $width, $height, $time, $seed, $effect_uniforms,
        $opt{frame}, $opt{delta_time}, $width, $height,
    );
    $uniforms->{data} = _remap_uniform_data($uniforms, $width, $height)
        if $state->{effect_id} eq 'synth/remap';
    my $runtime = Math::Fractal::Noisemaker::Runtime->new;
    my $result;
    my $last_output;
    my $external_tex = $state->{eff}{externalTexture};

    for my $pass (@{ $state->{eff}{passes} || [] }) {
        next unless _pass_is_active($pass, $uniforms);
        my $repeat = _repeat_count($pass, $uniforms);
        next unless $repeat;
        for (1 .. $repeat) {
            my %textures;
            my %resources = (%effective_inputs, %{ $state->{attachments} }, %$group_resources);
            for my $sampler (sort keys %$surface_params) {
                my $surface = $surface_params->{$sampler};
                $surface->filter((defined $external_tex && $sampler eq $external_tex) ? 'linear' : 'nearest');
                $textures{$sampler} = $surface;
            }
            for my $sampler (sort keys %{ $pass->{inputs} || {} }) {
                my $source = $pass->{inputs}{$sampler};
                my $surface;
                if (is_particle_state_name($source)) {
                    $surface = _resolve_particle_input($source, $state, $states, $group_resources, $width, $height);
                }
                elsif (defined $source && $source eq 'global_accum') {
                    $surface = $group_resources->{$source};
                }
                elsif (defined $source && ($source eq 'selfTex' || $source eq 'feedback')) {
                    $surface = $state->{self_tex} || $blank;
                }
                else {
                    $surface = $state->{attachments}{$source}
                        || $effective_inputs{$source}
                        || $effective_inputs{$sampler};
                }
                die "$state->{effect_id} pass '$pass->{name}' requires texture \"$source\"\n"
                    unless defined $surface;
                $surface->filter((defined $external_tex && $sampler eq $external_tex) ? 'linear' : 'nearest');
                $textures{$sampler} = $surface;
            }

            my $compiled = $pass->{drawMode} ? undef : _kernel_for($pass->{key});
            my @output_variables =
                $compiled && ($pass->{drawBuffers} || 0) >= 2 && ref $compiled->{output_names} eq 'ARRAY'
                ? @{ $compiled->{output_names} }
                : (sort keys %{ $pass->{outputs} || {} });
            die "$state->{effect_id} pass '$pass->{name}' has no fragment output\n"
                unless @output_variables;
            my @output_names = map {
                defined $pass->{outputs}{$_}
                    ? $pass->{outputs}{$_}
                    : die "$state->{effect_id} pass '$pass->{name}' has no destination for output '$_'\n"
            } @output_variables;
            my @destinations = map {
                _output_destination($_, $state, $states, $width, $height, $pass, \%resources)
            } @output_names;
            my ($dest_width, $dest_height) = ($destinations[0]->width, $destinations[0]->height);
            for my $destination (@destinations) {
                die "$state->{effect_id} pass '$pass->{name}' MRT destinations must share dimensions\n"
                    if $destination->width != $dest_width || $destination->height != $dest_height;
            }
            my $pass_uniforms = _pass_uniforms($pass, $uniforms, $state->{params});
            $pass_uniforms->{resolution} = [0.0 + $dest_width, 0.0 + $dest_height];
            $pass_uniforms->{aspectRatio} = f32($dest_width / $dest_height);
            $pass_uniforms->{aspect} = $pass_uniforms->{aspectRatio};

            if ($pass->{drawMode}) {
                my $draw_op = Math::Fractal::Noisemaker::DrawOps::get_draw_op(
                    $state->{effect_id}, $pass->{program});
                die "Missing CPU scatter adapter '$state->{effect_id}:$pass->{program}'\n"
                    unless ref $draw_op eq 'CODE';
                my $previous = (is_particle_state_name($output_names[0]) || $output_names[0] eq 'global_accum')
                    ? $group_resources->{ $output_names[0] }
                    : $state->{attachments}{ $output_names[0] };
                @{ $destinations[0]->data } = @{ $previous->data }
                    if defined $previous && @{ $previous->data } == @{ $destinations[0]->data };
                $draw_op->({
                    pass        => $pass,
                    uniforms    => $pass_uniforms,
                    inputs      => \%textures,
                    destination => $destinations[0],
                    params      => $state->{params},
                });
            }
            else {
                my $kernel = $compiled->{kernel};
                my $adapter = Math::Fractal::Noisemaker::Adapters::get_adapter(
                    $state->{effect_id}, $pass->{program});
                $kernel = $adapter->($runtime, $compiled) if $adapter;
                my $ctx = Math::Fractal::Noisemaker::Ctx->new(
                    rt         => $runtime,
                    uniforms   => $pass_uniforms,
                    textures   => \%textures,
                    resolution => [0.0 + $dest_width, 0.0 + $dest_height],
                    time       => $time,
                    seed       => $seed,
                    blank      => $blank,
                );
                if (@destinations > 1) {
                    run_pass_mrt($kernel, $ctx, \@destinations);
                }
                else {
                    $destinations[0] = $compiled->{uses_derivatives}
                        ? run_pass_deriv($kernel, $ctx, $dest_width, $dest_height)
                        : run_pass($kernel, $ctx, $dest_width, $dest_height);
                }
            }
            for my $index (0 .. $#destinations) {
                quantize_texture($destinations[$index], _output_format($output_names[$index], $state, $states));
                _store_output($output_names[$index], $destinations[$index], $state, $group_resources);
            }
            $result = $destinations[-1];
            $last_output = $result;
        }
    }

    my %resources = (%{ $state->{attachments} }, %$group_resources);
    my $domain = $state->{eff}{domain} || 'image';
    my $is_volume_domain = $domain =~ /\Avolume-/ ? 1 : 0;
    my $image = defined $state->{eff}{outputTex}
        ? _bundle_output($state->{eff}{outputTex}, $input_bundle->{image}, \%resources)
        : ($resources{outputTex} || ($is_volume_domain ? $input_bundle->{image} : $last_output));
    my $volume = _bundle_output($state->{eff}{outputTex3d}, $input_bundle->{volume}, \%resources);
    my $geometry = _bundle_output($state->{eff}{outputGeo}, $input_bundle->{geometry}, \%resources);
    my $volume_size = $domain eq 'volume-generator'
        ? ($state->{params}{volumeSize} // (defined $volume ? $volume->width : undef))
        : ($input_bundle->{volumeSize} // $state->{params}{volumeSize}
            // (defined $volume ? $volume->width : undef));
    die "$state->{effect_id} did not produce outputTex3d\n"
        if $is_volume_domain && !defined $volume && $domain ne 'volume-renderer';
    if (defined $volume && ($domain eq 'volume-generator' || $domain eq 'volume-filter')) {
        my $expected_height = $volume_size * $volume_size;
        die "$state->{effect_id} volume atlas expected ${volume_size}x${expected_height}, received "
            . $volume->width . 'x' . $volume->height . "\n"
            if $volume->width != $volume_size || $volume->height != $expected_height;
    }
    $result = ($opt{input_was_bundle} || $is_volume_domain)
        ? {
            image => $image, volume => $volume, geometry => $geometry,
            volumeSize => $volume_size,
        }
        : $image;
    die "$state->{effect_id} did not produce outputTex\n"
        if !defined $image && $domain ne 'volume-generator' && $domain ne 'volume-filter';
    if ($state->{self_tex}) {
        unless (@{ $state->{self_tex}->data } == @{ $image->data }) {
            my $self_size = $state->{self_tex}->width . 'x' . $state->{self_tex}->height;
            my $output_size = $image->width . 'x' . $image->height;
            die "$state->{effect_id} selfTex ($self_size) must match the step's output ($output_size)\n";
        }
        @{ $state->{self_tex}->data } = @{ $image->data };
    }
    return $result;
}

sub _zero_iteration_output {
    my ($input, $width, $height, $state) = @_;
    if (_is_chain_bundle($input)) {
        return {
            image => defined $input->{image} ? $input->{image}->clone : undef,
            volume => defined $input->{volume} ? $input->{volume}->clone : undef,
            geometry => defined $input->{geometry} ? $input->{geometry}->clone : undef,
            volumeSize => $input->{volumeSize},
        };
    }
    return $input->clone if defined $input;
    if ($state && ($state->{eff}{domain} || '') eq 'volume-generator') {
        my $volume = _destination(
            $state->{eff}, $state->{eff}{outputTex3d}, $state->{params}, $width, $height,
        );
        $volume->clear;
        my $geometry;
        if (defined $state->{eff}{outputGeo} && $state->{eff}{outputGeo} ne 'inputGeo') {
            $geometry = _destination(
                $state->{eff}, $state->{eff}{outputGeo}, $state->{params}, $width, $height,
            );
            $geometry->clear;
        }
        return {
            image => undef, volume => $volume, geometry => $geometry,
            volumeSize => ($state->{params}{volumeSize} // $volume->width),
        };
    }
    return Math::Fractal::Noisemaker::Surface->new($width, $height);
}

sub render_effect {
    my ($effect_id, $params, $inputs, %opt) = @_;
    $params = {} unless defined $params;
    $inputs ||= {};
    my $width  = defined $opt{width}  ? $opt{width}  : 256;
    my $height = defined $opt{height} ? $opt{height} : 256;
    my $seed   = defined $opt{seed}   ? $opt{seed}   : 1;
    my $time   = defined $opt{time}   ? $opt{time}   : 0.0;
    my $step = { kind => 'effect', effect_id => $effect_id, params => $params, surfaces => {} };
    my $input_was_bundle = defined $inputs->{inputTex3d} || defined $inputs->{inputGeo};
    my $input_value = $input_was_bundle
        ? {
            image => $inputs->{inputTex}, volume => $inputs->{inputTex3d},
            geometry => $inputs->{inputGeo},
            volumeSize => (defined $inputs->{inputTex3d} ? $inputs->{inputTex3d}->width : undef),
        }
        : $inputs->{inputTex};
    my $input_bundle = _chain_bundle($input_value);
    my $state = _prepare_state($step, $width, $height, $seed, undef, $input_bundle);
    my @states = ($state);
    my %group_resources;
    if (!$state->{eff}{iterated}) {
        return _run_state_once(
            $state, $inputs, \@states, \%group_resources,
            width => $width, height => $height, seed => $seed, time => $time,
            frame => (defined $opt{frame} ? $opt{frame} : 0),
            delta_time => (defined $opt{delta_time} ? $opt{delta_time} : 0),
            iterated => 0, input_bundle => $input_bundle,
            input_was_bundle => $input_was_bundle,
        );
    }
    my $count = defined $state->{params}{iterationCount} ? $state->{params}{iterationCount} : 60;
    return _zero_iteration_output($input_value, $width, $height, $state) unless $count > 0;
    my $result;
    for my $index (0 .. $count - 1) {
        $result = _run_state_once(
            $state, $inputs, \@states, \%group_resources,
            width => $width, height => $height, seed => $seed,
            time => wrap01($time - ($count - 1 - $index) * iteration_delta_time()),
            frame => $index, delta_time => iteration_delta_time(), iterated => 1,
            input_bundle => $input_bundle, input_was_bundle => $input_was_bundle,
        );
    }
    return $result;
}

# ---- Polymorphic DSL rendering (port of renderer.py render_dsl tail) ----

# Turn a compiled surface binding into a Surface (or undef for unbound):
# '@current' is the chain's current image, ['surface', 'oN'] a named surface
# that must already have been written.
sub _resolve_surface_marker {
    my ($marker, $current, $surfaces) = @_;
    return $current if !ref $marker && $marker eq '@current';
    my $name = $marker->[1];
    my $surf = $surfaces->{$name};
    die "Surface $name has not been written\n" unless defined $surf;
    return $surf;
}

# Mirror the JS renderer's per-step binding: the chain's current image is the
# effect's inputTex; each surface param is bound by param name (the path
# render_effect resolves), and external textures (imageTex/textTex/named)
# pass straight through. Explicit surface args and inputTex-defaults win over
# them.
sub _inputs_for_step {
    my ($step, $current, $surfaces, $external_textures) = @_;
    my $bundle = _chain_bundle($current);
    my %inputs = %{ $external_textures || {} };
    $inputs{inputTex}   = $bundle->{image} if defined $bundle->{image};
    $inputs{inputTex3d} = $bundle->{volume} if defined $bundle->{volume};
    $inputs{inputGeo}   = $bundle->{geometry} if defined $bundle->{geometry};
    for my $pname (sort keys %{ $step->{surfaces} }) {
        my $surf = _resolve_surface_marker($step->{surfaces}{$pname}, $bundle->{image}, $surfaces);
        $inputs{$pname} = $surf if defined $surf;
    }
    return \%inputs;
}

sub _run_effect_step {
    my ($step, $current, $surfaces, $external_textures, $width, $height, $seed, $time) = @_;
    my $inputs = _inputs_for_step($step, $current, $surfaces, $external_textures);
    return render_effect(
        $step->{effect_id}, $step->{params}, $inputs,
        width => $width, height => $height, seed => $seed, time => $time,
    );
}

sub _run_iteration_group {
    my ($group, $group_input, $surfaces, $external_textures, $width, $height, $seed, $time) = @_;
    my $group_input_bundle = _chain_bundle($group_input);
    my @states;
    my $owner_state_size;
    for my $index (0 .. $#{ $group->{steps} }) {
        my $state = _prepare_state(
            $group->{steps}[$index], $width, $height, $seed,
            $index == 0 ? undef : $owner_state_size, $group_input_bundle,
        );
        push @states, $state;
        if ($index == 0 && @{ $group->{steps} } > 1
            && exists(($state->{eff}{params} || {})->{stateSize})) {
            $owner_state_size = $state->{params}{stateSize};
        }
    }
    my $count = defined $states[0]{params}{iterationCount}
        ? $states[0]{params}{iterationCount} : 60;
    return _zero_iteration_output($group_input, $width, $height, $states[0]) unless $count > 0;

    my %group_resources;
    if ($group->{loop}) {
        my $input_image = $group_input_bundle->{image}
            or die "Loop iteration group requires a current image\n";
        $group_resources{global_accum} = Math::Fractal::Noisemaker::Surface->new(
            $input_image->width, $input_image->height,
        );
        $group_resources{global_accum}->clear;
    }
    my $last;
    for my $iteration (0 .. $count - 1) {
        my $step_input = $group_input;
        for my $state (@states) {
            my $inputs = _inputs_for_step(
                $state->{step}, $step_input, $surfaces, $external_textures);
            my $step_input_bundle = _chain_bundle($step_input);
            $step_input = _run_state_once(
                $state, $inputs, \@states, \%group_resources,
                width => $width, height => $height, seed => $seed,
                time => wrap01($time - ($count - 1 - $iteration) * iteration_delta_time()),
                frame => $iteration, delta_time => iteration_delta_time(), iterated => 1,
                input_bundle => $step_input_bundle,
                input_was_bundle => _is_chain_bundle($step_input),
            );
        }
        $last = $step_input;
    }
    return $last;
}

# Render a Polymorphic DSL program on the CPU — the Perl counterpart of
# noisemaker-cpu's CpuRenderer.render(). Compiles the program to a plan, then
# threads each chain's `current` surface through read/write/effect steps over
# a named-surface map (o0..o7), running one render_effect per effect step.
sub render_dsl {
    my ($source, %opt) = @_;
    my $width  = defined $opt{width}  ? $opt{width}  : 512;
    my $height = defined $opt{height} ? $opt{height} : 512;
    my $seed   = defined $opt{seed}   ? $opt{seed}   : 1;
    my $time   = defined $opt{time}   ? $opt{time}   : 0.0;
    my $external_textures = $opt{external_textures};
    my %surfaces = %{ $opt{seed_surfaces} || {} };
    my $plan = compile_dsl($source, meta()->{effects});
    for my $chain (@{ $plan->{chains} }) {
        my $current;
        for my $group (@{ compute_iteration_groups($chain->{steps}, meta()->{effects}) }) {
            my $step = @{ $group->{steps} } == 1 ? $group->{steps}[0] : undef;
            if ($step && $step->{kind} eq 'read') {
                $current = $surfaces{ $step->{surface} };
                die "Surface $step->{surface} has not been written\n" unless defined $current;
            }
            elsif ($step && $step->{kind} eq 'write') {
                my $image = _chain_bundle($current)->{image};
                die "write($step->{surface}) requires a current image\n" unless defined $image;
                $surfaces{ $step->{surface} } = $image;
            }
            elsif ($group->{iterated}) {
                $current = _run_iteration_group(
                    $group, $current, \%surfaces, $external_textures,
                    $width, $height, $seed, $time,
                );
            }
            else {
                $current = _run_effect_step($step, $current, \%surfaces, $external_textures,
                    $width, $height, $seed, $time);
            }
        }
    }
    my $rendered = $surfaces{ $plan->{render_surface} };
    die "Surface $plan->{render_surface} has not been written\n" unless defined $rendered;
    return $rendered;
}

# Stateful renderer facade for output sinks and bounded frame export.
sub new {
    my ($class, %options) = @_;
    return bless {
        sink_manager => Math::Fractal::Noisemaker::SinkManager->new(
            on_error => $options{on_sink_error},
        ),
        sink_descriptor => {
            width => 0, height => 0, format => 'rgba8unorm',
            colorSpace => 'srgb', alphaMode => 'straight', fps => 60,
        },
        sinks_configured => 0,
    }, $class;
}

sub sink_manager { $_[0]{sink_manager} }

sub add_sink {
    my ($self, $sink) = @_;
    return $self->{sink_manager}->add($sink);
}

sub should_defer_render {
    my ($self) = @_;
    return $self->{sink_manager}->should_defer_render;
}
*shouldDeferRender = \&should_defer_render;

sub create_frame_export_queue {
    my ($self, %options) = @_;
    return Math::Fractal::Noisemaker::FrameExportQueue->new(
        Math::Fractal::Noisemaker::CpuFrameExportAdapter->new,
        %options,
    );
}

sub _configure_sinks {
    my ($self, $width, $height) = @_;
    my $descriptor = $self->{sink_descriptor};
    return if $self->{sinks_configured}
        && $descriptor->{width} == $width
        && $descriptor->{height} == $height;
    $descriptor->{width} = $width;
    $descriptor->{height} = $height;
    $self->{sinks_configured} = 1;
    $self->{sink_manager}->configure($descriptor);
}

sub _validated_render_options {
    my (%options) = @_;
    my $width  = defined $options{width}  ? $options{width}  : 512;
    my $height = defined $options{height} ? $options{height} : 512;
    my $seed   = defined $options{seed}   ? $options{seed}   : 1;
    my $time   = defined $options{time}   ? $options{time}   : 0;
    die "width must be a positive integer\n"
        unless $width =~ /^\d+$/ && $width > 0;
    die "height must be a positive integer\n"
        unless $height =~ /^\d+$/ && $height > 0;
    die "time must be finite\n"
        unless looks_like_number($time) && POSIX::isfinite(0 + $time);
    die "seed must be an integer\n"
        unless looks_like_number($seed) && POSIX::isfinite(0 + $seed) && $seed == int($seed);
    return ($width, $height, $seed, $time);
}

sub render {
    my ($self, $source, %options) = @_;
    my ($width, $height, $seed, $time) = _validated_render_options(%options);
    $self->_configure_sinks($width, $height);
    my %render_options = (width => $width, height => $height, seed => $seed, time => $time);
    $render_options{external_textures} = $options{external_textures}
        if exists $options{external_textures};
    $render_options{seed_surfaces} = $options{seed_surfaces}
        if exists $options{seed_surfaces};
    my $result = render_dsl($source, %render_options);
    my $timestamp = defined $options{presentation_timestamp}
        ? $options{presentation_timestamp}
        : clock_gettime(CLOCK_MONOTONIC()) * 1000;
    $self->{sink_manager}->submit($result, $timestamp);
    return $result;
}

sub dispose {
    my ($self) = @_;
    $self->{sink_manager}->close;
}

1;

__END__

=head1 NAME

Math::Fractal::Noisemaker::Renderer - render effects and shader compositions

=head1 SYNOPSIS

    use Math::Fractal::Noisemaker::Renderer qw(render_effect render_dsl meta);

    my $image = render_effect('synth/solid', {color => '#4080c0'}, undef,
        width => 32, height => 32);
    my $inverse = render_effect('filter/invert', {}, {inputTex => $image},
        width => 32, height => 32);
    my $composed = render_dsl(
        "search synth, filter\nsolid(color: #4080c0).invert().write(o0)\nrender(o0)",
        width => 32, height => 32,
    );

=head1 FUNCTIONS

Functions are exported only on request. Rendering is synchronous and returns
a L<Math::Fractal::Noisemaker::Surface> for image effects and complete DSL programs.
Failures throw exceptions. Underscore-prefixed functions are private.

=head2 render_effect($id, $parameters, $inputs, %options)

C<$id> is a catalog ID such as C<synth/noise> or C<filter/invert>.
C<$parameters> is a hash reference of effect parameters; C<undef> means defaults.
Unknown names and malformed values are errors. An individual C<undef> value
also requests its catalog default. Numbers must be finite; integers must be
integral. Numeric dropdown values and values outside UI slider ranges remain
allowed. Named dropdown choices must exist in the metadata; qualified names
such as C<noise.simplex> use their final component. Booleans accept 0, 1,
JSON booleans, or the strings true/false, yes/no, and on/off. Colors accept
C<#RGB>, C<#RRGGBB>, C<#RRGGBBAA>, or arrays of three or four finite components.
Vectors and matrices accept arrays or comma-separated component strings.

C<$inputs> is a hash reference of borrowed C<Surface> objects, or C<undef>.
C<inputTex> is the primary filter input. Mixer surface parameters are bound
here by parameter name, uniform name, or texture name. External media uses the
effect's C<externalTexture> metadata key. Do not place surfaces in C<$parameters>.
Missing texture bindings sample a blank surface. Do not mutate an input during
rendering; returned surfaces may alias inputs in zero-iteration/pass-through cases.

Options are C<width> and C<height> (positive integers, default 256 each),
C<seed> (default 1), C<time> (default 0), and, for non-iterated effects,
C<frame> and C<delta_time> (default 0). The render seed fills an effect's
C<seed> parameter unless explicitly supplied there. Iterated effects use their
C<iterationCount> and internal time stepping.

Low-level typed effects can return a hash containing C<image>, C<volume>,
C<geometry>, and C<volumeSize>. Prefer C<render_dsl> for typed chains ending
in an image renderer; do not pass a typed bundle to C<encode_png>.
Bind typed input surfaces with C<inputTex3d> and C<inputGeo> in C<$inputs>.
Volume/geometry parameter defaults such as C<vol0> and C<geo0> are catalog
markers for the chain input; they do not select named resources. Only those
default markers or C<undef> are accepted in the parameter hash.

=head2 render_dsl($source, %options)

Compiles and renders a Polymorphic DSL string. Options are C<width>, C<height>
(default 512 each), C<seed> (1), C<time> (0), C<external_textures> (a hash of
named texture surfaces), and C<seed_surfaces> (a hash such as C<< {o0 => $image} >>).
The program selects its output using C<render(oN)>; absent that directive,
the compiler selects the last written surface. Surfaces must be written before reading them,
unless supplied in C<seed_surfaces>. DSL errors include source locations where
available. See L<Math::Fractal::Noisemaker::DSL>.

=head2 meta()

Returns the cached bundle metadata hash. Treat it as read-only. Discover effects
and their parameter names, types, defaults, named choices, and UI ranges with:

    my $effects = meta()->{effects};
    print "$_\n" for sort keys %$effects;
    my $effect = $effects->{'synth/noise'};
    for my $name (@{ $effect->{paramOrder} }) {
        my $spec = $effect->{params}{$name};
        print "$name ($spec->{type})\n";
    }

=head2 bundle_dir()

Returns the installed bundle path, or C<NOISEMAKER_BUNDLE> when set. Set this
environment variable before loading metadata or rendering; caches are process
wide and do not support switching bundles mid-process. Kernels are executable
Perl, so a custom bundle must be trusted.

=head1 OBJECT INTERFACE

=head2 new(on_sink_error => sub { ... })

Creates a renderer with an independent sink manager. The optional callback
receives C<($error, $sink)>. Construction does not render anything.

=head2 render($source, %options)

Renders DSL with the same options as C<render_dsl>, then submits the image to
registered sinks. C<presentation_timestamp> optionally supplies the timestamp
in milliseconds; otherwise a monotonic clock supplies it. Sinks receive an
RGBA8/sRGB/straight-alpha descriptor with nominal fps 60. No playback pacing,
cross-frame simulation state, or background worker is created.

=head2 add_sink($sink)

Registers an object implementing C<configure>, C<submit>, and C<close>.
Returns an idempotent unsubscribe coderef which closes the sink. See
L<Math::Fractal::Noisemaker::SinkManager> for the callback contract.

=head2 should_defer_render(), shouldDeferRender()

Delegates directly to C<sink_manager->should_defer_render>. Returns true (1)
if any active registered output sink requests that rendering be deferred.

=head2 sink_manager()

Returns this renderer's sink manager.

=head2 create_frame_export_queue(%options)

Returns a L<Math::Fractal::Noisemaker::FrameExportQueue> with the CPU adapter.
Options are C<slots> (2 through 8; default 3) and C<on_error> (a coderef).
The caller owns this queue and must configure, poll, and close it separately.

=head2 dispose()

Closes all sinks. Repeated calls are harmless. Close errors are rethrown after
all sinks have been visited. The sink manager cannot be reused after disposal.

=cut
