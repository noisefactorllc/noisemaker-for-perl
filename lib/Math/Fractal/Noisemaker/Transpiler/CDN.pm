package Math::Fractal::Noisemaker::Transpiler::CDN;

# Fetch shader source + effect metadata from the shaders.noisedeck.app CDN.
#
# The CDN serves a per-effect ESM bundle at /<version>/effects/<id>.js that
# inlines both the effect definition (globals == params, passes, textures)
# and the raw GLSL (shaders[program].glsl). Pure Perl, no JS execution: we
# extract the pieces from the bundle TEXT (template-literal scan for GLSL,
# balanced-delimiter walk + JSON5-shaped literal reading for the definition).
#
# Fetches are cached to disk as EXTRACTED JSON (never raw .js) under
# .cdn-cache/<version>/, so repeat runs are offline after the first hit —
# and the cache can be seeded from the (byte-identical) Python port's cache.
#
# HTTPS: HTTP::Tiny is used when SSL support is present; otherwise falls
# back to the system `curl` (developer-time fetch only — rendering needs no
# network).

use strict;
use warnings;
use File::Basename ();
use File::Path     ();
use File::Spec     ();
use JSON::PP       ();
use Exporter 'import';

use Math::Fractal::Noisemaker::Transpiler::ComputedDefs qw(%COMPUTED_DEFS);

our @EXPORT_OK = qw(fetch_effect fetch_manifest eligible_ids cache_root CDN_BASE CDN_VERSION);

our $CDN_BASE = ($ENV{NM_SHADER_CDN} || 'https://shaders.noisedeck.app');
$CDN_BASE =~ s{/+$}{};
# The "1.0" minor channel is the current release (rolling tag).
our $CDN_VERSION = $ENV{NM_SHADER_VERSION} || '1.0';

my $_JSON = JSON::PP->new->utf8->canonical;

# Effects the transpiler does not target (3D, points, mesh/cubemap, stateful
# and reactive effects) — mirrors the Python port's exclusion sets.
my %NAMESPACE_EXCLUSIONS = map { $_ => 1 } qw(filter3d synth3d points render);
my %ID_EXCLUSIONS        = map { $_ => 1 } qw(
    filter/convolutionFeedback filter/feedback filter/motionBlur
    filter/temporalAberration synth/cellularAutomata synth/mnca
    synth/navierStokes synth/reactionDiffusion synth/roll synth/scope
    synth/spectrum classicNoisedeck/noise3d classicNoisedeck/shapes3d
);

sub cache_root {
    # <dist>/.cdn-cache, next to lib/ (five levels up from
    # lib/Math/Fractal/Noisemaker/Transpiler/CDN.pm).
    my $here = File::Basename::dirname(__FILE__);
    return File::Spec->catdir($here, ('..') x 5, '.cdn-cache');
}

sub _cache_dir {
    my ($version) = @_;
    (my $safe = $version) =~ s/[^\w.-]/_/g;
    return File::Spec->catdir(cache_root(), $safe);
}

sub _fetch_text {
    my ($url) = @_;
    my $ok = eval {
        require HTTP::Tiny;
        HTTP::Tiny->can_ssl;
    };
    if ($ok) {
        my $res = HTTP::Tiny->new(
            agent   => 'noisemaker-for-perl transpiler (+https://noisedeck.app)',
            timeout => 30,
        )->get($url);
        die "CDN $res->{status} $res->{reason} for $url\n" unless $res->{success};
        return $res->{content};
    }
    # curl fallback (developer-time only)
    my $text = do {
        local $/;
        open my $fh, '-|', 'curl', '-fsSL', '--max-time', '30', $url
            or die "CDN request failed for $url: cannot run curl\n";
        <$fh>;
    };
    die "CDN request failed for $url\n" unless defined $text && length $text;
    return $text;
}

sub _read_file {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read $path: $!\n";
    local $/;
    return scalar <$fh>;
}

sub _write_file {
    my ($path, $text) = @_;
    File::Path::make_path(File::Basename::dirname($path));
    open my $fh, '>:raw', $path or die "cannot write $path: $!\n";
    print {$fh} $text;
}

sub fetch_manifest {
    my ($version) = @_;
    $version = $CDN_VERSION unless defined $version;
    my $cache = File::Spec->catfile(_cache_dir($version), 'effects', 'manifest.json');
    return $_JSON->decode(_read_file($cache)) if -e $cache;
    my $text = _fetch_text("$CDN_BASE/$version/effects/manifest.json");
    _write_file($cache, $text);
    return $_JSON->decode($text);
}

