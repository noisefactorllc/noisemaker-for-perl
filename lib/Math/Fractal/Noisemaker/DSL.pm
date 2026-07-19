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
use Scalar::Util ();
use Exporter 'import';

our @EXPORT_OK = qw(tokenize_dsl parse_dsl compile_dsl);

# JSON-style string quoting for diagnostic text, matching Python json.dumps
# (ascii mode mirrors ensure_ascii=True) so error messages stay byte-equal.
my $_JSON_STR = JSON::PP->new->allow_nonref->ascii;

sub _jq { $_JSON_STR->encode(defined $_[0] ? "$_[0]" : '') }

# Every internal diagnostic goes through the located error object below.
sub _throw { Math::Fractal::Noisemaker::DSL::Error->throw(@_) }

# ---- tokenizer (port of dsl/tokenizer.py tokenize_dsl) ----

my %KEYWORDS    = map { $_ => 1 } qw(search let render true false);
my %PUNCTUATION = map { $_ => 1 } split //, '()[],.:=;';
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
            push @{ $ast->{search} }, $self->identifier('Expected namespace after search')->{lexeme};
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
        push @$calls, $self->parse_call;
    }
    return { kind => 'Chain', calls => $calls, loc => $first->{loc} };
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
            _throw('Cannot mix positional and named arguments', _location($self->peek))
                if defined $mode && $mode ne $next_mode;
            $mode = $next_mode;
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
    return { kind => 'Call', name => $name->{lexeme}, args => \@args, argMode => $mode, loc => _location($name) };
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
        # Python returns bool; Perl has none, so true/false lower to 1/0.
        $self->{current}++;
        return $token->{lexeme} eq 'true' ? 1 : 0;
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
    if ($token->{type} eq 'identifier') {
        $self->{current}++;
        my $name = $token->{lexeme};
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
    return Scalar::Util::looks_like_number($value) ? 1 : 0;
}

sub _is_surface {
    my ($value) = @_;
    return ref $value eq 'HASH' && defined $value->{kind} && $value->{kind} eq 'surface' ? 1 : 0;
}

sub _evaluate_value {
    my ($value, $bindings) = @_;
    if (ref $value eq 'ARRAY') {
        return [map { _evaluate_value($_, $bindings) } @$value];
    }
    return $value unless ref $value eq 'HASH';
    my $kind = defined $value->{kind} ? $value->{kind} : '';
    if ($kind eq 'surface') { return $value }
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
# (handed to render_effect) from surface bindings. Like the Python port (and
# unlike JS normalizeArguments) this does NOT validate value
# type/range/enum-membership here; render_effect's _coerce performs the
# coercion and fills defaults, so malformed values render leniently while
# unknown parameter NAMES are still rejected. paramOrder stands in for
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

sub _compile_chain {
    my ($chain, $bindings, $search, $effects) = @_;
    my @steps;
    my $has_input             = 0;
    my $starts_with_generator = 0;
    my $calls = $chain->{calls};
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
            next;
        }
        if ($call->{name} eq 'write') {
            if (!$has_input || @$args != 1 || !_is_surface($args->[0]{value})) {
                _throw('write(surface) requires a current image', $call->{loc});
            }
            push @steps, { kind => 'write', surface => $args->[0]{value}{name}, loc => $call->{loc} };
            next;
        }
        my $effect_id = _resolve_effect($call->{name}, $search, $effects);
        if (!defined $effect_id) {
            _throw("Unknown effect \"$call->{name}\" in search namespaces " . join(', ', @$search),
                $call->{loc});
        }
        my $spec = $effects->{$effect_id};
        if ($spec->{kind} eq 'generator') {
            _throw("Generator $effect_id must begin a chain", $call->{loc}) if $index != 0;
            $starts_with_generator = 1;
            $has_input             = 1;
        }
        elsif (!$has_input) {
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
        if (ref $value eq 'HASH' && defined $value->{kind} && $value->{kind} eq 'Call') {
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
