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

use Math::Fractal::Noisemaker::DSL qw(compile_dsl);
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

sub _coerce {
    my ($spec, $value) = @_;
    my $t = $spec->{type} || '';
    $value = $spec->{default} unless defined $value;
    if ($t eq 'color') {
        $value = _parse_hex($value) if defined $value && !ref $value;
        return [map { f32($_) } @{ $value || [0, 0, 0] }];
    }
    if ($t eq 'vec2' || $t eq 'vec3' || $t eq 'vec4') {
        if (defined $value && !ref $value) {    # CLI --param: "0.1,0.2,0.3"
            $value = [map { 0 + $_ } split /,/, $value];
        }
        return [map { f32($_) } @{ $value || [] }];
    }
    if ($t eq 'float') {
        return f32(defined $value ? $value : 0);
    }
    if ($t eq 'int' || $t eq 'enum' || $t eq 'member') {
        if (defined $value && $value =~ /[^\d\s.+-]/) {    # enum name lookup
            my $choices = $spec->{choices} || {};
            my ($key) = $value =~ /([^.]+)$/;              # "oscType.sine" -> "sine"
            return int($choices->{$value}) if exists $choices->{$value};
            return int($choices->{$key})   if defined $key && exists $choices->{$key};
            return 0;    # CDN member with no inline choices: 0th member
        }
        return int(defined $value ? $value : 0);
    }
    if ($t eq 'bool' || $t eq 'boolean') {
        if (defined $value && $value =~ /^\s*(?:true|yes|on)\s*$/i) { return 1 }
        if (defined $value && $value =~ /^\s*(?:false|no|off)\s*$/i) { return 0 }
        return (defined $value && $value) ? 1 : 0;
    }
    return $value;
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
    my %raw = %{ $step->{params} || {} };
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
    $params ||= {};
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

1;
