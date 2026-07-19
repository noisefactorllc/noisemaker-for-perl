package Math::Fractal::Noisemaker::Transpiler::Lexer;

# GLSL ES 3.00 tokenizer (post-preprocess).
#
# Consumes already-normalized/preprocessed GLSL (no #directives). Produces a
# flat token list for the recursive-descent parser. Tokens are hashrefs:
# { kind => 'num'|'id'|'op', value => str, pos => int }.

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(tokenize);

# Multi-char operators, longest first so the scanner is greedy.
my @OPS = (
    '<<=', '>>=',
    '++', '--', '<<', '>>', '<=', '>=', '==', '!=', '&&', '||',
    '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=',
    '+', '-', '*', '/', '%', '<', '>', '=', '!', '~', '&', '|', '^',
    '?', ':', '.', ',', ';', '(', ')', '[', ']', '{', '}',
);

my $NUM = qr/
    (?:
        0[xX][0-9a-fA-F]+                 # hex int
      | (?:\d+\.\d*|\.\d+|\d+)            # decimal, with optional fraction
        (?:[eE][+-]?\d+)?                 # optional exponent
    )
    [uUfF]?                               # optional type suffix
/x;

sub tokenize {
    my ($source) = @_;
    my @tokens;
    pos($source) = 0;
    my $n = length $source;
    while (pos($source) < $n) {
        my $i = pos($source);
        if ($source =~ /\G\s+/gc)       { next }
        if ($source =~ /\G\/\/[^\n]*/gc) { next }
        if (substr($source, $i, 2) eq '/*') {
            if ($source =~ /\G\/\*.*?\*\//gcs) { next }
            die "unterminated block comment at $i\n";
        }
        my $c = substr($source, $i, 1);
        if ($c =~ /\d/ || ($c eq '.' && substr($source, $i + 1, 1) =~ /\d/)) {
            $source =~ /\G($NUM)/gc or die "bad number at $i\n";
            push @tokens, { kind => 'num', value => $1, pos => $i };
            next;
        }
        if ($c =~ /[A-Za-z_]/) {
            $source =~ /\G([A-Za-z_][A-Za-z0-9_]*)/gc;
            push @tokens, { kind => 'id', value => $1, pos => $i };
            next;
        }
        my $matched;
        for my $op (@OPS) {
            if (substr($source, $i, length $op) eq $op) {
                push @tokens, { kind => 'op', value => $op, pos => $i };
                pos($source) = $i + length $op;
                $matched = 1;
                last;
            }
        }
        die "unexpected character '$c' at $i\n" unless $matched;
    }
    push @tokens, { kind => 'op', value => '<eof>', pos => $n };
    return \@tokens;
}

1;
