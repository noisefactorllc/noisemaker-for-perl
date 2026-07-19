package Math::Fractal::Noisemaker::Transpiler::Parser;

# GLSL ES 3.00 recursive-descent parser -> clean AST.
#
# AST nodes are hashrefs with a "k" (kind) field. Consumes tokens from
# Lexer::tokenize on already-preprocessed GLSL.

use strict;
use warnings;
use Exporter 'import';

use Math::Fractal::Noisemaker::Transpiler::Lexer qw(tokenize);

our @EXPORT_OK = qw(parse);

my %SCALAR = map { $_ => 1 } qw(void bool int uint float);
my %VEC = map { $_ => 1 } map { my $p = $_; map {"${p}vec$_"} 2, 3, 4 } '', 'i', 'u', 'b';
my %MAT = map { $_ => 1 } (map {"mat$_"} 2, 3, 4), (map { my $a = $_; map {"mat${a}x$_"} 2, 3, 4 } 2, 3, 4);
my %SAMPLER = map { $_ => 1 } qw(sampler2D sampler3D samplerCube sampler2DArray);
our %TYPES = (%SCALAR, %VEC, %MAT, %SAMPLER);

my %QUALIFIERS = map { $_ => 1 } qw(
    const uniform in out inout flat smooth noperspective centroid invariant
    highp mediump lowp precise
);

my %ASSIGN = map { $_ => 1 } qw(= += -= *= /= %= &= |= ^= <<= >>=);

sub new {
    my ($class, $tokens) = @_;
    return bless { toks => $tokens, i => 0, struct_types => {} }, $class;
}

# ---- cursor ----
sub peek { $_[0]{toks}[ $_[0]{i} + (defined $_[1] ? $_[1] : 0) ] }
sub at   { $_[0]{toks}[ $_[0]{i} ]{value} eq $_[1] }

sub at_type {
    my ($self) = @_;
    my $t = $self->peek;
    return $t->{kind} eq 'id' && ($TYPES{ $t->{value} } || $self->{struct_types}{ $t->{value} });
}

sub next_tok {
    my ($self) = @_;
    my $t = $self->{toks}[ $self->{i} ];
    $self->{i}++;
    return $t;
}

sub expect {
    my ($self, $value) = @_;
    my $t = $self->{toks}[ $self->{i} ];
    die "expected '$value' got '$t->{value}' at token $self->{i}\n" if $t->{value} ne $value;
    $self->{i}++;
    return $t;
}

sub eat {
    my ($self, $value) = @_;
    if ($self->{toks}[ $self->{i} ]{value} eq $value) { $self->{i}++; return 1 }
    return 0;
}

# ---- top level ----
sub parse_program {
    my ($self) = @_;
    my @decls;
    until ($self->at('<eof>')) {
        my $d = $self->external_decl;
        push @decls, $d if defined $d;
    }
    return { k => 'program', decls => \@decls };
}

sub external_decl {
    my ($self) = @_;
    if ($self->at('precision')) {
        $self->next_tok until $self->eat(';');
        return undef;
    }
    return $self->struct_decl if $self->at('struct');
    my $quals = $self->qualifiers;
    # interface (uniform) block: `uniform Name { members } [inst];`
    if ((grep { $_ eq 'uniform' } @$quals) && $self->peek->{kind} eq 'id' && $self->peek(1)->{value} eq '{') {
        return $self->uniform_block;
    }
    my $typ  = $self->type_spec;
    my $name = $self->next_tok->{value};
    return $self->function_rest($typ, $name, $quals) if $self->at('(');
    return $self->var_decl_rest($typ, $name, $quals, 1);
}

sub uniform_block {
    my ($self) = @_;
    $self->next_tok;    # block type name (irrelevant without an instance)
    $self->expect('{');
    my @members;
    until ($self->at('}')) {
        $self->qualifiers;
        my $mtype = $self->type_spec;
        my $mname = $self->next_tok->{value};
        my $arr;
        if ($self->eat('[')) {
            $arr = $self->expr;
            $self->expect(']');
        }
        push @members, { type => $mtype, name => $mname, array => $arr };
        $self->expect(';');
    }
    $self->expect('}');
    my $inst;
    $inst = $self->next_tok->{value} if $self->peek->{kind} eq 'id';
    $self->expect(';');
    return { k => 'ubo', members => \@members, inst => $inst };
}

