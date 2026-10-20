package Math::Fractal::Noisemaker::DSL;

# Polymorphic DSL front-end: tokenizer + parser + compiler.
#
# Faithful port of the (parity-proven) Python DSL modules
# noisemaker_cpu/dsl/{error,tokenizer,parser,compiler}.py, themselves ports
# of noisemaker-cpu src/dsl/*.js. compile_dsl() lowers a program to a render
# plan that Math::Fractal::Noisemaker::Renderer::render_dsl evaluates against
# the effect catalog (bundle metadata.json).
#
# Data conventions (the evaluator depends on these):
# - AST nodes are hashrefs with the same keys as the Python dicts ("kind",
#   "name", "value", "loc", "args", "argMode", "calls", "search", "bindings",
#   "chains", "render", ...); Python None -> undef, True/False -> 1/0.
# - Tokens: { type =>, lexeme =>, value =>, sourceName =>, line =>,
#   column =>, index => }.
# - compile_dsl($source, $effects, $options) returns { search => [...],
#   chains => [...], render_surface => $name }. Effect steps are
#   { kind => 'effect', effect_id =>, params => {...}, surfaces => {...},
#   loc => }.
# - Surface markers: undef = leave unbound (blank 1x1), the string
#   '@current' = bind the chain's current image, ['surface', 'oN'] = a named
#   surface (the Python port uses a tuple here).
# - Positional-arg mapping and the "accepted:" error listing use the
#   effect's paramOrder array from the metadata wherever Python used
#   list(param_specs.keys()): Perl hash order is random, and paramOrder is
#   the bundle's record of the Python/JS param dict order.
#
# Deliberate deviations from the Python source (reject-vs-accept space only;
# valid programs compile identically):
# - Python's _is_number excludes bool. Perl has no bool type (true/false lex
#   to the integers 1/0), so 1/0 pass as numbers — e.g. vec2(true, 1)
#   compiles here where Python raises. Numeric-looking DSL string literals
#   ("1") pass looks_like_number the same way.

use strict;
use warnings;
use JSON::PP     ();
use Scalar::Util qw(looks_like_number);
use B ();
use Exporter 'import';

use Math::Fractal::Noisemaker::Automation qw(
    is_automation_value
    is_finite_number
    MAX_AUTOMATION_DEPTH
);

our @EXPORT_OK = qw(tokenize_dsl parse_dsl compile_dsl);

my $_UNSUPPORTED_INPUT = bless {}, __PACKAGE__ . '::UnsupportedInput';
sub _is_unsupported_input { ref($_[0]) eq __PACKAGE__ . '::UnsupportedInput' }


# JSON-style string quoting for diagnostic text, matching Python json.dumps
# (ascii mode mirrors ensure_ascii=True) so error messages stay byte-equal.
my $_JSON_STR = JSON::PP->new->allow_nonref->ascii;

sub _jq { $_JSON_STR->encode(defined $_[0] ? "$_[0]" : '') }

# Every internal diagnostic goes through the located error object below.
sub _throw { Math::Fractal::Noisemaker::DSL::Error->throw(@_) }

# ---- tokenizer (port of dsl/tokenizer.py tokenize_dsl) ----

my %KEYWORDS    = map { $_ => 1 } qw(search let render true false subchain);
my %PUNCTUATION = map { $_ => 1 } split //, '(){}[],.:=;';
my %OPERATORS   = map { $_ => 1 } split //, '+-*/';

