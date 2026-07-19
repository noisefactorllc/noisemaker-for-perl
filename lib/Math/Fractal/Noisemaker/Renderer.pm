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
use Math::Fractal::Noisemaker::PassRunner qw(run_pass run_pass_deriv);
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
    $data[0] = [$bg->[0], $bg->[1], $bg->[2], $g->('bgAlpha', 1)];
    $data[1] = [$g->('zoneCount', 0), $g->('smoothEdge', 0.04), 0, $g->('time', 0)];
    for my $zone (0 .. 7) {
        $data[ 2 + $zone ] = [
            $g->("zone${zone}_count", 0), $g->("zone${zone}_active", 0),
            0, $g->("zone${zone}_alpha", 1),
        ];
        for my $pair (0 .. 31) {
            my $v = $g->("zone${zone}_v${pair}", [0, 0, 0, 0]);
            $data[ 10 + $zone * 32 + $pair ] = [@$v];
        }
    }
    $data[266] = [0.0 + $width, 0.0 + $height, 0, 0];
    return \@data;
}

# Match the reference engine's createCanonicalBindings.
sub _canonical_uniforms {
    my ($width, $height, $time, $seed, $effect_uniforms) = @_;
    my $res    = [0.0 + $width, 0.0 + $height];
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
        fullResolution => $res,
        tileOffset     => [0.0, 0.0],
        aspectRatio    => $aspect,
        aspect         => $aspect,
        time           => f32($time),
        globalTime     => f32($time),
        deltaTime      => 0,
    );
    return \%u;
}

