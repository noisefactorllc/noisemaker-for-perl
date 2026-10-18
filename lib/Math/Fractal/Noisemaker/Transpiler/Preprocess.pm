package Math::Fractal::Noisemaker::Transpiler::Preprocess;

# GLSL preprocessing + light normalization (pure Perl).
#
# Reproduces the parts of the reference pipeline that matter for codegen:
#   - strip #version / #extension / #pragma / #line
#   - object-like #define expansion
#   - #ifdef/#ifndef/#if/#elif/#else/#endif: static conditions are evaluated;
#     conditions on a RUNTIME define are lowered into real GLSL if/else fed by
#     a uniform of that name (or, at global scope, include-all-branches — the
#     transpiled functions are uniquely named and dispatched at runtime)
#   - capture `out vec4 X;` -> global `vec4 X;` + record X in outputs
#   - capture `in vecN Y;` varyings (dropped; codegen maps them to ctx uv)

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(normalize);

# Remove block and line comments before preprocessing (a // comment trailing
# a #define value would otherwise be captured into the macro).
sub _strip_comments {
    my ($source) = @_;
    $source =~ s{/\*.*?\*/}{ }gs;
    $source =~ s{//[^\n]*}{}g;
    return $source;
}

sub _canonical_compatibility {
    my ($source, $canonical_key) = @_;
    # Two different pinned `uint hash_uint(uint)` bodies share one name.
    # noisemaker-for-cpu 5b686a4 routes them by BODY (compile-glsl
    # lowerUnsignedJavaScript): the murmur finalizer (7feb352d/846ca68b) keeps
    # stdlib.hashUint, the LCG-seeded mix (747796405; pointsEmit init, the
    # points/* agents, flow3d) goes to stdlib.hashUintLcg. hash_uint routes by
    # name in the codegen, so give the LCG body its own name.
    if ($source =~ /\buint\s+hash_uint\s*\(\s*uint\b/ && $source !~ /7feb352d|846ca68b/
        && index($source, '747796405') >= 0) {
        $source =~ s/\bhash_uint\s*\(/hash_uint_lcg(/g;
    }
    $source =~ s{\bmod\(\s*([A-Za-z_]\w*(?:\.[xyzw]{1,4})?)\s*\+\s*1\.0\s*,\s*2\.0\s*\)\s*-\s*1\.0\b}{($1 - 2.0 * floor(($1 + 1.0) * 0.5))}g;
    $source =~ s{\Qreturn fract((p3.x + p3.y) * p3.z);\E}{return fract(float(float(p3.x + p3.y) * p3.z));}g;
    $source =~ s{\Qreturn fract((p3.xx + p3.yz) * p3.zy);\E}{return fract(vec2(float(float(p3.x + p3.y) * p3.z), float(float(p3.x + p3.z) * p3.y)));}g;
    if (defined $canonical_key && $canonical_key eq 'filter/scatter:scatterJitter') {
        my $seed = ($source =~ s{\Qhash22(hashCoord + float(seed) * 101.7)\E}{hash22(hashCoord + float(seed * 101.7))}g);
        die "scatter canonical seed pattern changed\n" unless $seed == 1;
    }
    if (defined $canonical_key && $canonical_key eq 'filter/extrude:extrude') {
        my $scale = ($source =~ s{\Qfloat s = 1.0 + h * (depth / 100.0) * 0.4;\E}{float s = float(1.0 + h * (depth / 100.0) * 0.4);}g);
        my $face = ($source =~ s{\Qbool topHit = all(lessThanEqual(abs(P - faceCenter), faceHalf));\E}{bool topHit = all(lessThanEqual(abs((P - imgCenter) - (cellC - imgCenter) * s), faceHalf));}g);
        die "extrude canonical block-face pattern changed\n" unless $scale == 1 && $face == 1;
    }
    if (defined $canonical_key && $canonical_key eq 'filter/strokes:stkSmear') {
        my $pigment = ($source =~ s{\QpigmentSum += srcSample(centerUV).rgb * mark;\E}{pigmentSum += vec3(srcSample(centerUV).rgb * mark);}g);
        die "strokes canonical pigment pattern changed\n" unless $pigment == 1;
        # Vector declarations in the canonical kernel store binary results
        # in Float32Array lanes before later expressions consume them.
        my $vectors = ($source =~ s{\bvec2\s+(u|px|cell|jitter|center|delta|centerGlobal|centerUV|p|sampP|sampN|uv|gc)\s*=\s*([^;]+);}{vec2 $1 = vec2($2);}g);
        die "strokes canonical vector declarations changed\n" unless $vectors == 15;
    }
    if (defined $canonical_key
        && $canonical_key eq 'filter/temporalAberration:temporalAberration') {
        # The pinned CPU oracle's glsl-transpiler lowering evaluates `cur` on
        # an empty history slot but assigns only the false branch. Preserve
        # that observable behavior rather than the source GLSL's intended
        # empty-slot fallback, because render parity is defined by the pinned
        # generated CPU kernel.
        my $rewritten = ($source =~ s{
            slots\[(\d)\]\s*=\s*\(s\.a\s*<\s*0\.5\)\s*\?\s*cur\s*:\s*s\s*;
        }{if (!(s.a < 0.5)) { slots[$1] = s; }}gx);
        die "temporalAberration canonical compatibility pattern changed\n"
            unless $rewritten == 8;
    }
    elsif (defined $canonical_key && $canonical_key eq 'synth3d/flythrough3d:precompute') {
        # FractalResult holds exactly three floats. The canonical kernel
        # lowers it to a vec3 (dist, trap, iterRatio as x, y, z), so the Perl
        # kernel follows the same lowering.
        my $struct = ($source =~ s{struct\s+FractalResult\s*\{.*?\n\};\n}{}s);
        die "flythrough3d canonical FractalResult pattern changed\n" unless $struct == 1;
        $source =~ s{\bFractalResult\b}{vec3}g;
        $source =~ s{\.dist\b}{.x}g;
        $source =~ s{\.trap\b}{.y}g;
        $source =~ s{\.iterRatio\b}{.z}g;
    }
    elsif (defined $canonical_key && $canonical_key eq 'synth3d/cell3d:precompute') {
        my $p = ($source =~ s{
            vec3\s+hash3\(vec3\s+p\)\s*\{\s*p\s*=\s*p\s*\+\s*float\(seed\)\s*\*\s*0\.1\s*;
        }{vec3 hash3(vec3 base, vec3 neighbor) \{
    float cpuSeedOffset = float(seed * 0.1);
    vec3 cpuCellPos = vec3(base + neighbor);
    vec3 p = vec3(base.x + float(neighbor.x + cpuSeedOffset), cpuCellPos.y + cpuSeedOffset, cpuCellPos.z + cpuSeedOffset);}gx);
        my $call = ($source =~ s{\Qvec3 randomOffset = hash3(cellPos);\E}{vec3 randomOffset = hash3(i, neighbor);}g);
        my $q = ($source =~ s{
            uvec3\s+q\s*=\s*uvec3\(\s*ivec3\(\s*p\s*\*\s*1000\.0\s*\)\s*\+\s*65536\s*\)\s*;
        }{uvec3 q = uvec3(ivec3(vec3(p * 1000.0)) + 65536);}gx);
        die "cell3d canonical hash3 pattern changed\n" unless $p == 1 && $call == 1 && $q == 1;
        # The canonical kernel adds the cell point with vec3.add, which rounds
        # each component to f32, and stores diff in a Float32Array; the Perl
        # codegen defers both roundings.
        my $point = ($source =~ s{
            vec3\s+cellPoint\s*=\s*(neighbor\s*\+\s*mix\(vec3\(0\.5\),\s*randomOffset,\s*jitter\))\s*;
        }{vec3 cellPoint = vec3($1);}gx);
        my $diff = ($source =~ s{vec3\s+diff\s*=\s*cellPoint\s*-\s*f\s*;}{vec3 diff = vec3(cellPoint - f);}g);
        die "cell3d canonical cell-point pattern changed\n" unless $point == 1 && $diff == 1;
    }
    elsif (defined $canonical_key && $canonical_key eq 'synth3d/noise3d:precompute') {
        my $ps = ($source =~ s{
            float\s+hash4\(vec4\s+p\)\s*\{\s*vec4\s+ps\s*=\s*p\s*\+\s*float\(seed\)\s*\*\s*0\.1\s*;
        }{float hash4(vec4 p, vec4 k) \{
    float cpuSeedOffset = float(seed * 0.1);
    vec4 cpuLatticeOffset = vec4(k + cpuSeedOffset);
    vec4 ps = vec4(p + cpuLatticeOffset);}gx);
        my $grad = ($source =~ s{
            vec4\s+grad4\(vec4\s+p\)\s*\{\s*
            float\s+h1\s*=\s*hash4\(p\);\s*float\s+h2\s*=\s*hash4\(p\s*\+\s*127\.1\);\s*
            float\s+h3\s*=\s*hash4\(p\s*\+\s*269\.5\);\s*float\s+h4\s*=\s*hash4\(p\s*\+\s*419\.2\);
        }{vec4 grad4(vec4 p, vec4 k) \{
    float h1 = hash4(p, k);
    float h2 = hash4(p, k + 127.1);
    float h3 = hash4(p, k + 269.5);
    float h4 = hash4(p, k + 419.2);}gx);
        my $corners = ($source =~ s{grad4\(vec4\(i\.xyz, (iw[01])\) \+ (vec4\([01],[01],[01],0\))\)}{grad4(vec4(i.xyz, $1), $2)}g);
        my $q = ($source =~ s{
            uvec4\s+q\s*=\s*uvec4\(\s*ivec4\(\s*ps\s*\*\s*1000\.0\s*\)\s*\+\s*65536\s*\)\s*;
        }{uvec4 q = uvec4(ivec4(vec4(ps * 1000.0)) + 65536);}gx);
        die "noise3d canonical hash4 pattern changed\n" unless $ps == 1 && $grad == 1 && $corners == 16 && $q == 1;
    }
    elsif (defined $canonical_key && $canonical_key eq 'synth/perlin:perlin') {
        my $p = ($source =~ s{
            float\s+hash3\(vec3\s+p\)\s*\{\s*//\s*Add\ seed\ to\ input\ to\ vary\ the\ noise\ pattern\s*
            p\s*=\s*p\s*\+\s*float\(seed\)\s*\*\s*0\.1\s*;
        }{float hash3(vec3 p, vec3 k) \{
    float cpuSeedOffset = float(seed * 0.1);
    vec2 cpuLatticeOffset = vec2(k.xy + cpuSeedOffset);
    p = vec3(p.x + cpuLatticeOffset.x, p.y + cpuLatticeOffset.y, float(p.z + cpuSeedOffset) + k.z);}gx);
        my $grad = ($source =~ s{
            vec3\s+grad3\(vec3\s+p\)\s*\{\s*//\s*Generate\ 3\ independent\ random\ values\s*
            float\s+h1\s*=\s*hash3\(p\);\s*float\s+h2\s*=\s*hash3\(p\s*\+\s*127\.1\);\s*
            float\s+h3\s*=\s*hash3\(p\s*\+\s*269\.5\);
        }{vec3 grad3(vec3 p, vec3 k) \{
    float h1 = hash3(p, k);
    float h2 = hash3(p, k + 127.1);
    float h3 = hash3(p, k + 269.5);}gx);
        my $corners = ($source =~ s{grad3\(vec3\(i\.xy, (iz[01])\) \+ (vec3\([01],[01],0\))\)}{grad3(vec3(i.xy, $1), $2)}g);
        my $q = ($source =~ s{
            uvec3\s+q\s*=\s*uvec3\(\s*ivec3\(\s*p\s*\*\s*1000\.0\s*\)\s*\+\s*65536\s*\)\s*;
        }{uvec3 q = uvec3(ivec3(vec3(p * 1000.0)) + 65536);}gx);
        die "perlin canonical hash3 pattern changed\n" unless $p == 1 && $grad == 1 && $corners == 8 && $q == 1;
    }
    elsif (defined $canonical_key && $canonical_key eq 'synth/navierStokes:nsSplat') {
        my $hash = ($source =~ s{\Qreturn fract(sin(x * 12.9898) * 43758.5453);\E}{return fract(float(float(sin(float(float(x) * 12.9898))) * 43758.5453));}g);
        die "navierStokes canonical hash11 pattern changed\n" unless $hash == 1;
    }
    elsif (defined $canonical_key && $canonical_key =~ m{^synth3d/(?:reactionDiffusion3d|cellularAutomata3d):simulate$}) {
        my $hash = ($source =~ s{
            float\s+hash3\(vec3\s+p\)\s*\{\s*
            p\s*=\s*p\s*\+\s*float\(seed\)\s*\*\s*0\.1;\s*
            p\s*=\s*fract\(p\s*\*\s*vec3\(0\.1031,\s*0\.1030,\s*0\.0973\)\);\s*
            p\s*\+=\s*dot\(p,\s*p\.yxz\s*\+\s*33\.33\);\s*
            return\s+fract\(\(p\.x\s*\+\s*p\.y\)\s*\*\s*p\.z\);\s*\}
        }{float hash3(vec3 p) {
    p = vec3(p + float(seed * 0.1));
    p = fract(p * vec3(0.1031, 0.1030, 0.0973));
    float cpuHashDot = dot(p, p.yxz + 33.33);
    return fract(float(float(float(p.x + p.y) + float(cpuHashDot + cpuHashDot)) * float(p.z + cpuHashDot)));
}}gx);
        die "3D simulation canonical hash3 pattern changed\n" unless $hash == 1;
    }
    return $source;
}

sub normalize {
    my ($source, $runtime_defines, $canonical_key) = @_;
    $runtime_defines = {} unless defined $runtime_defines;
    $source = _canonical_compatibility($source, $canonical_key);
    my $body = _preprocess(_strip_comments($source), $runtime_defines);

    my (@out_lines, @outputs, @output_locations, @varyings);
    for my $line (split /\n/, $body, -1) {
        if ($line =~ /^\s*layout\s*\(([^)]*)\)\s*out\s+(\w+)\s+(\w+)\s*;\s*$/) {
            my ($layout, $type, $name) = ($1, $2, $3);
            my ($location) = $layout =~ /\blocation\s*=\s*(\d+)/;
            $location = scalar @output_locations unless defined $location;
            push @output_locations, { name => $name, location => 0 + $location, order => scalar @output_locations };
            push @out_lines, "$type $name;";
            next;
        }
        if ($line =~ /^\s*out\s+(\w+)\s+(\w+)\s*;\s*$/) {
            push @outputs, $2;
            push @output_locations, { name => $2, location => scalar @output_locations, order => scalar @output_locations };
            push @out_lines, "$1 $2;";
            next;
        }
        if ($line =~ /^\s*(?:flat\s+)?in\s+(\w+)\s+(\w+)\s*;\s*$/) {
            push @varyings, $2;
            next;    # codegen maps varyings to ctx uv
        }
        push @out_lines, $line;
    }

    # Declare runtime-define uniforms (they were lowered to runtime branches).
    my $decls = '';
    for my $name (sort keys %$runtime_defines) {
        my $t = $runtime_defines->{$name} eq 'float' ? 'float' : 'int';
        $decls .= "uniform $t $name;\n";
    }
    @outputs = map { $_->{name} }
        sort { $a->{location} <=> $b->{location} || $a->{order} <=> $b->{order} }
        @output_locations;
    return {
        source   => $decls . join("\n", @out_lines),
        outputs  => (@outputs ? \@outputs : ['fragColor']),
        varyings => \@varyings,
    };
}

sub _emitting {
    my ($stack) = @_;
    for (@$stack) { return 0 unless $_->{active} }
    return 1;
}

sub _preprocess {
    my ($source, $runtime_defines) = @_;
    my @out;
    my %defines;
    my @stack;      # frames: {kind => static|runtime|include_all, active, taken, outer}
    my $depth = 0;  # brace nesting of emitted content

    my $emit = sub {
        my ($line) = @_;
        push @out, $line;
        $depth += () = $line =~ /\{/g;
        $depth -= () = $line =~ /\}/g;
    };

    for my $raw (split /\n/, $source, -1) {
        my $s = $raw;
        $s =~ s/^\s+|\s+$//g;
        if ($s =~ /^#/) {
            (my $d = substr($s, 1)) =~ s/^\s+//;
            my ($head) = $d =~ /^(\S+)/;
            $head = '' unless defined $head;
            next if $head eq 'version' || $head eq 'extension' || $head eq 'pragma' || $head eq 'line';
            if ($head eq 'define') {
                if (_emitting(\@stack) && $d !~ /^define\s+\w+\(/) {    # object-like only
                    if ($d =~ /^define\s+(\w+)(?:\s+(.*))?$/) {
                        my $val = defined $2 ? $2 : '';
                        $val =~ s/^\s+|\s+$//g;
                        $defines{$1} = $val;
                    }
                }
                next;
            }
            if ($head eq 'undef') {
                if (_emitting(\@stack)) {
                    my (undef, $name) = split /\s+/, $d;
                    delete $defines{$name} if defined $name;
                }
                next;
            }
            if ($head eq 'ifdef' || $head eq 'ifndef' || $head eq 'if') {
                my $outer = _emitting(\@stack);
                if ($outer && _cond_runtime($d, $head, $runtime_defines)) {
                    if ($depth == 0) {
                        # Global-scope runtime #if gates whole declarations —
                        # include ALL branches; runtime dispatch happens at
                        # statement scope.
                        push @stack, { kind => 'include_all', active => 1, taken => 1, outer => $outer };
                    }
                    else {
                        $emit->('if (' . _glsl_cond($d, $head, \%defines) . ') {');
                        push @stack, { kind => 'runtime', active => 1, taken => 1, outer => $outer };
                    }
                }
                else {
                    my $val = $outer ? _eval_cond($d, $head, \%defines, $runtime_defines) : 0;
                    push @stack, { kind => 'static', active => ($outer && $val), taken => $val, outer => $outer };
                }
                next;
            }
            if ($head eq 'elif') {
                my $fr = $stack[-1];
                if ($fr->{kind} eq 'include_all') { }
                elsif ($fr->{kind} eq 'runtime') {
                    $emit->('} else if (' . _glsl_cond($d, 'if', \%defines) . ') {');
                    $fr->{active} = 1;
                }
                else {
                    if ($fr->{taken}) { $fr->{active} = 0 }
                    else {
                        my $val = $fr->{outer} ? _eval_cond($d, 'if', \%defines, $runtime_defines) : 0;
                        $fr->{active} = ($fr->{outer} && $val);
                        $fr->{taken} ||= $val;
                    }
                }
                next;
            }
            if ($head eq 'else') {
                my $fr = $stack[-1];
                if ($fr->{kind} eq 'include_all') { }
                elsif ($fr->{kind} eq 'runtime') {
                    $emit->('} else {');
                    $fr->{active} = 1;
                }
                else {
                    $fr->{active} = ($fr->{outer} && !$fr->{taken}) ? 1 : 0;
                    $fr->{taken}  = 1;
                }
                next;
            }
            if ($head eq 'endif') {
                my $fr = pop @stack;
                $emit->('}') if $fr && $fr->{kind} eq 'runtime';
                next;
            }
            next;    # unknown directive
        }
        $emit->(_expand($raw, \%defines)) if _emitting(\@stack);
    }
    return join "\n", @out;
}

sub _expand {
    my ($line, $defines) = @_;
    return $line unless %$defines;
    for (1 .. 16) {
        my $changed = 0;
        $line =~ s/\b([A-Za-z_]\w*)\b/
            exists $defines->{$1} ? do { $changed = 1; $defines->{$1} } : $1
        /ge;
        last unless $changed;
    }
    return $line;
}

sub _cond_runtime {
    my ($directive, $head, $runtime_defines) = @_;
    # #ifdef/#ifndef are about DEFINEDNESS: a runtime define is always
    # "defined" (bound as a uniform). Only `#if <expr>` needs lowering.
    return 0 if !%$runtime_defines || $head eq 'ifdef' || $head eq 'ifndef';
    my %idents = map { $_ => 1 } $directive =~ /\b([A-Za-z_]\w*)\b/g;
    for my $rd (keys %$runtime_defines) {
        return 1 if $idents{$rd};
    }
    return 0;
}

sub _strip_kw {
    my ($directive) = @_;
    $directive =~ s/^(?:elif|ifdef|ifndef|if)\b\s*//;
    $directive =~ s/^\s+|\s+$//g;
    return $directive;
}

sub _glsl_cond {
    my ($directive, $head, $defines) = @_;
    return 'true'  if $head eq 'ifdef';
    return 'false' if $head eq 'ifndef';
    return _expand(_strip_kw($directive), $defines);
}

sub _eval_cond {
    my ($directive, $head, $defines, $runtime_defines) = @_;
    if ($head eq 'ifdef' || $head eq 'ifndef') {
        my (undef, $n) = split /\s+/, $directive;
        my $defined = (defined $n && (exists $defines->{$n} || exists $runtime_defines->{$n})) ? 1 : 0;
        return $head eq 'ifdef' ? $defined : (1 - $defined);
    }
    my $expr = _strip_kw($directive);
    $expr =~ s/defined\s*\(\s*(\w+)\s*\)/exists $defines->{$1} ? 1 : 0/ge;
    $expr =~ s/defined\s+(\w+)/exists $defines->{$1} ? 1 : 0/ge;
    $expr = _expand($expr, $defines);
    # Hex literals evaluate numerically (translate before the letter scrub
    # below would zero the 'x').
    $expr =~ s/\b0[xX][0-9a-fA-F]+\b/hex($&)/ge;
    # undefined identifiers evaluate to 0 in C/GLSL #if; keep true/false
    $expr =~ s/\b([A-Za-z_]\w*)\b/($1 eq 'true' || $1 eq 'false') ? $1 : '0'/ge;
    $expr =~ s/\btrue\b/1/g;
    $expr =~ s/\bfalse\b/0/g;
    # Only arithmetic/comparison/logic characters may remain; then eval. The
    # charset admits < and > individually, but adjacent <> would be Perl's
    # readline operator (blocks on STDIN) — reject it outright.
    return 0 if $expr =~ /[^\d\s()<>=!&|^+\-*\/%~]/;
    return 0 if $expr =~ /<\s*>/;
    my $result = eval $expr;    ## no critic (eval of sanitized numeric expr)
    return $@ ? 0 : ($result ? 1 : 0);
}

1;