# ---- bundle text extraction ----

# text[i] is a quote char (', ", or `); return index just past the close.
sub _skip_string {
    my ($text, $i) = @_;
    my $quote = substr($$text, $i, 1);
    my $n     = length $$text;
    $i++;
    while ($i < $n) {
        my $c = substr($$text, $i, 1);
        if ($c eq '\\') { $i += 2; next }
        return $i + 1 if $c eq $quote;
        $i++;
    }
    return $i;    # unterminated — treat end-of-text as the boundary
}

# Balanced {...}/[...] substring starting at $start; strings skipped whole.
sub _extract_balanced {
    my ($text, $start) = @_;
    my $c0 = substr($$text, $start, 1);
    die "expected '{' or '[' at offset $start\n" unless $c0 eq '{' || $c0 eq '[';
    my $depth = 0;
    my $i     = $start;
    my $n     = length $$text;
    while ($i < $n) {
        my $c = substr($$text, $i, 1);
        if ($c eq '"' || $c eq "'" || $c eq '`') {
            $i = _skip_string($text, $i);
            next;
        }
        if    ($c eq '{' || $c eq '[') { $depth++ }
        elsif ($c eq '}' || $c eq ']') {
            $depth--;
            return substr($$text, $start, $i + 1 - $start) if $depth == 0;
        }
        $i++;
    }
    die "unbalanced brackets: reached end of text\n";
}

# Rewrite minifier boolean shorthand (!0 / !1 -> true / false) outside strings.
sub _normalize_js_literals {
    my ($text) = @_;
    my @out;
    my $i = 0;
    my $n = length $text;
    while ($i < $n) {
        my $c = substr($text, $i, 1);
        if ($c eq '"' || $c eq "'" || $c eq '`') {
            my $start = $i;
            $i = _skip_string(\$text, $i);
            push @out, substr($text, $start, $i - $start);
            next;
        }
        my $two = substr($text, $i, 2);
        if ($two eq '!0' || $two eq '!1') {
            my $prev = $i > 0 ? substr($text, $i - 1, 1) : '';
            my $next = $i + 2 < $n ? substr($text, $i + 2, 1) : '';
            if ($prev !~ /[\w\$]/ && $next !~ /[\w\$]/) {
                push @out, ($two eq '!0' ? 'true' : 'false');
                $i += 2;
                next;
            }
        }
        push @out, $c;
        $i++;
    }
    return join '', @out;
}

# Replace value-position bare identifiers with 0 (UI-metadata fields may
# reference minified module-scope constants). Keys and true/false/null kept.
sub _sanitize_bare_identifiers {
    my ($text) = @_;
    my @out;
    my $i = 0;
    my $n = length $text;
    while ($i < $n) {
        my $c = substr($text, $i, 1);
        if ($c eq '"' || $c eq "'" || $c eq '`') {
            my $start = $i;
            $i = _skip_string(\$text, $i);
            push @out, substr($text, $start, $i - $start);
            next;
        }
        if ($c =~ /[A-Za-z_\$]/) {
            my $j = $i;
            $j++ while $j < $n && substr($text, $j, 1) =~ /[A-Za-z0-9_\$]/;
            my $ident = substr($text, $i, $j - $i);
            my $k     = $j;
            $k++ while $k < $n && substr($text, $k, 1) =~ /[ \t\n\r]/;
            my $is_key = $k < $n && substr($text, $k, 1) eq ':';
            push @out,
                ($is_key || $ident eq 'true' || $ident eq 'false' || $ident eq 'null') ? $ident : '0';
            $i = $j;
            next;
        }
        push @out, $c;
        $i++;
    }
    return join '', @out;
}