sub render_effect {
    my ($effect_id, $params, $inputs, %opt) = @_;
    $params = {} unless defined $params;
    $inputs = {} unless defined $inputs;
    my $width  = defined $opt{width}  ? $opt{width}  : 256;
    my $height = defined $opt{height} ? $opt{height} : 256;
    my $seed   = defined $opt{seed}   ? $opt{seed}   : 1;
    my $time   = defined $opt{time}   ? $opt{time}   : 0.0;
    my $eff    = meta()->{effects}{$effect_id}
        or die "unknown effect '$effect_id' (not in bundle)\n";

    my %effect_uniforms;
    my %surface_params;    # sampler-name -> provided Surface (or undef)
    for my $pname (sort keys %{ $eff->{params} }) {
        my $spec = $eff->{params}{$pname};
        next unless ref $spec eq 'HASH';
        if (($spec->{type} || '') eq 'surface') {
            my $sampler = $spec->{uniform} || $spec->{texture} || $pname;
            my $surf = defined $inputs->{$sampler} ? $inputs->{$sampler} : $inputs->{$pname};
            $surface_params{$sampler} = $surf;
            # colorModeUniform (e.g. mashup's layerN_active): 1 when the
            # surface is wired, 0 when unbound.
            if ($spec->{colorModeUniform}) {
                $effect_uniforms{ $spec->{colorModeUniform} } = defined $surf ? 1 : 0;
            }
            next;
        }
        my $val;
        if ($pname eq 'seed' && !exists $params->{seed}) {
            # An effect's own `seed` param shares the GLSL uniform name with
            # the canonical render seed: thread the render seed into it so
            # `seed=` actually changes the generator's look (the big parity
            # unlock in the Python port).
            $val = _coerce($spec, $seed);
        }
        else {
            $val = _coerce($spec, $params->{$pname});
        }
        $effect_uniforms{ $spec->{uniform} } = $val if defined $spec->{uniform};
        $effect_uniforms{ $spec->{define} }  = $val if defined $spec->{define};
    }

    # classicNoisedeck palette presets: a palette-type param > 0 selects
    # cosine-palette coefficients from the shared table.
    if (($eff->{namespace} || '') eq 'classicNoisedeck') {
        my ($pal) = grep {
            ref $eff->{params}{$_} eq 'HASH' && ($eff->{params}{$_}{type} || '') eq 'palette'
        } sort keys %{ $eff->{params} };
        if (defined $pal) {
            my $idx = _coerce($eff->{params}{$pal}, $params->{$pal});
            my $table = \@Math::Fractal::Noisemaker::PaletteData::PALETTE_DATA;
            if ($idx =~ /^\d+$/ && $idx > 0 && $idx <= @$table) {
                my $e = $table->[ $idx - 1 ];
                $effect_uniforms{paletteAmp}    = [@{$e}[0 .. 2]];
                $effect_uniforms{paletteFreq}   = [@{$e}[4 .. 6]];
                $effect_uniforms{paletteOffset} = [@{$e}[8 .. 10]];
                $effect_uniforms{palettePhase}  = [@{$e}[12 .. 14]];
                $effect_uniforms{paletteMode}   = $e->[3] == 0 ? 3 : int($e->[3]);
            }
        }
    }

    my $uniforms = _canonical_uniforms($width, $height, $time, $seed, \%effect_uniforms);
    $uniforms->{data} = _remap_uniform_data($uniforms, $width, $height)
        if $effect_id eq 'synth/remap';
    my $blank = Math::Fractal::Noisemaker::Surface->new(1, 1);

    my $rt = Math::Fractal::Noisemaker::Runtime->new;
    my $result;
    my %attachments;    # attach-name -> Surface produced by an earlier pass

    # One-shot CPU-generated textures declared but not produced by any pass
    # (fibers/scratches/strayHair overlayTex): generate and bind up front.
    if (Math::Fractal::Noisemaker::OverlayGen::is_overlay_effect($effect_id)) {
        my %produced;
        for my $pp (@{ $eff->{passes} }) {
            $produced{$_} = 1 for values %{ $pp->{outputs} || {} };
        }
        for my $tname (sort keys %{ $eff->{textures} || {} }) {
            next unless $tname eq 'overlayTex' && !$produced{$tname} && !exists $surface_params{$tname};
            my %gen;
            for my $pn ('seed', 'density') {
                next unless exists $eff->{params}{$pn};
                my $gp = $eff->{params}{$pn};
                $gen{$pn} =
                    ($pn eq 'seed' && !exists $params->{seed})
                    ? _coerce($gp, $seed)
                    : _coerce($gp, $params->{$pn});
            }
            $attachments{$tname} =
                Math::Fractal::Noisemaker::OverlayGen::render_worm_overlay($effect_id, $width, $height, \%gen);
        }
    }

    # Texture filtering must match the oracle: only the declared external
    # texture is 'linear'; every pooled surface stays 'nearest' (decisive for
    # warp effects sampling at fractional coordinates).
    my $external_tex = $eff->{externalTexture};

    for my $p (@{ $eff->{passes} }) {
        my %textures;
        for my $sampler (sort keys %surface_params) {
            my $surf = $surface_params{$sampler};
            next unless defined $surf;
            $surf->filter((defined $external_tex && $sampler eq $external_tex) ? 'linear' : 'nearest');
            $textures{$sampler} = $surf;
        }
        for my $sampler_name (sort keys %{ $p->{inputs} || {} }) {
            my $source = $p->{inputs}{$sampler_name};
            # An earlier pass's named attachment wins over a same-named
            # external input.
            my $surf =
                   $attachments{$source}
                || $inputs->{$source}
                || $inputs->{$sampler_name}
                || $result;
            next unless defined $surf;
            $surf->filter((defined $external_tex && $sampler_name eq $external_tex) ? 'linear' : 'nearest');
            $textures{$sampler_name} = $surf;
        }
        # Pass-level uniform aliases: the definition may expose a param under
        # one name while this pass's GLSL declares another.
        my %pass_uniforms = %$uniforms;
        for my $glsl_name (sort keys %{ $p->{uniforms} || {} }) {
            my $param_name = $p->{uniforms}{$glsl_name};
            if (exists $effect_uniforms{$param_name}) {
                $pass_uniforms{$glsl_name} = $effect_uniforms{$param_name};
            }
            elsif (exists $uniforms->{$param_name}) {
                $pass_uniforms{$glsl_name} = $uniforms->{$param_name};
            }
        }
        my @out_names = values %{ $p->{outputs} || {} };
        my $fmt = 'rgba16f';
        if (@out_names && $eff->{textures} && $eff->{textures}{ $out_names[0] }) {
            $fmt = $eff->{textures}{ $out_names[0] }{format} || 'rgba16f';
        }
        my $draw_op =
            $p->{drawMode}
            ? Math::Fractal::Noisemaker::DrawOps::get_draw_op($effect_id, $p->{program})
            : undef;
        if ($draw_op) {
            # CPU-only draw op (e.g. point-scatter): fresh destination seeds
            # from the prior same-name attachment (accumulator) or clears.
            my ($src_name) = values %{ $p->{inputs} || {} };
            $src_name = 'inputTex' unless defined $src_name;
            my $src = $textures{$src_name} || $textures{inputTex} || $blank;
            $result = Math::Fractal::Noisemaker::Surface->new($width, $height);
            my $prev = @out_names ? $attachments{ $out_names[0] } : undef;
            if (defined $prev && @{ $prev->data } == @{ $result->data }) {
                @{ $result->data } = @{ $prev->data };
            }
            $draw_op->($src, $result, \%pass_uniforms);
        }
        else {
            my $ctx = Math::Fractal::Noisemaker::Ctx->new(
                rt         => $rt,
                uniforms   => \%pass_uniforms,
                textures   => \%textures,
                resolution => [0.0 + $width, 0.0 + $height],
                time       => $time,
                seed       => $seed,
                blank      => $blank,
            );
            my $compiled = _kernel_for($p->{key});
            my $kernel   = $compiled->{kernel};
            my $adapter  = Math::Fractal::Noisemaker::Adapters::get_adapter($effect_id, $p->{program});
            $kernel = $adapter->($rt, $compiled) if $adapter;
            $result =
                $compiled->{uses_derivatives}
                ? run_pass_deriv($kernel, $ctx, $width, $height)
                : run_pass($kernel, $ctx, $width, $height);
        }
        # Quantize the pass output to its declared texture format.
        quantize_texture($result, $fmt);
        $attachments{$_} = $result for @out_names;
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
sub _run_effect_step {
    my ($step, $current, $surfaces, $external_textures, $width, $height, $seed, $time) = @_;
    my %inputs = %{ $external_textures || {} };
    $inputs{inputTex} = $current if defined $current;
    for my $pname (sort keys %{ $step->{surfaces} }) {
        my $surf = _resolve_surface_marker($step->{surfaces}{$pname}, $current, $surfaces);
        $inputs{$pname} = $surf if defined $surf;
    }
    return render_effect(
        $step->{effect_id}, $step->{params}, \%inputs,
        width => $width, height => $height, seed => $seed, time => $time,
    );
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
        for my $step (@{ $chain->{steps} }) {
            my $kind = $step->{kind};
            if ($kind eq 'read') {
                $current = $surfaces{ $step->{surface} };
                die "Surface $step->{surface} has not been written\n" unless defined $current;
            }
            elsif ($kind eq 'write') {
                $surfaces{ $step->{surface} } = $current;
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
