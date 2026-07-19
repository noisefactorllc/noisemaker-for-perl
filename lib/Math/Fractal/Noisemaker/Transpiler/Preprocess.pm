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

sub normalize {
    my ($source, $runtime_defines) = @_;
    $runtime_defines = {} unless defined $runtime_defines;
    my $body = _preprocess(_strip_comments($source), $runtime_defines);

    my (@out_lines, @outputs, @varyings);
    for my $line (split /\n/, $body, -1) {
        if ($line =~ /^\s*out\s+(\w+)\s+(\w+)\s*;\s*$/) {
            push @outputs, $2;
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