sub qualifiers {
    my ($self) = @_;
    my @q;
    while (1) {
        my $t = $self->peek;
        if ($t->{value} eq 'layout') {
            $self->next_tok;
            $self->expect('(');
            my $depth = 1;
            while ($depth) {
                my $v = $self->next_tok->{value};
                $depth++ if $v eq '(';
                $depth-- if $v eq ')';
            }
            next;
        }
        if ($t->{kind} eq 'id' && $QUALIFIERS{ $t->{value} }) {
            push @q, $self->next_tok->{value};
            next;
        }
        last;
    }
    return \@q;
}

sub type_spec { $_[0]->next_tok->{value} }

sub struct_decl {
    my ($self) = @_;
    $self->expect('struct');
    my $name = $self->next_tok->{value};
    $self->{struct_types}{$name} = 1;
    $self->expect('{');
    my @fields;
    until ($self->at('}')) {
        $self->qualifiers;
        my $ftype = $self->type_spec;
        my $fname = $self->next_tok->{value};
        my $arr;
        if ($self->eat('[')) {
            $arr = $self->expr;
            $self->expect(']');
        }
        push @fields, [$ftype, $fname, $arr];
        $self->expect(';');
    }
    $self->expect('}');
    my $inst;
    $inst = $self->next_tok->{value} if $self->peek->{kind} eq 'id';
    $self->expect(';');
    return { k => 'struct', name => $name, fields => \@fields, inst => $inst };
}

sub function_rest {
    my ($self, $ret, $name, $quals) = @_;
    $self->expect('(');
    my @params;
    if (!$self->at(')')) {
        while (1) {
            my $pquals = $self->qualifiers;
            if ($self->at('void') && $self->peek(1)->{value} eq ')') {
                $self->next_tok;
                last;
            }
            my $ptype = $self->type_spec;
            my $pname = $self->peek->{kind} eq 'id' ? $self->next_tok->{value} : undef;
            if ($self->eat('[')) {
                $self->expr;
                $self->expect(']');
            }
            push @params, [$ptype, $pname, $pquals];
            last unless $self->eat(',');
        }
    }
    $self->expect(')');
    if ($self->eat(';')) {    # prototype
        return { k => 'proto', ret => $ret, name => $name, params => \@params };
    }
    my $body = $self->block;
    return { k => 'func', ret => $ret, name => $name, params => \@params, body => $body };
}

sub var_decl_rest {
    my ($self, $typ, $name, $quals, $top) = @_;
    my @declarators;
    while (1) {
        my $arr;
        if ($self->eat('[')) {
            $arr = $self->at(']') ? 'unsized' : $self->expr;
            $self->expect(']');
        }
        my $init;
        $init = $self->assign_expr if $self->eat('=');
        push @declarators, { name => $name, array => $arr, init => $init };
        last unless $self->eat(',');
        $name = $self->next_tok->{value};
    }
    $self->expect(';');
    return { k => 'decl', type => $typ, quals => $quals, declarators => \@declarators, top => ($top ? 1 : 0) };
}

# ---- statements ----
sub block {
    my ($self) = @_;
    $self->expect('{');
    my @stmts;
    push @stmts, $self->statement until $self->at('}');
    $self->expect('}');
    return \@stmts;
}