sub tokenize_dsl {
    my ($source, $options) = @_;
    $options = {} unless defined $options;
    die "DSL source must be a string\n" if !defined $source || ref $source;
    my $source_name = defined $options->{sourceName} ? $options->{sourceName} : '<dsl>';
    my @tokens;
    my $length = length $source;
    my ($index, $line, $column) = (0, 1, 1);

    my $at = sub {
        my $pos = $index + $_[0];
        return ($pos >= 0 && $pos < $length) ? substr($source, $pos, 1) : '';
    };
    my $start = sub {
        return { sourceName => $source_name, line => $line, column => $column, index => $index };
    };
    my $advance = sub {
        # At end-of-source this returns '' instead of dying (Python would
        # IndexError on e.g. a trailing backslash inside an unterminated
        # string); the enclosing loop then raises the located DslError.
        my $char = substr($source, $index, 1);
        $index++;
        if ($char eq "\n") { $line++; $column = 1 }
        else               { $column++ }
        return $char;
    };
    my $push_tok = sub {
        my ($type, $lexeme, $location, $value) = @_;
        push @tokens, { type => $type, lexeme => $lexeme, value => $value, %$location };
    };

    while ($index < $length) {
        my $char = substr($source, $index, 1);
        if ($char =~ /\s/) { $advance->(); next }
        if ($char eq '/' && $at->(1) eq '/') {
            while ($index < $length && substr($source, $index, 1) ne "\n") { $advance->() }
            next;
        }
        if ($char eq '/' && $at->(1) eq '*') {
            my $location = $start->();
            $advance->();
            $advance->();
            while ($index < $length && !(substr($source, $index, 1) eq '*' && $at->(1) eq '/')) {
                $advance->();
            }
            _throw('Unterminated block comment', $location) if $index >= $length;
            $advance->();
            $advance->();
            next;
        }

        my $location = $start->();
        if ($char eq '#') {
            my $lexeme = $advance->();
            while ($at->(0) =~ /^[0-9a-fA-F]$/) { $lexeme .= $advance->() }
            my $len = length $lexeme;
            _throw('Colors must use #RGB, #RRGGBB, or #RRGGBBAA', $location)
                unless $len == 4 || $len == 7 || $len == 9;
            $push_tok->('color', $lexeme, $location, undef);
            next;
        }
        if ($char eq '"' && $at->(1) eq '"' && $at->(2) eq '"') {
            # A triple-quoted string may span lines. The lexer keeps its
            # content raw, without escape processing, and the unparser
            # writes a multi-line string in this form.
            my $location = $start->();
            my $search_start = $index + 3;
            my $end = index($source, '"""', $search_start);
            _throw('Unterminated string', $location) if $end < 0;
            my $value = substr($source, $search_start, $end - $search_start);
            while ($index < $end + 3) { $advance->() }
            $push_tok->('string', $value, $location, $value);
            next;
        }
        if ($char eq '"') {
            $advance->();
            my $value = '';
            while ($index < $length && substr($source, $index, 1) ne '"') {
                if (substr($source, $index, 1) eq "\n") {
                    _throw('Unterminated string', $location);
                }
                if (substr($source, $index, 1) eq "\\") {
                    $advance->();
                    my $escaped = $advance->();
                    $value .= $escaped eq 'n' ? "\n" : $escaped eq 't' ? "\t" : $escaped;
                }
                else { $value .= $advance->() }
            }
            _throw('Unterminated string', $location) if $index >= $length;
            $advance->();
            $push_tok->('string', $value, $location, $value);
            next;
        }
        if ($char =~ /^\d$/ || ($char eq '.' && $at->(1) =~ /^\d$/)) {
            my $lexeme = '';
            while ($at->(0) =~ /^\d$/) { $lexeme .= $advance->() }
            if ($at->(0) eq '.') {
                $lexeme .= $advance->();
                while ($at->(0) =~ /^\d$/) { $lexeme .= $advance->() }
            }
            if ($at->(0) eq 'e' || $at->(0) eq 'E') {
                $lexeme .= $advance->();
                if ($at->(0) eq '+' || $at->(0) eq '-') { $lexeme .= $advance->() }
                while ($at->(0) =~ /^\d$/) { $lexeme .= $advance->() }
            }
            # Python float() rejects a truncated exponent like "1e"/"1e+";
            # mirror with a strict grammar so every DSL failure stays a
            # located DslError rather than a silent numify-to-garbage.
            _throw('Invalid numeric literal ' . _jq($lexeme), $location)
                unless $lexeme =~ /^(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/;
            $push_tok->('number', $lexeme, $location, 0 + $lexeme);
            next;
        }
        if ($char =~ /^[A-Za-z_]$/) {
            my $lexeme = $advance->();
            while ($at->(0) =~ /^[A-Za-z0-9_]$/) { $lexeme .= $advance->() }
            my $type =
                  $lexeme =~ /^o\d+$/ ? 'surface'
                : $KEYWORDS{$lexeme}  ? 'keyword'
                :                       'identifier';
            $push_tok->($type, $lexeme, $location, undef);
            next;
        }
        if ($PUNCTUATION{$char}) {
            $advance->();
            $push_tok->('punctuation', $char, $location, undef);
            next;
        }
        if ($OPERATORS{$char}) {
            $advance->();
            $push_tok->('operator', $char, $location, undef);
            next;
        }
        _throw('Unexpected character ' . _jq($char), $location);
    }

    push @tokens, {
        type       => 'eof',
        lexeme     => '',
        value      => undef,
        sourceName => $source_name,
        line       => $line,
        column     => $column,
        index      => $index,
    };
    return \@tokens;
}

# ---- parser (port of dsl/parser.py) ----

sub _location {
    my ($token) = @_;
    return {
        sourceName => $token->{sourceName},
        line       => $token->{line},
        column     => $token->{column},
        index      => $token->{index},
    };
}

sub _parse_color {
    my ($lexeme) = @_;
    my $hexit = substr($lexeme, 1);
    if (length($hexit) == 3) {
        $hexit = join '', map { $_ x 2 } split //, $hexit;
    }
    my @values = map { hex(substr($hexit, $_, 2)) / 255 } (0, 2, 4);
    push @values, hex(substr($hexit, 6, 2)) / 255 if length($hexit) == 8;
    return \@values;
}

# File-scoped so the _Parser methods below share it.
my %_PRECEDENCE = ('+' => 1, '-' => 1, '*' => 2, '/' => 2);

sub parse_dsl {
    my ($source, $options) = @_;
    $options = {} unless defined $options;
    return Math::Fractal::Noisemaker::DSL::_Parser->new(tokenize_dsl($source, $options))->parse_program;
}

package Math::Fractal::Noisemaker::DSL::_Parser;

# Recursive-descent parser state — port of parser.py class _Parser. Methods
# keep the Python names; _throw/_location alias the outer package's helpers.

*_throw    = \&Math::Fractal::Noisemaker::DSL::_throw;
*_location = \&Math::Fractal::Noisemaker::DSL::_location;

sub new {
    my ($class, $tokens) = @_;
    return bless { tokens => $tokens, current => 0 }, $class;
}

sub peek {
    my ($self, $offset) = @_;
    $offset = 0 unless defined $offset;
    my $tokens = $self->{tokens};
    my $i = $self->{current} + $offset;
    $i = $#$tokens if $i > $#$tokens;
    return $tokens->[$i];
}

# Note: at current == 0 this reads index -1 (the trailing eof token), the
# same wraparound Python's tokens[self.current - 1] produces.
sub previous { $_[0]{tokens}[ $_[0]{current} - 1 ] }

sub at_end { $_[0]->peek->{type} eq 'eof' }

sub check { $_[0]->peek->{lexeme} eq $_[1] }

sub match {
    my ($self, @lexemes) = @_;
    my $lex = $self->peek->{lexeme};
    return 0 unless grep { $_ eq $lex } @lexemes;
    $self->{current}++;
    return 1;
}

sub consume {
    my ($self, $lexeme, $message) = @_;
    if (!$self->check($lexeme)) {
        _throw(defined $message ? $message : "Expected \"$lexeme\"", _location($self->peek));
    }
    my $token = $self->{tokens}[ $self->{current} ];
    $self->{current}++;
    return $token;
}

sub identifier {
    my ($self, $message) = @_;
    $message = 'Expected identifier' unless defined $message;
    my $token = $self->peek;
    _throw($message, _location($token)) unless $token->{type} eq 'identifier';
    $self->{current}++;
    return $token;
}

# `render` is both a top-level directive keyword and the real namespace that
# owns the particle emitter/render effects. Accept that keyword token only in
# a search list; it remains reserved everywhere else in the grammar.
sub search_namespace {
    my ($self) = @_;
    my $token = $self->peek;
    if ($token->{type} eq 'identifier'
        || ($token->{type} eq 'keyword' && $token->{lexeme} eq 'render')) {
        $self->{current}++;
        return $token;
    }
    _throw('Expected namespace after search', _location($token));
}

sub parse_program {
    my ($self) = @_;
    my $ast = {
        kind     => 'DslProgram',
        search   => [],
        bindings => [],
        chains   => [],
        render   => undef,
        loc      => _location($self->peek),
    };
    if ($self->match('search')) {
        while (1) {
            push @{ $ast->{search} }, $self->search_namespace->{lexeme};
            last unless $self->match(',');
        }
        $self->match(';');
    }
    while (!$self->at_end) {
        next if $self->match(';');
        if ($self->match('let')) {
            push @{ $ast->{bindings} }, $self->parse_binding($self->previous);
        }
        elsif ($self->match('render')) {
            _throw('Program may only declare one render surface', _location($self->previous))
                if $ast->{render};
            my $start = $self->previous;
            $self->consume('(');
            $ast->{render} = $self->parse_surface;
            $ast->{render}{loc} = _location($start);
            $self->consume(')');
            $self->match(';');
        }
        else {
            push @{ $ast->{chains} }, $self->parse_chain;
            $self->match(';');
        }
    }
    return $ast;
}

sub parse_binding {
    my ($self, $start) = @_;
    my $name = $self->identifier('Expected binding name after let');
    $self->consume('=');
    my $value;
    if ($self->peek->{type} eq 'identifier' && $self->peek(1)->{lexeme} eq '(') {
        $value = $self->parse_call;
    }
    else {
        $value = $self->parse_value_expression;
    }
    $self->match(';');
    return { kind => 'Binding', name => $name->{lexeme}, value => $value, loc => _location($start) };
}

sub parse_chain {
    my ($self) = @_;
    my $first = $self->parse_call;
    my $calls = [$first];
    while ($self->match('.')) {
        if ($self->at_subchain) {
            push @$calls, $self->parse_subchain;
        }
        elsif ($self->peek->{lexeme} eq 'write3d' && $self->peek->{type} eq 'identifier') {
            push @$calls, $self->parse_write3d;
        }
        else {
            push @$calls, $self->parse_call;
        }
    }
    return { kind => 'Chain', calls => $calls, loc => $first->{loc} };
}

# Port of upstream parseWriteCall for write3d: two positional references, a
# volume and a geometry (`write3d(vol0, geo0)`), each an identifier or a surface.
sub parse_write3d {
    my ($self) = @_;
    my $name = $self->identifier;
    $self->consume('(');
    my $reference = sub {
        my $token = $self->peek;
        if ($token->{type} eq 'surface') {
            return $self->parse_surface;
        }
        _throw('Expected surface reference', _location($token))
            unless $token->{type} eq 'identifier';
        $self->{current}++;
        return { kind => 'identifier', name => $token->{lexeme}, loc => _location($token) };
    };
    my $volume = $reference->();
    $self->consume(',');
    my $geometry = $reference->();
    $self->consume(')');
    return {
        kind    => 'Call',
        name    => 'write3d',
        args    => [ map { { name => undef, value => $_, loc => $_->{loc} } } ($volume, $geometry) ],
        argMode => 'positional',
        loc     => _location($name),
    };
}

sub at_subchain {
    my ($self) = @_;
    return $self->peek->{type} eq 'keyword' && $self->peek->{lexeme} eq 'subchain';
}

sub is_punctuation {
    my ($self, $lexeme) = @_;
    return $self->peek->{type} eq 'punctuation' && $self->peek->{lexeme} eq $lexeme;
}

# A chain in a value position (upstream parseChain in its 'expression' context).
# It may hold subchain blocks, and it cannot hold write() or write3d().
sub parse_expression_chain {
    my ($self, $first) = @_;
    my $calls = [$first];
    while ($self->is_punctuation('.')) {
        $self->{current}++;
        if ($self->at_subchain) {
            push @$calls, $self->parse_subchain;
            next;
        }
        my $call = $self->parse_call;
        _throw('Expected effect or IO function name', $call->{loc})
            if $call->{name} eq 'write' || $call->{name} eq 'write3d';
        push @$calls, $call;
    }
    return { kind => 'Chain', calls => $calls, loc => $first->{loc} };
}

# Port of upstream parseSubchainCall: `subchain(name: "...", id: "...") { .a() .b() }`.
# A single leading string is shorthand for `name`. Unknown keys, duplicate keys and
# a missing ',' between keys are upstream warnings (P008-P010): the program still
# compiles, an unknown key's value is discarded and the last duplicate wins. The
# body holds one or more '.'-prefixed calls and cannot hold write(), write3d() or
# another subchain, which upstream's lexer reserves as keywords.
sub parse_subchain {
    my ($self) = @_;
    my $start = $self->{tokens}[ $self->{current}++ ];
    $self->consume('(');
    my %meta = (name => undef, id => undef);
    if ($self->peek->{type} eq 'string') {
        $meta{name} = $self->{tokens}[ $self->{current}++ ]{value};
    }
    else {
        while ($self->peek->{type} eq 'identifier' && $self->peek(1)->{lexeme} eq ':') {
            my $key = $self->identifier->{lexeme};
            $self->consume(':');
            # A value that is not a string ends the arguments, so the closing ')'
            # check below reports it.
            last if $self->peek->{type} ne 'string';
            my $value = $self->{tokens}[ $self->{current}++ ]{value};
            $meta{$key} = $value if $key eq 'name' || $key eq 'id';
            $self->match(',');
        }
    }
    $self->consume(')');
    $self->consume('{');
    # The body holds at least one element, so an empty block fails on its
    # missing '.'.
    my @body;
    do {
        $self->consume('.');
        my $call = $self->parse_call;
        _throw('Expected effect or IO function name', $call->{loc})
            if $call->{name} eq 'write' || $call->{name} eq 'write3d';
        push @body, $call;
    } while (!$self->check('}'));
    $self->consume('}');
    return { kind => 'Subchain', name => $meta{name}, id => $meta{id}, body => \@body, loc => _location($start) };
}

sub parse_call {
    my ($self) = @_;
    my $name = $self->identifier('Expected effect or IO function name');
    $self->consume('(');
    my @args;
    my $mode;
    if (!$self->check(')')) {
        while (1) {
            my $is_named = $self->peek->{type} eq 'identifier' && $self->peek(1)->{lexeme} eq ':';
            my $next_mode = $is_named ? 'named' : 'positional';
            # Upstream's parseCall lets the midi() and audio() value calls mix
            # positional and keyword arguments (`allowMixed`); every other call
            # keeps one form.
            my $allow_mixed = $name->{lexeme} eq 'midi' || $name->{lexeme} eq 'audio';
            _throw('Cannot mix positional and named arguments', _location($self->peek))
                if defined $mode && $mode ne $next_mode && !$allow_mixed;
            $mode = (defined $mode && $mode ne $next_mode) ? 'mixed' : $next_mode;
            my $arg_name;
            if ($is_named) {
                $arg_name = $self->identifier->{lexeme};
                $self->consume(':');
            }
            my $start = $self->peek;
            push @args, { name => $arg_name, value => $self->parse_value_expression, loc => _location($start) };
            last unless $self->match(',');
        }
    }
    $self->consume(')');
    my $call = { kind => 'Call', name => $name->{lexeme}, args => \@args, argMode => $mode, loc => _location($name) };
    return $call->{name} eq 'from' ? _from_call($call) : $call;
}

# Port of upstream transformFromInvocation: `from(namespace, effect(...))` is the
# effect call, resolved in that one namespace instead of the search order. It
# takes exactly two positional arguments, an identifier and one call; upstream's
# read(), read3d(), osc(), midi() and audio() nodes are not Call nodes. Any
# other from(...) stays a call named `from`, which no namespace defines, so the
# compiler rejects it as an unknown effect.
sub _from_call {
    my ($call) = @_;
    return $call if ($call->{argMode} // '') ne 'positional' || @{ $call->{args} } != 2;
    my ($namespace, $target) = map { $_->{value} } @{ $call->{args} };
    my $inner = (ref $target eq 'HASH' && ($target->{kind} // '') eq 'Chain' && @{ $target->{calls} } == 1)
        ? $target->{calls}[0] : undef;
    return $call
        if !ref $namespace || ($namespace->{kind} // '') ne 'identifier'
        || !ref $inner || ($inner->{kind} // '') ne 'Call'
        || grep { ($inner->{name} // '') eq $_ } ('read', 'read3d', 'write', 'write3d');
    return { %$inner, namespace => $namespace->{name} };
}

sub parse_value_expression {
    my ($self, $min_precedence) = @_;
    $min_precedence = 0 unless defined $min_precedence;
    my $left = $self->parse_value_unary;
    while (1) {
        my $lex = $self->peek->{lexeme};
        my $prec = exists $_PRECEDENCE{$lex} ? $_PRECEDENCE{$lex} : -1;
        last if $prec < $min_precedence;
        my $operator = $self->{tokens}[ $self->{current} ];
        $self->{current}++;
        my $right = $self->parse_value_expression($_PRECEDENCE{ $operator->{lexeme} } + 1);
        $left = {
            kind     => 'binary',
            operator => $operator->{lexeme},
            left     => $left,
            right    => $right,
            loc      => _location($operator),
        };
    }
    return $left;
}

sub parse_value_unary {
    my ($self) = @_;
    if ($self->match('-', '+')) {
        my $operator = $self->previous;
        return {
            kind     => 'unary',
            operator => $operator->{lexeme},
            argument => $self->parse_value_unary,
            loc      => _location($operator),
        };
    }
    return $self->parse_value_primary;
}

sub parse_value_primary {
    my ($self) = @_;
    my $token = $self->peek;
    if ($token->{type} eq 'number') {
        $self->{current}++;
        return $token->{value};
    }
    if ($token->{type} eq 'string') {
        $self->{current}++;
        return $token->{value};
    }
    if ($token->{lexeme} eq 'true' || $token->{lexeme} eq 'false') {
        # Upstream keeps JS booleans in the AST; the Perl parser keeps the
        # 'true'/'false' token string so automation fields can gate boolean
        # coercion (allowBoolean). _evaluate_value lowers it to 1/0 where a
        # raw value is consumed.
        $self->{current}++;
        return $token->{lexeme};
    }
    if ($token->{type} eq 'color') {
        $self->{current}++;
        return Math::Fractal::Noisemaker::DSL::_parse_color($token->{lexeme});
    }
    if ($token->{type} eq 'surface') {
        return $self->parse_surface;
    }
    if ($self->match('[')) {
        my @values;
        if (!$self->check(']')) {
            while (1) {
                push @values, $self->parse_value_expression;
                last unless $self->match(',');
            }
        }
        $self->consume(']');
        return \@values;
    }
    if ($self->match('(')) {
        my $value = $self->parse_value_expression;
        $self->consume(')');
        return $value;
    }
    # `Math.PI` is the one numeric constant of upstream's grammar
    # (`NumberExpr ::= Number | 'Math.PI' | ...`). Match the three-token
    # sequence `Math` `.` `PI` before the generic identifier handling.
    if ($token->{type} eq 'identifier' && $token->{lexeme} eq 'Math'
        && $self->peek(1)->{type} eq 'punctuation' && $self->peek(1)->{lexeme} eq '.'
        && $self->peek(2)->{type} eq 'identifier' && $self->peek(2)->{lexeme} eq 'PI') {
        $self->{current} += 3;
        return 4 * atan2(1, 1);
    }
    if ($token->{type} eq 'identifier') {
        $self->{current}++;
        my $name = $token->{lexeme};
        # A one-argument `read3d(vol0)` names a volume or geometry for a parameter,
        # as upstream's validator reads it. With two arguments it starts a chain.
        if ($name eq 'read3d' && $self->is_punctuation('(')) {
            $self->{current}--;
            my $call = $self->parse_call;
            if (@{ $call->{args} } == 1 && ref($call->{args}[0]{value}) eq 'HASH'
                && ($call->{args}[0]{value}{kind} // '') eq 'identifier') {
                return $call->{args}[0]{value};
            }
            return $self->parse_expression_chain($call);
        }
        # MIDI/audio calls are parsed only for unsupported-input warnings.
        if ($name =~ /\A(?:osc|midi|audio)\z/ && $self->peek->{lexeme} eq '(') {
            $self->{current}--;
            return $self->parse_call;
        }
        if ($name eq 'read' && $self->match('(')) {
            if ($self->peek->{type} eq 'identifier' && $self->peek(1)->{lexeme} eq ':') {
                my $argument_name = $self->identifier->{lexeme};
                if ($argument_name ne 'surface' && $argument_name ne 'tex') {
                    _throw('read() surface argument must be named "surface" or "tex"',
                        _location($self->previous));
                }
                $self->consume(':');
            }
            my $surface = $self->parse_surface;
            $self->consume(')');
            # `read(oN).effect()` in a value position is a chain argument that starts
            # from the surface. A bare `read(oN)` stays a plain surface reference.
            if ($self->is_punctuation('.')) {
                my $read = {
                    kind    => 'Call',
                    name    => 'read',
                    args    => [ { name => undef, value => $surface, loc => $surface->{loc} } ],
                    argMode => 'positional',
                    loc     => _location($token),
                };
                return $self->parse_expression_chain($read);
            }
            return $surface;
        }
        if (($name eq 'vec2' || $name eq 'vec3' || $name eq 'vec4') && $self->match('(')) {
            my @values;
            if (!$self->check(')')) {
                while (1) {
                    push @values, $self->parse_value_expression;
                    last unless $self->match(',');
                }
            }
            $self->consume(')');
            return { kind => 'vector', width => 0 + substr($name, -1), values => \@values, loc => _location($token) };
        }
        # (upstream `Expr ::= Chain`), for example `tex: solid(color: #f00)`.
        if ($self->is_punctuation('(')) {
            $self->{current}--;
            return $self->parse_expression_chain($self->parse_call);
        }
        my $path = $name;
        while ($self->match('.')) {
            $path .= '.' . $self->identifier('Expected enum member')->{lexeme};
        }
        return { kind => 'identifier', name => $path, loc => _location($token) };
    }
    _throw('Expected DSL value', _location($token));
}

sub parse_surface {
    my ($self) = @_;
    my $token = $self->peek;
    _throw('Expected surface reference', _location($token)) unless $token->{type} eq 'surface';
    $self->{current}++;
    my $index = 0 + substr($token->{lexeme}, 1);
    if ($index < 0 || $index > 7) {
        _throw('Surface reference must be o0 through o7', _location($token));
    }
    return { kind => 'surface', name => $token->{lexeme}, loc => _location($token) };
}

package Math::Fractal::Noisemaker::DSL;

# ---- compiler (port of dsl/compiler.py) ----
#
# Resolves each call against the effect catalog, merges `let` partials,
# evaluates value expressions/bindings, and lowers every chain into a flat
# list of read/write/effect steps. Effect steps split arguments into value
# params (handed to render_effect, which coerces + fills defaults) and
# surface bindings, applying each surface param's own default
# ("inputTex"/"none") exactly as the JS engine does.

sub _is_number {
    # Python excludes bool here; Perl true/false are the numbers 1/0, so
    # they pass (documented deviation, see module header).
    my ($value) = @_;
    return 0 if ref $value;
    # A string token (e.g. "1") must not pass as a number, even if it
    # looks like one: string-only scalars are rejected.
    my $sv = B::svref_2object(\$value);
    if (($sv->FLAGS & B::SVf_POK) && !($sv->FLAGS & B::SVf_IOK || $sv->FLAGS & B::SVf_NOK)) {
        return 0;
    }
    return Scalar::Util::looks_like_number($value) ? 1 : 0;
}

sub _is_surface {
    my ($value) = @_;
    return ref $value eq 'HASH' && defined $value->{kind} && $value->{kind} eq 'surface' ? 1 : 0;
}

# Mirrors upstream std_enums.js oscKind (sine..noise2d; noise/noise1d alias kind 5,
# noise2d is the two-stage periodic noise).
my %_OSC_KINDS = (sine => 0, tri => 1, saw => 2, sawInv => 3, square => 4, noise => 5, noise1d => 5, noise2d => 6);
my @_OSC_PARAM_ORDER = ('type', 'min', 'max', 'speed', 'offset', 'seed');

# The upstream std_enums.js enums that automation descriptors resolve. A dotted
# path or bare name outside these tables does not resolve, which upstream reports
# as a warning (S002) and replaces with the field's fallback.
my %_STD_ENUMS = (
    oscKind  => \%_OSC_KINDS,
    midiMode => {
        noteChange => 0, gateNote => 1, gateVelocity => 2, triggerNote => 3, velocity => 4,
        cc => 5, cc14 => 6, nrpn => 7, pitchBend => 8, pressure => 9, polyPressure => 10,
    },
    midiZone  => { lower => 0, upper => 1 },
    audioBand => { low => 0, mid => 1, high => 2, vol => 3, raw => 4 },
    oscType   => { sine => 0, linear => 1, sawtooth => 2, sawtoothInv => 3, square => 4, noise1d => 5, noise2d => 6 },
    channel   => { r => 0, g => 1, b => 2, a => 3 },
    color     => { mono => 0, rgb => 1, hsv => 2 },
);

# Splits a midi()/audio() call into upstream's resolved fields: positional
# arguments fill the positional order densely, keyword arguments take their
# own slots (the last duplicate keyword wins), and omitted fields take defaults.
my @_MIDI_POSITIONAL  = ('channel', 'mode', 'min', 'max', 'sensitivity');
my @_MIDI_KEYWORD_ONLY = ('name', 'id', 'cc', 'nrpn', 'zone', 'members');
my @_AUDIO_POSITIONAL  = ('band', 'min', 'max');
my @_AUDIO_KEYWORD_ONLY = ('channel', 'name', 'id');

# Compiles an `osc(...)` value-position call into the automation value shape the
# runtime evaluator consumes ({type: 'Oscillator', oscType, min, max, speed,
# offset, seed}), mirroring upstream's parser transformOscInvocation plus the
# validator's compileAutomationDescriptor: positional args fill
# type/min/max/speed/offset/seed in order, kwargs select by name, every field
# defaults as upstream defaults, min/max clamp into [0,1], nested osc() fields
# are allowed, and the oscType resolves from an integer 0..6 or an oscKind name
# (bare or oscKind-qualified). Invalid programs throw DslError, as everywhere
# else in this compiler.
sub _compile_oscillator {
    my ($call, $bindings, $depth) = @_;
    my $loc = $call->{loc};
    if ($depth > MAX_AUTOMATION_DEPTH) {
        _throw("Automation nesting exceeds the maximum depth of " . MAX_AUTOMATION_DEPTH, $loc);
    }
    my %fields;
    my $args = $call->{args};
    if (($call->{argMode} || '') eq 'named') {
        for my $arg (@$args) {
            my $name = $arg->{name};
            unless (grep { $_ eq $name } @_OSC_PARAM_ORDER) {
                _throw("osc() unknown parameter '$name'; valid: " . join(', ', @_OSC_PARAM_ORDER), $loc);
            }
            $fields{$name} = $arg->{value};
        }
    }
    else {
        for my $index (0 .. $#$args) {
            $fields{ $_OSC_PARAM_ORDER[$index] } = $args->[$index]{value} if $index < @_OSC_PARAM_ORDER;
        }
    }

    my $raw_type = !exists $fields{type} ? 0 : _evaluate_value($fields{type}, $bindings, $depth + 1);
    my $osc_type;
    if (_is_number($raw_type)) {
        if ($raw_type != int($raw_type) || $raw_type < 0 || $raw_type > 6) {
            _throw('osc() type must resolve to a supported oscKind value (0-6)', $loc);
        }
        $osc_type = 0 + int($raw_type);
    }
    elsif (!ref $raw_type && defined $raw_type && !looks_like_number($raw_type) && length($raw_type)) {
        my $kind_name = $raw_type;
        $kind_name =~ s/\AoscKind\.//;
        unless (exists $_OSC_KINDS{$kind_name}) {
            _throw("osc() type must resolve to a supported oscKind value; got \"$raw_type\"", $loc);
        }
        $osc_type = $_OSC_KINDS{$kind_name};
    }
    else {
        _throw('osc() type must resolve to a supported oscKind value', $loc);
    }

    my $number_field = sub {
        my ($node, $name, $fallback, $clamp) = @_;
        return $fallback unless defined $node;
        my $value = _evaluate_value($node, $bindings, $depth + 1);
        return $fallback if _is_unsupported_input($value);
        return $value if is_automation_value($value);
        return $value if !ref $value && _is_number($value) && is_finite_number($value);
        _throw("osc() $name must be a number or a nested osc()", $loc);
    };
    my $apply_field = sub {
        my ($node, $name, $fallback, $clamp) = @_;
        my $value = $number_field->($node, $name, $fallback, $clamp);
        return $value unless $clamp;
        return $value < 0 ? 0 : $value > 1 ? 1 : $value if !ref $value;
        return $value;
    };

    return {
        type    => 'Oscillator',
        oscType => $osc_type,
        min     => $apply_field->(exists $fields{min}    ? $fields{min}    : undef, 'min',    0, 1),
        max     => $apply_field->(exists $fields{max}    ? $fields{max}    : undef, 'max',    1, 1),
        speed   => $apply_field->(exists $fields{speed}  ? $fields{speed}  : undef, 'speed',  1, 0),
        offset  => $apply_field->(exists $fields{offset} ? $fields{offset} : undef, 'offset', 0, 0),
        seed    => $apply_field->(exists $fields{seed}   ? $fields{seed}   : undef, 'seed',   1, 0),
    };
}

# The selector strings must be non-empty string literals (upstream parser).
sub _check_selector_strings {
    my ($call, $fields) = @_;
    for my $field ('name', 'id') {
        next unless exists $fields->{$field};
        my $value = $fields->{$field};
        _throw("Unsupported DSL value Call \"$call->{name}\"", $call->{loc})
            if !defined $value || ref $value || !length($value);
    }
}

# Port of upstream resolveAutomationEnum. Returns the resolved numeric value or
# the fallback (a bare identifier/string outside the enum table is upstream's
# S002 warning; a string literal is an error).
sub _resolve_automation_enum {
    my ($node, $enum_name, $fallback, $valid_values, $call, $field) = @_;
    my $resolved;
    if (_is_number($node)) {
        $resolved = $node;
    }
    elsif (ref $node eq 'HASH' && ($node->{kind} // '') eq 'identifier') {
        $resolved = _resolve_std_enum($node->{name});
        if (!defined $resolved) {
            $resolved = _resolve_std_enum("$enum_name.$node->{name}");
        }
    }
    if (defined $resolved && _is_number($resolved) && exists $valid_values->{$resolved}) {
        return $resolved;
    }
    if (!ref $node && defined $node && !looks_like_number($node)) {
        _throw("Parameter \"$field\" must be an enum value", $call->{loc});
    }
    return $fallback;
}

# Port of upstream resolveAutomationNumber. Returns a hash with `value` and
# `valid`; `valid` is false where upstream reports a warning and keeps the
# field's fallback.
sub _resolve_automation_number {
    my ($node, $bindings, $depth, $call, $field, $fallback, $options) = @_;
    $options //= {};
    return { value => $fallback, valid => 1 } unless defined $node;
    my $invalid = { value => $fallback, valid => 0 };
    my $value;
    if (_is_number($node)) {
        $value = $node;
    }
    elsif (ref $node eq 'HASH' && ($node->{type} // '') =~ /\A(?:Oscillator|Midi|Audio)\z/) {
        # An already-compiled automation value (bound by `let`, whose bindings are
        # evaluated eagerly). Returned as the field's value; the runtime evaluator
        # resolves nested automation recursively, as upstream does.
        return { value => $node, valid => (defined $node->{_invalid} ? 0 : 1) };
    }
    elsif (!ref $node && ($node eq 'true' || $node eq 'false')) {
        # Upstream keeps booleans in the AST; a boolean coerces only where
        # upstream passes allowBoolean (midi()'s min and max). Otherwise the
        # field keeps its fallback value and is flagged invalid, without a
        # throw (upstream returns { value: fallback, valid: false }).
        return $invalid unless $options->{allowBoolean};
        $value = $node eq 'true' ? 1 : 0;
    }
    elsif (ref $node eq 'HASH' && ($node->{kind} // '') eq 'identifier'
        && $node->{name} =~ /\./ && ($options->{allowMember} // 1)) {
        $value = _resolve_std_enum($node->{name});
    }
    elsif (ref $node eq 'HASH' && ($node->{kind} // '') eq 'Call'
        && $node->{name} =~ /\A(?:osc|midi|audio)\z/ && $options->{allowAutomation}) {
        my $compiled = _compile_automation_call($node, $bindings, $depth + 1);
        return { value => $compiled, valid => (defined $compiled->{_invalid} ? 0 : 1) };
    }
    elsif (!ref $node && defined $node
        || (ref $node eq 'HASH' && ($node->{kind} // '') eq 'identifier' && $node->{name} !~ /\./)) {
        _throw("Parameter \"$field\" must be a finite number", $call->{loc});
    }
    else {
        return $invalid;
    }
    return $invalid if !defined $value || ref $value || !_is_number($value) || !is_finite_number($value);
    return $invalid if $options->{integer} && $value != int($value);
    return $invalid if defined $options->{min} && $value < $options->{min};
    return $invalid if defined $options->{max} && $value > $options->{max};
    $value = $value < 0 ? 0 : $value > 1 ? 1 : $value if $options->{clamp01};
    return { value => $value, valid => 1 };
}

# Splits a midi()/audio() call into upstream's resolved fields: positional
# arguments fill the positional order densely, keyword arguments take their
# own slots (the last duplicate keyword wins), and omitted fields take defaults.
sub _automation_fields {
    my ($call, $bindings, $positional_order, $keyword_only, $defaults) = @_;
    my %valid = map { $_ => 1 } (@$positional_order, @$keyword_only);
    my (@positional, %kwargs);
    for my $arg (@{ $call->{args} }) {
        if (defined $arg->{name}) { $kwargs{ $arg->{name} } = $arg->{value} }
        else { push @positional, $arg }
    }
    # Upstream: the keyword-only fields cannot take a positional argument.
    # excess() reports the arg's 1-based position in the full argument list.
    my $excess = sub {
        my ($arg) = @_;
        my ($index) = grep { $call->{args}[$_] == $arg } 0 .. $#{ $call->{args} };
        _throw("Unknown parameter \"argument " . ($index + 1) . "\" for $call->{name}(); accepted: "
            . join(', ', @$positional_order, @$keyword_only), $call->{loc});
    };
    $excess->($positional[ @$positional_order ]) if @positional > @$positional_order;
    for my $key (keys %kwargs) {
        unless ($valid{$key}) {
            _throw("Unknown parameter \"$key\" for $call->{name}(); accepted: "
                . join(', ', @$positional_order, @$keyword_only), $call->{loc});
        }
    }
    my %fields;
    my $cursor = 0;
    for my $field (@$positional_order) {
        if (exists $kwargs{$field}) { $fields{$field} = $kwargs{$field} }
        elsif ($cursor < @positional) { $fields{$field} = $positional[ $cursor++ ]->{value} }
        elsif (exists $defaults->{$field}) { $fields{$field} = $defaults->{$field} }
    }
    $excess->($positional[$cursor]) if $cursor < @positional;
    for my $field (@$keyword_only) {
        $fields{$field} = $kwargs{$field} if exists $kwargs{$field};
    }
    for my $field (keys %fields) {
        next if $field eq 'name' || $field eq 'id';
        $fields{$field} = _substitute_field($fields{$field}, $bindings);
    }
    return \%fields;
}

# Replaces an identifier bound by `let` with the bound expression, as upstream's
# validator substitutes symbols before it compiles an automation descriptor, and
# folds arithmetic to a number, as upstream's parser does.
sub _substitute_field {
    my ($node, $bindings, $seen) = @_;
    $seen //= {};
    return _evaluate_value($node, $bindings) if ref $node eq 'HASH' && ($node->{kind} // '') =~ /\A(?:unary|binary)\z/;
    return $node if !ref $node || ref $node ne 'HASH' || ($node->{kind} // '') ne 'identifier'
        || $node->{name} =~ /\./;
    my $binding = $bindings->{ $node->{name} };
    return $node if !defined $binding || $seen->{ $node->{name} };
    $seen->{ $node->{name} } = 1;
    if (($binding->{kind} // '') eq 'value') {
        return $binding->{value};
    }
    if (($binding->{kind} // '') eq 'alias') {
        return { kind => 'identifier', name => $binding->{name}, loc => $node->{loc} };
    }
    # An effect partial is a call that is not an automation source.
    return { kind => 'Call', name => $binding->{call}{name}, args => [], argMode => undef, loc => $node->{loc} };
}

# Resolves a dotted enum path in the standard enum tables. Returns undef for
# any path that is not exactly `enumName.member` in a known table.
sub _resolve_std_enum {
    my ($path) = @_;
    return undef unless defined $path && length $path;
    my ($head, $rest) = split /\./, $path, 2;
    return undef unless defined $rest && $rest !~ /\./ && exists $_STD_ENUMS{$head};
    return exists $_STD_ENUMS{$head}->{$rest} ? $_STD_ENUMS{$head}->{$rest} : undef;
}

sub _compile_midi {
    my ($call, $bindings, $depth) = @_;
    my $loc = $call->{loc};
    if ($depth > MAX_AUTOMATION_DEPTH) {
        _throw("Automation nesting exceeds the maximum depth of " . MAX_AUTOMATION_DEPTH, $loc);
    }
    my $fields = _automation_fields($call, $bindings, \@_MIDI_POSITIONAL, \@_MIDI_KEYWORD_ONLY,
        { mode => 4, min => 0, max => 1, sensitivity => 1 });
    my $has_zone = exists $fields->{zone};
    if (!exists $fields->{channel} && !$has_zone) {
        _throw('Missing required parameter "channel" for midi()', $loc);
    }
    if (exists $fields->{channel} && $has_zone) {
        _throw("Unsupported DSL value Call \"$call->{name}\"", $loc);
    }
    if (exists $fields->{members} && !$has_zone) {
        _throw('Missing required parameter "zone" for midi()', $loc);
    }
    if (exists $fields->{id} && !exists $fields->{name}) {
        _throw('Missing required parameter "name" for midi()', $loc);
    }
    _check_selector_strings($call, $fields);

    my %midi_modes = map { $_ => 1 } (0 .. 10);
    my $mode = _resolve_automation_enum($fields->{mode}, 'midiMode', 4, \%midi_modes, $call, 'mode');
    my $zone = $has_zone
        ? _resolve_automation_enum($fields->{zone}, 'midiZone', undef, { map { $_ => 1 } (0 .. 1) }, $call, 'zone')
        : undef;
    my $valid_selection = !$has_zone || defined $zone;
    my $members;
    if (exists $fields->{members}) {
        my $result = _resolve_automation_number($fields->{members}, $bindings, $depth, $call,
            'members', undef, { integer => 1, min => 1, max => 15, allowMember => 0 });
        $members = $result->{value};
        $valid_selection = 0 unless $result->{valid};
    }
    my $valid_channel = 1;
    my $channel;
    if (!$has_zone) {
        my $result = _resolve_automation_number($fields->{channel}, $bindings, $depth, $call,
            'channel', 1, { integer => 1, min => 1, max => 16, allowMember => 0 });
        $channel       = $result->{value};
        $valid_channel = $result->{valid};
    }
    my $valid_cc = 1;
    my $cc;
    if (exists $fields->{cc} || $mode == 5 || $mode == 6) {
        my $max_cc = $mode == 6 ? 31 : 127;
        my $result = _resolve_automation_number((exists $fields->{cc} ? $fields->{cc} : undef),
            $bindings, $depth, $call, 'cc', 1, { integer => 1, min => 0, max => $max_cc, allowMember => 0 });
        $cc       = $result->{value};
        $valid_cc = $result->{valid};
    }
    my $nrpn;
    if (exists $fields->{nrpn} || $mode == 7) {
        $valid_selection = 0 unless exists $fields->{nrpn};
        my $result = _resolve_automation_number((exists $fields->{nrpn} ? $fields->{nrpn} : undef),
            $bindings, $depth, $call, 'nrpn', undef, { integer => 1, min => 0, max => 16382, allowMember => 0 });
        $nrpn = $result->{value};
        $valid_selection = 0 unless $result->{valid};
    }
    my %number_options = (allowBoolean => 1, allowAutomation => 1);
    my %descriptor = (
        type    => 'Midi',
        channel => $channel,
        mode    => $mode,
        min     => _resolve_automation_number($fields->{min}, $bindings, $depth, $call, 'min', 0,
            { %number_options, clamp01 => 1 })->{value},
        max         => _resolve_automation_number($fields->{max}, $bindings, $depth, $call, 'max', 1,
            { %number_options, clamp01 => 1 })->{value},
        sensitivity => _resolve_automation_number($fields->{sensitivity}, $bindings, $depth, $call,
            'sensitivity', 1, \%number_options)->{value},
        name => $fields->{name},
        id   => $fields->{id},
    );
    $descriptor{cc}      = $cc    if defined $cc;
    $descriptor{nrpn}    = $nrpn  if defined $nrpn;
    $descriptor{zone}    = $zone  if $has_zone;
    $descriptor{members} = $members if exists $fields->{members};
    $descriptor{_invalid} = 1 if !$valid_cc || !$valid_channel || !$valid_selection;
    return \%descriptor;
}

sub _compile_audio {
    my ($call, $bindings, $depth) = @_;
    my $loc = $call->{loc};
    if ($depth > MAX_AUTOMATION_DEPTH) {
        _throw("Automation nesting exceeds the maximum depth of " . MAX_AUTOMATION_DEPTH, $loc);
    }
    my $fields = _automation_fields($call, $bindings, \@_AUDIO_POSITIONAL, \@_AUDIO_KEYWORD_ONLY,
        { min => 0, max => 1 });
    if (!exists $fields->{band}) {
        _throw('Missing required parameter "band" for audio()', $loc);
    }
    if (exists $fields->{id} && !exists $fields->{name}) {
        _throw('Missing required parameter "name" for audio()', $loc);
    }
    if (exists $fields->{name} && !exists $fields->{channel}) {
        _throw('Missing required parameter "channel" for audio()', $loc);
    }
    _check_selector_strings($call, $fields);
    my %audio_bands = map { $_ => 1 } (0 .. 4);
    my $band = _resolve_automation_enum($fields->{band}, 'audioBand', undef, \%audio_bands, $call, 'band');
    # Upstream audio fields reject booleans and reject dotted enum members.
    my %number_options = (allowAutomation => 1, allowMember => 0, clamp01 => 1);
    my $min = _resolve_automation_number($fields->{min}, $bindings, $depth, $call, 'min', 0, \%number_options);
    my $max = _resolve_automation_number($fields->{max}, $bindings, $depth, $call, 'max', 1, \%number_options);
    my $channel;
    my $valid_channel = 1;
    if (exists $fields->{channel}) {
        my $node = $fields->{channel};
        if (_is_number($node)) {
            _throw('Parameter "channel" must be an integer', $loc) if $node != int($node);
            if ($node >= 1 && $node <= 32) { $channel = $node }
            else { $valid_channel = 0 }
        }
        elsif (!ref $node && defined $node) {
            _throw('Parameter "channel" must be an integer', $loc);
        }
        else {
            $valid_channel = 0;
        }
    }
    return {
        type     => 'Audio',
        band     => $band,
        min      => $min->{value},
        max      => $max->{value},
        channel  => $channel,
        name     => $fields->{name},
        id       => $fields->{id},
        _invalid => (!defined $band || !$min->{valid} || !$max->{valid} || !$valid_channel) ? 1 : 0,
    };
}

sub _compile_automation_call {
    my ($call, $bindings, $depth) = @_;
    return _compile_midi($call, $bindings, $depth) if ($call->{name} // '') eq 'midi';
    return _compile_audio($call, $bindings, $depth) if ($call->{name} // '') eq 'audio';
    return _compile_oscillator($call, $bindings, $depth);
}

sub _evaluate_value {
    my ($value, $bindings, $osc_depth) = @_;
    $osc_depth = 0 unless defined $osc_depth;
    if (ref $value eq 'ARRAY') {
        return [map { _evaluate_value($_, $bindings, $osc_depth) } @$value];
    }
    if (!ref $value && ($value eq 'true' || $value eq 'false')) {
        # A boolean literal lowers to 1/0 where a raw value is consumed
        # (effect args, let bindings, osc() number fields).
        return $value eq 'true' ? 1 : 0;
    }
    return $value unless ref $value eq 'HASH';
    my $kind = defined $value->{kind} ? $value->{kind} : '';
    if ($kind eq 'surface') { return $value }
    if ($kind eq 'Call') {
        if ($value->{name} eq 'midi') { return _compile_midi($value, $bindings, $osc_depth) }
        if ($value->{name} eq 'audio') { return _compile_audio($value, $bindings, $osc_depth) }
        if ($value->{name} eq 'osc') { return _compile_oscillator($value, $bindings, $osc_depth) }
        _throw("Unsupported DSL value $kind \"$value->{name}\"", $value->{loc});
    }
    if ($kind eq 'identifier') {
        my $name = $value->{name};
        if (exists $bindings->{$name}) {
            my $binding = $bindings->{$name};
            _throw("Effect partial \"$name\" cannot be used as a value", $value->{loc})
                if $binding->{kind} eq 'partial';
            return $binding->{value};
        }
        return $name;
    }
    if ($kind eq 'vector') {
        my $components = [map { _evaluate_value($_, $bindings) } @{ $value->{values} }];
        my $width = $value->{width};
        if (@$components != $width || grep { !_is_number($_) } @$components) {
            _throw("vec$width requires $width numeric values", $value->{loc});
        }
        return $components;
    }
    if ($kind eq 'unary') {
        my $operand = _evaluate_value($value->{argument}, $bindings);
        _throw('Unary arithmetic requires a number', $value->{loc}) unless _is_number($operand);
        return $value->{operator} eq '-' ? -$operand : $operand;
    }
    if ($kind eq 'binary') {
        my $left  = _evaluate_value($value->{left},  $bindings);
        my $right = _evaluate_value($value->{right}, $bindings);
        _throw('Arithmetic requires numeric values', $value->{loc})
            unless _is_number($left) && _is_number($right);
        my $operator = $value->{operator};
        return $left + $right if $operator eq '+';
        return $left - $right if $operator eq '-';
        return $left * $right if $operator eq '*';
        return $left / $right;
    }
    _throw("Unsupported DSL value $kind", $value->{loc});
}

sub _resolve_args {
    my ($args, $bindings) = @_;
    return [map { { %$_, value => _evaluate_value($_->{value}, $bindings) } } @$args];
}

sub _merge_partial {
    my ($stored, $call) = @_;
    if (!$stored->{argMode}) {
        return { %$call, name => $stored->{name} };
    }
    if (!$call->{argMode}) {
        return { %$stored, loc => $call->{loc} };
    }
    if ($stored->{argMode} ne $call->{argMode}) {
        _throw('Partial and call arguments must use the same named or positional form', $call->{loc});
    }
    if ($stored->{argMode} eq 'positional') {
        return { %$call, name => $stored->{name}, args => [@{ $stored->{args} }, @{ $call->{args} }] };
    }
    # Named merge preserves Python dict-update order: stored names first (a
    # re-supplied name keeps its slot, value overridden), new names appended.
    my (%merged, @order);
    for my $arg (@{ $stored->{args} }, @{ $call->{args} }) {
        push @order, $arg->{name} unless exists $merged{ $arg->{name} };
        $merged{ $arg->{name} } = $arg;
    }
    return { %$call, name => $stored->{name}, args => [map { $merged{$_} } @order], argMode => 'named' };
}

sub _resolve_effect {
    my ($func, $search, $effects) = @_;
    for my $namespace (@$search) {
        my $effect_id = "$namespace/$func";
        return $effect_id if exists $effects->{$effect_id};
    }
    return undef;
}

# Lower a surface argument (or a param's own default) to an evaluator
# binding: undef means leave unbound (a blank 1x1, matching JS emptySurface),
# '@current' binds the chain's current image, ['surface', 'oN'] a named
# surface.
sub _surface_marker {
    my ($value, $name, $loc) = @_;
    return undef if !defined $value || (!ref $value && $value eq 'none');
    return '@current' if !ref $value && $value eq 'inputTex';
    return ['surface', $value->{name}] if _is_surface($value);
    _throw("Parameter \"$name\" must be a surface reference", $loc);
}

# Map a call's arguments onto the effect's params, splitting value params
# (handed to render_effect) from surface bindings. Value validation happens
# in the renderer before coercion; unknown parameter names are rejected here.
# Catalog slider ranges remain UI hints. paramOrder stands in for
# Python's list(param_specs.keys()) (see module header).
sub _normalize_effect {
    my ($effect_id, $spec, $args) = @_;
    my $param_specs = $spec->{params};
    my $param_names = $spec->{paramOrder};
    my $named = (@$args && defined $args->[0]{name}) ? 1 : 0;
    my (%params, %surfaces, %provided);
    for my $index (0 .. $#$args) {
        my $arg = $args->[$index];
        my $supplied =
              $named                 ? $arg->{name}
            : $index < @$param_names ? $param_names->[$index]
            :                          undef;
        if (!defined $supplied || $supplied eq '' || !exists $param_specs->{$supplied}) {
            my $bad = (defined $supplied && $supplied ne '') ? $supplied : 'argument ' . ($index + 1);
            _throw("Unknown parameter \"$bad\" for $effect_id; accepted: " . join(', ', @$param_names),
                $arg->{loc});
        }
        next if _is_unsupported_input($arg->{value});
        $provided{$supplied} = 1;
        my $pspec = $param_specs->{$supplied};
        if (ref $pspec eq 'HASH' && defined $pspec->{type} && $pspec->{type} eq 'surface') {
            my $marker = _surface_marker($arg->{value}, $supplied, $arg->{loc});
            $surfaces{$supplied} = $marker if defined $marker;
        }
        else {
            $params{$supplied} = $arg->{value};
        }
    }
    for my $name (@$param_names) {
        my $pspec = $param_specs->{$name};
        next unless ref $pspec eq 'HASH' && defined $pspec->{type} && $pspec->{type} eq 'surface';
        next if $provided{$name} || !exists $pspec->{default};
        my $marker = _surface_marker($pspec->{default}, $name, undef);
        $surfaces{$name} = $marker if defined $marker;
    }
    return (\%params, \%surfaces);
}

sub _volume_references {
    my ($call) = @_;
    return undef if ($call->{argMode} // '') ne 'positional' || @{ $call->{args} } != 2;
    my @names;
    for my $arg (@{ $call->{args} }) {
        my $value = $arg->{value};
        if (ref $value eq 'HASH' && $value->{kind} eq 'surface') {
            push @names, $value->{name};
        }
        elsif (ref $value eq 'HASH' && ($value->{kind} // '') eq 'identifier' && index($value->{name}, '.') < 0) {
            push @names, $value->{name};
        }
        else {
            return undef;
        }
    }
    return \@names;
}

sub _read3d_references {
    my ($call) = @_;
    return _volume_references($call) if ($call->{argMode} // '') ne 'named';
    my %named = map { $_->{name} => $_ } @{ $call->{args} };
    return undef unless exists $named{tex3d} && exists $named{geo};
    return _volume_references({
        argMode => 'positional',
        args    => [ $named{tex3d}, $named{geo} ],
    });
}

sub _compile_chain {
    my ($chain, $bindings, $search, $effects) = @_;
    my @steps;
    my $has_input             = 0;
    my $has_image             = 0;
    my $has_volume            = 0;
    my $starts_with_generator = 0;
    my $open_loop;
    my $calls = $chain->{calls};
    # A subchain block contributes its body calls in place. Upstream's validator
    # wraps them in `_subchain_begin`/`_subchain_end` markers, which its expander
    # passes through without a render pass; the body's calls take the subchain's
    # position and the following calls shift, as upstream's flatMap does.
    my @flat_calls;
    my $pos = 0;
    while ($pos <= $#$calls) {
        my $call = $calls->[ $pos++ ];
        if (($call->{kind} // '') eq 'Subchain') {
            my $binding = $bindings->{ $call->{name} };
            if (defined $binding) {
                _throw("Binding \"$call->{name}\" is not callable", $call->{loc})
                    unless $binding->{kind} eq 'partial';
                $call = _merge_partial($binding->{call}, $call);
            }
            splice @$calls, $pos, 0, @{ $call->{body} };
            next;
        }
        push @flat_calls, $call;
    }
    $calls = \@flat_calls;
    for my $index (0 .. $#$calls) {
        my $call = $calls->[$index];
        my $binding = $bindings->{ $call->{name} };
        if (defined $binding) {
            _throw("Binding \"$call->{name}\" is not callable", $call->{loc})
                unless $binding->{kind} eq 'partial';
            $call = _merge_partial($binding->{call}, $call);
        }
        my $args = _resolve_args($call->{args}, $bindings);
        if ($call->{name} eq 'read') {
            if ($index != 0 || @$args != 1 || !_is_surface($args->[0]{value})) {
                _throw('read(surface) must begin a chain', $call->{loc});
            }
            push @steps, { kind => 'read', surface => $args->[0]{value}{name}, loc => $call->{loc} };
            $has_input = 1;
            $has_image = 1;
            next;
        }
        if ($call->{name} eq 'write') {
            _throw('loopBegin must be closed by loopEnd before write', $call->{loc}) if $open_loop;
            if (!$has_image || @$args != 1 || !_is_surface($args->[0]{value})) {
                _throw('write(surface) requires a current image', $call->{loc});
            }
            push @steps, { kind => 'write', surface => $args->[0]{value}{name}, loc => $call->{loc} };
            next;
        }
        # Built-in volume I/O (upstream `_write3d` and `_read3d`). write3d stores the
        # current volume and geometry under the two names and passes the chain through;
        # read3d starts a chain from them. A mid-chain read3d() is not a starter, so it
        # fails below as an unknown effect, as a one-argument read3d() at a chain start
        # does.
        if ($call->{name} eq 'write3d') {
            # Upstream's lexer reserves write3d, so it cannot start a chain.
            _throw('Expected effect or IO function name', $call->{loc}) if $index == 0;
            _throw('loopBegin must be closed by loopEnd before write', $call->{loc}) if $open_loop;
            my $references = _volume_references($call);
            _throw('Expected surface reference', $call->{loc}) unless $references;
            push @steps, {
                kind     => 'write3d',
                volume   => $references->[0],
                geometry => $references->[1],
                loc      => $call->{loc},
            };
            next;
        }
        if ($index == 0 && $call->{name} eq 'read3d' && (my $references = _read3d_references($call))) {
            push @steps, {
                kind     => 'read3d',
                volume   => $references->[0],
                geometry => $references->[1],
                loc      => $call->{loc},
            };
            $has_input = 1;
            $has_volume = 1;
            $has_image = 1;
            next;
        }
        my $effect_id = _resolve_effect($call->{name},
            $call->{namespace} ? [ $call->{namespace} ] : $search, $effects);
        if (!defined $effect_id) {
            _throw("Unknown effect \"$call->{name}\" in search namespaces " . join(', ', @$search),
                $call->{loc});
        }
        my $spec = $effects->{$effect_id};
        my $domain = $spec->{domain} || 'image';
        if ($domain eq 'volume-generator') {
            if ($index != 0 && !($spec->{iterated} && $has_volume)) {
                _throw("Generator $effect_id must begin a chain", $call->{loc});
            }
            $starts_with_generator = 1 if $index == 0;
            $has_input  = 1;
            $has_volume = 1;
        }
        elsif ($domain eq 'volume-filter') {
            _throw("volume filter $effect_id requires a volume input", $call->{loc}) unless $has_volume;
            $has_input = 1;
        }
        elsif ($domain eq 'volume-renderer') {
            _throw("volume renderer $effect_id requires a volume input", $call->{loc}) unless $has_volume;
            $has_input = 1;
            $has_image = 1;
        }
        elsif ($domain eq 'loop-begin') {
            _throw("$effect_id requires a current image", $call->{loc}) unless $has_image;
            _throw('nested loopBegin regions are not supported', $call->{loc}) if $open_loop;
            $open_loop = $call->{loc};
        }
        elsif ($domain eq 'loop-end') {
            _throw('loopEnd has no matching loopBegin', $call->{loc}) unless $open_loop;
            _throw("$effect_id requires a current image", $call->{loc}) unless $has_image;
            $open_loop = undef;
        }
        elsif ($spec->{kind} eq 'generator') {
            _throw("Generator $effect_id must begin a chain", $call->{loc}) if $index != 0;
            $starts_with_generator = 1;
            $has_input             = 1;
            $has_image             = 1;
        }
        elsif (!$has_image) {
            my $requires_input_tex = 0;
            for my $p (@{ $spec->{passes} }) {
                my @sources = values %{ $p->{inputs} || {} };
                $requires_input_tex = 1, last if grep { defined $_ && $_ eq 'inputTex' } @sources;
            }
            if ($requires_input_tex) {
                _throw("$spec->{kind} $effect_id requires an input; begin with a generator or read(oN)",
                    $call->{loc});
            }
            $has_input = 1;
            $has_image = 1;
        }
        my ($params, $surfaces) = _normalize_effect($effect_id, $spec, $args);
        push @steps, {
            kind      => 'effect',
            effect_id => $effect_id,
            params    => $params,
            surfaces  => $surfaces,
            loc       => $call->{loc},
        };
    }
    _throw('loopBegin must be closed by loopEnd before the chain ends', $open_loop) if $open_loop;
    if ($starts_with_generator && (!@steps || $steps[-1]{kind} ne 'write')) {
        _throw('Generator chain must end with write(oN)', $chain->{loc});
    }
    return { steps => \@steps, loc => $chain->{loc} };
}

sub compile_dsl {
    my ($source, $effects, $options) = @_;
    $options = {} unless defined $options;
    my $ast = parse_dsl($source, $options);
    _throw('Missing required search directive', $ast->{loc}) if !@{ $ast->{search} };

    my %bindings;
    for my $binding (@{ $ast->{bindings} }) {
        _throw("Duplicate binding \"$binding->{name}\"", $binding->{loc})
            if exists $bindings{ $binding->{name} };
        my $value = $binding->{value};
        if (ref $value eq 'HASH' && defined $value->{kind} && $value->{kind} eq 'Call'
            && $value->{name} !~ /\A(?:osc|midi|audio)\z/) {
            $bindings{ $binding->{name} } = {
                kind => 'partial',
                call => { %$value, args => _resolve_args($value->{args}, \%bindings) },
            };
        }
        else {
            $bindings{ $binding->{name} } = { kind => 'value', value => _evaluate_value($value, \%bindings) };
        }
    }

    my @chains = map { _compile_chain($_, \%bindings, $ast->{search}, $effects) } @{ $ast->{chains} };

    my $last_written;
    for my $chain (@chains) {
        for my $step (@{ $chain->{steps} }) {
            $last_written = $step->{surface} if $step->{kind} eq 'write';
        }
    }
    my $render_surface = $ast->{render} ? $ast->{render}{name} : $last_written;
    if (!defined $render_surface) {
        _throw('No render surface specified and no write() found - add render(oN) or write(oN)', $ast->{loc});
    }

    return {
        search         => [@{ $ast->{search} }],
        chains         => \@chains,
        render_surface => $render_surface,
    };
}

# ---- diagnostic error object ----

package Math::Fractal::Noisemaker::DSL::Error;

# Exception object thrown by every tokenizer/parser/compiler diagnostic —
# port of dsl/error.py DslError (a SyntaxError subclass in Python).
# Stringifies as "<sourceName>:<line>:<column>: <message>\n" so an uncaught
# die prints the located diagnostic like the Python SyntaxError text.

use overload
    '""'     => sub { $_[0]->{message} },
    fallback => 1;

sub new {
    my ($class, $message, $location) = @_;
    $location = {} unless ref $location eq 'HASH';
    my $source_name = defined $location->{sourceName} ? $location->{sourceName} : '<dsl>';
    my $line        = defined $location->{line}       ? $location->{line}       : 1;
    my $column      = defined $location->{column}     ? $location->{column}     : 1;
    return bless {
        message     => "$source_name:$line:$column: $message\n",
        source_name => $source_name,
        line        => $line,
        column      => $column,
    }, $class;
}

sub throw { my $class = shift; die $class->new(@_) }

sub message     { $_[0]{message} }
sub source_name { $_[0]{source_name} }
sub line        { $_[0]{line} }
sub column      { $_[0]{column} }

1;

__END__

=head1 NAME

Math::Fractal::Noisemaker::DSL - parse and compile Polymorphic compositions

=head1 SYNOPSIS

    use Math::Fractal::Noisemaker::DSL qw(compile_dsl);
    use Math::Fractal::Noisemaker::Renderer qw(meta);
    my $plan = compile_dsl(
        "search synth, filter\nnoise(seed: 3).invert().write(o0)\nrender(o0)",
        meta()->{effects},
        {sourceName => 'example.dsl'},
    );

=head1 FUNCTIONS

C<tokenize_dsl>, C<parse_dsl>, and C<compile_dsl> are optional exports.

=head2 tokenize_dsl($source, $options)

Returns an array reference of tokens with type, lexeme, value, and source
location fields. C<$options> is an optional hash with C<sourceName> for errors.

=head2 parse_dsl($source, $options)

Returns the parsed syntax tree. Accepts the same source and options as the
tokenizer. Token and syntax-tree internals may change; most callers should
use C<compile_dsl> or C<Renderer::render_dsl>.

=head2 compile_dsl($source, $effects, $options)

C<$effects> is the catalog's C<effects> hash. Returns a plan containing
C<search> (namespace array), C<chains> (compiled chains), and C<render_surface>
(output name). Compilation checks names, arguments, and chain domains;
effect parameter values are validated when the renderer runs the plan.
Compilation neither executes kernels nor performs network I/O.

=head1 LANGUAGE

C<search synth, filter> selects effect namespaces. Dotted calls compose
effects; keyword arguments use C<name: value>. C<write(o0)> stores an image;
C<read(o0)> begins a chain from a previously written or seeded image.
C<render(o0)> selects the final image. Names C<o0> through C<o7> are available.
Values include numbers, booleans, quoted strings, colors, vectors, and named
enum choices. C<let> binds reusable values or partial effect calls.

Numeric parameters accept C<osc(kind, min?, max?, speed?, offset?, seed?)>
automation values, evaluated against the render's normalized C<time> on every
render: C<kind> is one of C<sine>, C<tri>, C<saw>, C<sawInv>, C<square>,
C<noise>/C<noise1d>, or C<noise2d>, fields may nest further C<osc(...)> values,
and the resolved number scales into the parameter's declared range (integer
choice selectors round, matching the upstream contract).

=head1 ERRORS

Syntax and compilation failures throw C<Math::Fractal::Noisemaker::DSL::Error>
objects, which stringify as source name, line, column, and message. They expose
C<message>, C<source_name>, C<line>, and C<column> methods. Catch them with C<eval>;
ordinary argument errors may be plain string exceptions.

=cut