# Locate key's value: object-literal `key: value` or class-field `"key", value`.
sub _find_value_start {
    my ($text, $key) = @_;
    my $k = quotemeta $key;
    if ($$text =~ /(?:\b$k\b\s*:|["']$k["']\s*,)\s*/) {
        return $+[0];
    }
    return undef;
}

# Convert a JSON5-shaped literal (unquoted keys, single quotes, trailing
# commas) to strict JSON, then decode.
sub _json5_decode {
    my ($text) = @_;
    my @out;
    my $i = 0;
    my $n = length $text;
    while ($i < $n) {
        my $c = substr($text, $i, 1);
        if ($c eq "'" || $c eq '`') {    # single/backtick string -> double-quoted
            my $end = _skip_string(\$text, $i);
            my $body = substr($text, $i + 1, $end - $i - 2);
            $body =~ s/\\(['`])/$1/g;    # unescape original quotes
            $body =~ s/(["\\])/\\$1/g;   # escape for JSON
            $body =~ s/\n/\\n/g;
            $body =~ s/\t/\\t/g;
            $body =~ s/\r/\\r/g;
            push @out, '"' . $body . '"';
            $i = $end;
            next;
        }
        if ($c eq '"') {
            my $end = _skip_string(\$text, $i);
            push @out, substr($text, $i, $end - $i);
            $i = $end;
            next;
        }
        if ($c =~ /[A-Za-z_\$]/) {       # bare identifier: quote keys, keep literals
            my $j = $i;
            $j++ while $j < $n && substr($text, $j, 1) =~ /[A-Za-z0-9_\$]/;
            my $ident = substr($text, $i, $j - $i);
            my $k     = $j;
            $k++ while $k < $n && substr($text, $k, 1) =~ /[ \t\n\r]/;
            my $is_key = $k < $n && substr($text, $k, 1) eq ':';
            if ($is_key) { push @out, '"' . $ident . '"' }
            elsif ($ident eq 'true' || $ident eq 'false' || $ident eq 'null') { push @out, $ident }
            elsif ($ident eq 'undefined') { push @out, 'null' }
            elsif ($ident eq 'Infinity')  { push @out, '1e308' }
            elsif ($ident eq 'NaN')       { push @out, '0' }
            else                          { push @out, '0' }    # sanitized elsewhere; belt+braces
            $i = $j;
            next;
        }
        # JSON5 relaxations handled IN the walk, so string contents (already
        # emitted whole above) can never be corrupted by them:
        if ($c eq ',') {    # trailing comma before } or ] — drop it
            my $k = $i + 1;
            $k++ while $k < $n && substr($text, $k, 1) =~ /[ \t\n\r]/;
            if ($k < $n && (substr($text, $k, 1) eq '}' || substr($text, $k, 1) eq ']')) {
                $i++;
                next;
            }
        }
        if ($c eq '+' && $i + 1 < $n && substr($text, $i + 1, 1) =~ /\d/) {
            $i++;           # explicit plus sign on a number — drop it
            next;
        }
        push @out, $c;
        $i++;
    }
    return $_JSON->decode(join '', @out);
}

# Read the single JS value (string/object/array literal) at $start.
sub _read_literal {
    my ($text, $start, $sanitize) = @_;
    return undef if !defined $start || $start >= length $$text;
    my $c = substr($$text, $start, 1);
    if ($c eq '{' || $c eq '[') {
        my $raw = _normalize_js_literals(_extract_balanced($text, $start));
        $raw = _sanitize_bare_identifiers($raw) if $sanitize;
        return _json5_decode($raw);
    }
    if ($c eq '"' || $c eq "'") {
        my $end = _skip_string($text, $start);
        return _json5_decode(substr($$text, $start, $end - $start));
    }
    return undef;
}

# Slice the bundle down to the definition region (before the shaders object).
sub _definition_region {
    my ($bundle) = @_;
    if ($$bundle =~ /(\w+)\s*:\s*\{\s*glsl\s*:\s*`/) {
        return substr($$bundle, 0, $-[0]);
    }
    return $$bundle;
}

# Extract every program's GLSL template literal.
sub _extract_programs {
    my ($bundle) = @_;
    my %programs;
    pos($$bundle) = 0;
    while ($$bundle =~ /(\w+)\s*:\s*\{\s*glsl\s*:\s*`/g) {
        my $program        = $1;
        my $backtick_start = $+[0] - 1;
        my $end            = _skip_string($bundle, $backtick_start);
        $programs{$program} = substr($$bundle, $backtick_start + 1, $end - 1 - ($backtick_start + 1));
        pos($$bundle) = $end;
    }
    return \%programs;
}

sub _parse_field {
    my ($region, $effect_id, $key, $default) = @_;
    my $start = _find_value_start($region, $key);
    return $default unless defined $start;
    my $value = eval { _read_literal($region, $start, $key eq 'globals') };
    die "CDN effect '$effect_id': could not parse '$key' as a JSON5 literal "
        . "(likely a JS-computed definition — see ComputedDefs): $@" if $@;
    return defined $value ? $value : $default;
}

# Top-level key order of a JSON object's text — JSON::PP hashes lose insertion
# order, but the ORACLE binds mixer surface params by definition order, so the
# bundle must record it. Walks the raw text, skipping strings/nested values.
sub ordered_object_keys {
    my ($text) = @_;
    my @keys;
    my $i = index($text, '{');
    return \@keys if $i < 0;
    my $n     = length $text;
    my $depth = 0;
    while ($i < $n) {
        my $c = substr($text, $i, 1);
        if ($c eq '"' || $c eq "'") {
            my $end = _skip_string(\$text, $i);
            if ($depth == 1) {
                my $body = substr($text, $i + 1, $end - $i - 2);
                my $k    = $end;
                $k++ while $k < $n && substr($text, $k, 1) =~ /\s/;
                push @keys, $body if $k < $n && substr($text, $k, 1) eq ':';
            }
            $i = $end;
            next;
        }
        if    ($c eq '{' || $c eq '[') { $depth++ }
        elsif ($c eq '}' || $c eq ']') { $depth--; return \@keys if $depth == 0 }
        $i++;
    }
    return \@keys;
}

# Key order of the "params" object inside a cached-effect JSON document.
sub params_key_order {
    my ($doc_text) = @_;
    if ($doc_text =~ /"params"\s*:\s*/) {
        my $start = $+[0];
        return ordered_object_keys(_extract_balanced(\$doc_text, $start));
    }
    return [];
}

sub fetch_effect {
    my ($effect_id, $version) = @_;
    $version = $CDN_VERSION unless defined $version;
    # Cache the EXTRACTED data as JSON (no raw CDN .js ever hits disk).
    my $cache = File::Spec->catfile(_cache_dir($version), 'effects', "$effect_id.json");
    if (-e $cache) {
        my $text   = _read_file($cache);
        my $result = $_JSON->decode($text);
        $result->{paramOrder} = params_key_order($text)
            unless $result->{paramOrder} && @{ $result->{paramOrder} };
        return $result;
    }

    my $bundle = _fetch_text("$CDN_BASE/$version/effects/$effect_id.js");
    my $region = _definition_region(\$bundle);
    my $result;
    if (my $override = $COMPUTED_DEFS{$effect_id}) {
        $result = {
            id              => $effect_id,
            namespace       => $override->{namespace},
            func            => $override->{func},
            params          => $override->{params},
            paramOrder      => $override->{paramOrder},
            passes          => $override->{passes},
            textures        => ($override->{textures} || {}),
            externalTexture => $override->{externalTexture},
            programs        => _extract_programs(\$bundle),
        };
    }
    else {
        my $param_order = [];
        if (my $gstart = _find_value_start(\$region, 'globals')) {
            if (substr($region, $gstart, 1) eq '{') {
                $param_order = ordered_object_keys(_extract_balanced(\$region, $gstart));
            }
        }
        $result = {
            id              => $effect_id,
            namespace       => _parse_field(\$region, $effect_id, 'namespace', undef),
            func            => _parse_field(\$region, $effect_id, 'func', undef),
            params          => _parse_field(\$region, $effect_id, 'globals', {}),
            paramOrder      => $param_order,
            passes          => _parse_field(\$region, $effect_id, 'passes', []),
            textures        => _parse_field(\$region, $effect_id, 'textures', {}),
            externalTexture => _parse_field(\$region, $effect_id, 'externalTexture', undef),
            programs        => _extract_programs(\$bundle),
        };
    }
    # The cache is written with canonical (sorted) JSON, so paramOrder is
    # stored explicitly — the raw-text key scan on re-read would see sorted
    # keys, not definition order.
    _write_file($cache, $_JSON->encode($result));
    return $result;
}

sub eligible_ids {
    my ($version) = @_;
    my $manifest = fetch_manifest($version);
    my @result;
    for my $effect_id (sort keys %$manifest) {
        my ($namespace) = split m{/}, $effect_id, 2;
        next if $NAMESPACE_EXCLUSIONS{$namespace};
        next if index($effect_id, '3d') >= 0 || index($effect_id, 'cubemap') >= 0 || index($effect_id, 'mesh') >= 0;
        next if $ID_EXCLUSIONS{$effect_id};
        push @result, $effect_id;
    }
    return \@result;
}

1;