sub statement {
    my ($self) = @_;
    my $t = $self->peek;
    return { k => 'block', body => $self->block } if $t->{value} eq '{';
    return $self->if_stmt  if $t->{value} eq 'if';
    return $self->for_stmt if $t->{value} eq 'for';
    if ($t->{value} eq 'while') {
        $self->next_tok;
        $self->expect('(');
        my $cond = $self->expr;
        $self->expect(')');
        return { k => 'while', cond => $cond, body => $self->statement };
    }
    if ($t->{value} eq 'do') {
        $self->next_tok;
        my $body = $self->statement;
        $self->expect('while');
        $self->expect('(');
        my $cond = $self->expr;
        $self->expect(')');
        $self->expect(';');
        return { k => 'dowhile', cond => $cond, body => $body };
    }
    if ($t->{value} eq 'return') {
        $self->next_tok;
        my $val = $self->at(';') ? undef : $self->expr;
        $self->expect(';');
        return { k => 'return', value => $val };
    }
    if ($t->{value} eq 'break')    { $self->next_tok; $self->expect(';'); return { k => 'break' } }
    if ($t->{value} eq 'continue') { $self->next_tok; $self->expect(';'); return { k => 'continue' } }
    if ($t->{value} eq 'discard')  { $self->next_tok; $self->expect(';'); return { k => 'discard' } }
    if ($self->at_decl_start) {
        my $quals = $self->qualifiers;
        my $typ   = $self->type_spec;
        my $name  = $self->next_tok->{value};
        return $self->var_decl_rest($typ, $name, $quals, 0);
    }
    my $e = $self->expr;
    $self->expect(';');
    return { k => 'expr', expr => $e };
}

sub at_decl_start {
    my ($self) = @_;
    my $t = $self->peek;
    return 0 if $t->{kind} ne 'id';
    return 1 if $QUALIFIERS{ $t->{value} };
    if ($TYPES{ $t->{value} } || $self->{struct_types}{ $t->{value} }) {
        # a type keyword followed by an ident (decl) or by `(` (constructor)
        return $self->peek(1)->{kind} eq 'id';
    }
    return 0;
}

sub if_stmt {
    my ($self) = @_;
    $self->next_tok;
    $self->expect('(');
    my $cond = $self->expr;
    $self->expect(')');
    my $then = $self->statement;
    my $els;
    $els = $self->statement if $self->eat('else');
    return { k => 'if', cond => $cond, then => $then, els => $els };
}

sub for_stmt {
    my ($self) = @_;
    $self->next_tok;
    $self->expect('(');
    my $init;
    if ($self->eat(';')) { $init = undef }
    elsif ($self->at_decl_start) {
        my $quals = $self->qualifiers;
        my $typ   = $self->type_spec;
        my $name  = $self->next_tok->{value};
        $init = $self->var_decl_rest($typ, $name, $quals, 0);
    }
    else {
        $init = { k => 'expr', expr => $self->expr };
        $self->expect(';');
    }
    my $cond = $self->at(';') ? undef : $self->expr;
    $self->expect(';');
    my $update = $self->at(')') ? undef : $self->expr;
    $self->expect(')');
    my $body = $self->statement;
    return { k => 'for', init => $init, cond => $cond, update => $update, body => $body };
}

# ---- expressions (precedence climbing) ----
sub expr {
    my ($self) = @_;
    my $e = $self->assign_expr;
    while ($self->at(',')) {    # comma operator: keep last
        $self->next_tok;
        $e = $self->assign_expr;
    }
    return $e;
}

sub assign_expr {
    my ($self) = @_;
    my $left = $self->conditional;
    if ($ASSIGN{ $self->peek->{value} }) {
        my $op    = $self->next_tok->{value};
        my $right = $self->assign_expr;
        return { k => 'assign', op => $op, target => $left, value => $right };
    }
    return $left;
}

sub conditional {
    my ($self) = @_;
    my $c = $self->binary_expr(0);
    if ($self->eat('?')) {
        my $a = $self->expr;
        $self->expect(':');
        my $b = $self->assign_expr;
        return { k => 'cond', c => $c, a => $a, b => $b };
    }
    return $c;
}

my @BIN = (
    { '||' => 1 },
    { '&&' => 1 },
    { '|'  => 1 },
    { '^'  => 1 },
    { '&'  => 1 },
    { '==' => 1, '!=' => 1 },
    { '<' => 1, '>' => 1, '<=' => 1, '>=' => 1 },
    { '<<' => 1, '>>' => 1 },
    { '+' => 1, '-' => 1 },
    { '*' => 1, '/' => 1, '%' => 1 },
);

sub binary_expr {
    my ($self, $level) = @_;
    return $self->unary_expr if $level >= @BIN;
    my $left = $self->binary_expr($level + 1);
    while ($BIN[$level]{ $self->peek->{value} }) {
        my $op    = $self->next_tok->{value};
        my $right = $self->binary_expr($level + 1);
        $left = { k => 'binary', op => $op, l => $left, r => $right };
    }
    return $left;
}

sub unary_expr {
    my ($self) = @_;
    my $t = $self->peek;
    if ($t->{value} =~ /^(?:\+|-|!|~|\+\+|--)$/) {
        $self->next_tok;
        return { k => 'unary', op => $t->{value}, x => $self->unary_expr };
    }
    return $self->postfix;
}

sub postfix {
    my ($self) = @_;
    my $e = $self->primary;
    while (1) {
        my $t = $self->peek;
        if ($t->{value} eq '.') {
            $self->next_tok;
            my $field = $self->next_tok->{value};
            if ($self->at('(') && $field eq 'length') {    # arr.length() -> array size
                $self->expect('(');
                $self->expect(')');
                $e = { k => 'call', name => '__array_length', args => [$e] };
            }
            else {
                $e = { k => 'member', obj => $e, field => $field };
            }
        }
        elsif ($t->{value} eq '[') {
            $self->next_tok;
            my $idx = $self->expr;
            $self->expect(']');
            $e = { k => 'index', obj => $e, idx => $idx };
        }
        elsif ($t->{value} eq '(') {
            $e = $self->call_rest($e);
        }
        elsif ($t->{value} eq '++' || $t->{value} eq '--') {
            $self->next_tok;
            $e = { k => 'post', op => $t->{value}, x => $e };
        }
        else { last }
    }
    return $e;
}

sub call_rest {
    my ($self, $callee) = @_;
    $self->expect('(');
    my @args;
    if (!$self->at(')')) {
        while (1) {
            push @args, $self->assign_expr;
            last unless $self->eat(',');
        }
    }
    $self->expect(')');
    my $name = ($callee->{k} && $callee->{k} eq 'id') ? $callee->{name} : $callee->{type};
    return { k => 'call', name => $name, args => \@args };
}

sub primary {
    my ($self) = @_;
    my $t = $self->peek;
    if ($t->{value} eq '(') {
        $self->next_tok;
        my $e = $self->expr;
        $self->expect(')');
        return $e;
    }
    if ($t->{kind} eq 'num') {
        $self->next_tok;
        return { k => 'num', value => $t->{value} };
    }
    if ($t->{value} eq 'true' || $t->{value} eq 'false') {
        $self->next_tok;
        return { k => 'bool', value => ($t->{value} eq 'true' ? 1 : 0) };
    }
    if ($t->{kind} eq 'id') {
        # constructor: TYPE(...) or TYPE[N](...)
        if (($TYPES{ $t->{value} } || $self->{struct_types}{ $t->{value} })
            && ($self->peek(1)->{value} eq '(' || $self->peek(1)->{value} eq '[')) {
            $self->next_tok;
            my $arr;
            if ($self->eat('[')) {
                $arr = $self->at(']') ? 'unsized' : $self->expr;
                $self->expect(']');
            }
            $self->expect('(');
            my @args;
            if (!$self->at(')')) {
                while (1) {
                    push @args, $self->assign_expr;
                    last unless $self->eat(',');
                }
            }
            $self->expect(')');
            return { k => 'construct', type => $t->{value}, array => $arr, args => \@args };
        }
        $self->next_tok;
        return { k => 'id', name => $t->{value} };
    }
    die "unexpected token '$t->{value}' at $self->{i}\n";
}

sub parse {
    my ($source_or_tokens) = @_;
    my $tokens = ref $source_or_tokens ? $source_or_tokens : tokenize($source_or_tokens);
    return __PACKAGE__->new($tokens)->parse_program;
}

1;
