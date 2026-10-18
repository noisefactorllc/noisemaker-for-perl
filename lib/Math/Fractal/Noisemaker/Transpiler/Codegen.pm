package Math::Fractal::Noisemaker::Transpiler::Codegen;

# GLSL AST -> Perl kernel source.
#
# Emits a kernel file whose last expression is `{ kernel => $run_pixel,
# uses_derivatives => 0|1 }` where $run_pixel is a coderef called as
# $kernel->($ctx, $out). The kernel calls the Math::Fractal::Noisemaker
# Runtime ($ctx->rt) with the SAME primitive sequence the (parity-proven)
# Python codegen emits, so the float model carries over op-for-op.
#
# Perl-specific emission notes:
# - Python locals are function-scoped; Perl `my` is block-scoped. All body
#   locals are therefore hoisted into one `my (...)` at function top, and
#   the body emits plain assignments — matching Python's semantics exactly
#   (including its deliberate conflation of GLSL shadowed redeclarations).
# - In-place vector reassignment (`x[:] = rhs` in Python) is emitted as
#   `@{$x} = @{rhs}`, preserving JS pooled-array aliasing (`prevUV = rayUV`
#   tracks later updates — the parallax fix).
# - Nested GLSL functions become closures assigned to predeclared lexicals,
#   so declaration order never breaks calls and all of them close over the
#   uniforms/globals of the enclosing run_pixel invocation.

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(emit_perl);

our %TYPE = (
    void  => { base => 'void',  width => 0 },
    bool  => { base => 'bool',  width => 1 },
    int   => { base => 'int',   width => 1 },
    uint  => { base => 'uint',  width => 1 },
    float => { base => 'float', width => 1 },
    vec2  => { base => 'float', width => 2 },
    vec3  => { base => 'float', width => 3 },
    vec4  => { base => 'float', width => 4 },
    ivec2 => { base => 'int',   width => 2 },
    ivec3 => { base => 'int',   width => 3 },
    ivec4 => { base => 'int',   width => 4 },
    uvec2 => { base => 'uint',  width => 2 },
    uvec3 => { base => 'uint',  width => 3 },
    uvec4 => { base => 'uint',  width => 4 },
    bvec2 => { base => 'bool',  width => 2 },
    bvec3 => { base => 'bool',  width => 3 },
    bvec4 => { base => 'bool',  width => 4 },
    mat2  => { base => 'float', width => 4,  mat => 2 },
    mat3  => { base => 'float', width => 9,  mat => 3 },
    mat4  => { base => 'float', width => 16, mat => 4 },
    sampler2D      => { base => 'sampler', width => 0 },
    sampler3D      => { base => 'sampler', width => 0 },
    samplerCube    => { base => 'sampler', width => 0 },
    sampler2DArray => { base => 'sampler', width => 0 },
);
my $FLOAT = $TYPE{float};
my $BOOL  = $TYPE{bool};
my $VEC4  = $TYPE{vec4};

# Preserve the existing effect-scoped JS uint coercion and guarded reads.
# Integer division restoration is independent of this runtime flag.
my %JS_UINT_MODEL = map { $_ => 1 } qw(filter/spookyTicker);

sub base_of  { my ($t) = @_; ($t && $t->{base}) ? $t->{base} : 'float' }
sub width_of { my ($t) = @_; ($t && $t->{width}) ? $t->{width} : 1 }
sub _uses_js_uint_model { $JS_UINT_MODEL{$_[0]{effect_id} || q{}} ? 1 : 0 }

sub pq {    # single-quoted Perl string literal
    my ($s) = @_;
    $s = "$s";
    $s =~ s/([\\'])/\\$1/g;
    return "'$s'";
}

sub _fmt_num {
    my $v = 0 + $_[0];
    my $s = sprintf('%.17g', $v);
    return $s;
}

# Names that would collide with emitted-kernel infrastructure lexicals.
my %RESERVED = map { $_ => 1 } qw(rt g U T ctx out kernel run_pixel);

sub p_ident {
    my ($name) = @_;
    return $RESERVED{$name} ? "_$name" : $name;
}

sub _construct_base {
    my ($t) = @_;
    return ($t && ($t->{base} eq 'int' || $t->{base} eq 'uint')) ? ', ' . pq($t->{base}) : '';
}

# ---- scope ----

package Math::Fractal::Noisemaker::Transpiler::Codegen::Scope;

sub new {
    my ($class, $parent) = @_;
    return bless { parent => $parent, vars => {} }, $class;
}
sub child { (ref $_[0])->new($_[0]) }

sub define {
    my ($self, $name, $typ, $pyname) = @_;
    my $entry = {
        py => (defined $pyname ? $pyname : '$' . Math::Fractal::Noisemaker::Transpiler::Codegen::p_ident($name)),
        type => $typ,
        declared_type => $typ,
    };
    $self->{vars}{$name} = $entry;
    return $entry;
}

sub resolve {
    my ($self, $name) = @_;
    my $s = $self;
    while ($s) {
        return $s->{vars}{$name} if exists $s->{vars}{$name};
        $s = $s->{parent};
    }
    return undef;
}

package Math::Fractal::Noisemaker::Transpiler::Codegen;

sub new {
    my ($class, $program, $outputs, $varyings, $effect_id, $options) = @_;
    $options ||= {};
    my $self = bless {
        program   => $program,
        constant_divisors => $options->{constant_divisors} || {},
        int_names => $program->{integer_names} || {},
        effect_id => $effect_id,
        outputs   => ($outputs && @$outputs) ? $outputs : ['fragColor'],
        varyings  => { map { $_ => 1 } @{ $varyings || [] } },
        root      => Math::Fractal::Noisemaker::Transpiler::Codegen::Scope->new(undef),
        overloads => {},
        funcs     => [],
        uniforms  => [],
        globals   => [],
        structs   => {},
        loop_id   => 0,
        uses_deriv => 0,
        cur_out   => [],
        declared  => undef,    # per-function set of hoisted local names
        unused_n  => 0,
    }, $class;
    return $self;
}

# ---- collect ----

sub collect {
    my ($self) = @_;
    for my $d (@{ $self->{program}{decls} }) {
        if ($d->{k} eq 'struct') {
            $self->{structs}{ $d->{name} } = [map { [$_->[0], $_->[1]] } @{ $d->{fields} }];
        }
        elsif ($d->{k} eq 'func')  { $self->_collect_func($d) }
        elsif ($d->{k} eq 'proto') { }
        elsif ($d->{k} eq 'decl')  { $self->_collect_decl($d) }
        elsif ($d->{k} eq 'ubo') {
            # Anonymous std140 block members are addressed like bare uniforms.
            for my $m (@{ $d->{members} }) {
                push @{ $self->{uniforms} },
                    { name => $m->{name}, type => $self->type_of_name($m->{type}, $m->{array}) };
            }
        }
    }
}

sub type_of_name {
    my ($self, $tname, $array) = @_;
    my $t = { %{ $TYPE{$tname} || { base => 'float', width => 1 } } };
    if ($self->{structs}{$tname}) {
        $t = { base => 'struct', width => 0, struct => $tname };
    }
    if (defined $array) {
        $t = {%$t};
        $t->{array} = 1;
    }
    return $t;
}

sub _collect_func {
    my ($self, $d) = @_;
    my $ret    = $self->type_of_name($d->{ret});
    my @ptypes = map { $self->type_of_name($_->[0]) } @{ $d->{params} };
    my @out_idxs;
    for my $i (0 .. $#{ $d->{params} }) {
        my $p = $d->{params}[$i];
        push @out_idxs, $i
            if $p->[2] && grep { $_ eq 'out' || $_ eq 'inout' } @{ $p->[2] };
    }
    my $mangled = p_ident($d->{name}) . '__'
        . (@ptypes ? join('_', map { _type_name($_) } @ptypes) : 'void');
    my $entry = { mangled => $mangled, ptypes => \@ptypes, ret => $ret, node => $d, out_idxs => \@out_idxs };
    push @{ $self->{funcs} }, $entry;
    push @{ $self->{overloads}{ $d->{name} } ||= [] }, $entry;
}

sub _collect_decl {
    my ($self, $d) = @_;
    my $quals = $d->{quals} || [];
    if (grep { $_ eq 'uniform' } @$quals) {
        for my $dc (@{ $d->{declarators} }) {
            push @{ $self->{uniforms} }, { name => $dc->{name}, type => $self->type_of_name($d->{type}) };
        }
    }
    else {
        for my $dc (@{ $d->{declarators} }) {
            push @{ $self->{globals} },
                {
                name  => $dc->{name},
                type  => $self->type_of_name($d->{type}, $dc->{array}),
                init  => $dc->{init},
                array => $dc->{array},
                constant => scalar(grep { $_ eq 'const' } @$quals),
                };
        }
    }
}

# ---- emit ----

sub emit {
    my ($self) = @_;
    $self->collect;
    for my $u (@{ $self->{uniforms} }) {
        my $entry = $self->{root}->define($u->{name}, $u->{type}, '$_u_' . p_ident($u->{name}));
        $entry->{division_kind} = exists $self->{constant_divisors}{$u->{name}} ? 'constant' : 'runtime';
    }
    for my $g (@{ $self->{globals} }) {
        my $py = $self->{varyings}{ $g->{name} } ? '$ctx->{uv}' : '$g->{' . p_ident($g->{name}) . '}';
        my $entry = $self->{root}->define($g->{name}, $g->{type}, $py);
        $entry->{division_kind} = $g->{constant} ? 'constant' : undef;
        $entry->{initializer} = $g->{init};
    }

    my @L = (
        'my $run_pixel = sub {',
        '    my ($ctx, $out) = @_;',
        '    my $rt = $ctx->rt;',
        '    my $U = $ctx->uniforms;',
        '    my $g = {};',
    );
    # The %JS_UINT_MODEL effects run the oracle's transpiled-JS op
    # semantics (see the hash table comment): scalar uint bitwise ops coerce
    # through ToInt32 in the runtime. local() scopes the flag to this kernel's
    # dynamic extent, so sibling kernels in the same render are unaffected.
    push @L, '    local $rt->{js_native_ints} = 1;' if $self->_uses_js_uint_model;
    my @fn_lexicals = map { '$' . $_->{mangled} } @{ $self->{funcs} };
    push @L, '    my (' . join(', ', @fn_lexicals) . ');' if @fn_lexicals;
    push @L, '    my $_retc;';
    for my $u (@{ $self->{uniforms} }) {
        my $n = p_ident($u->{name});
        if (base_of($u->{type}) eq 'sampler') {
            push @L, "    my \$_u_$n = \$ctx->texture_binding(" . pq($u->{name}) . ');';
        }
        else {
            # WebGL zero-initializes unbound uniforms; default absent ones.
            push @L,
                  "    my \$_u_$n = exists \$U->{" . pq($u->{name}) . "} ? \$U->{" . pq($u->{name}) . '} : '
                . $self->_default($u->{type}) . ';';
        }
    }
    for my $g (@{ $self->{globals} }) {
        next if $self->{varyings}{ $g->{name} };
        my $code;
        if (defined $g->{init}) {
            ($code) = $self->expr($g->{init}, $self->{root});
        }
        elsif (defined $g->{array}) {
            my $n_code = (ref $g->{array}) ? ($self->expr($g->{array}, $self->{root}))[0] : '0';
            $code = "\$rt->new_array($n_code, $g->{type}{width})";
        }
        else {
            $code = $self->_default($g->{type});
        }
        push @L, '    $g->{' . p_ident($g->{name}) . "} = $code;";
    }

    my $main;
    for my $fn (@{ $self->{funcs} }) {
        if ($fn->{node}{name} eq 'main') { $main = $fn; next }
        $self->_emit_func(\@L, $fn);
    }
    die "shader has no main()\n" unless $main;
    $self->_emit_func(\@L, $main);
    push @L, '    $' . $main->{mangled} . '->();';
    for my $index (0 .. $#{ $self->{outputs} }) {
        my $name = $self->{outputs}[$index];
        my $out_name = $self->{varyings}{$name}
            ? '$ctx->{uv}'
            : '$g->{' . p_ident($name) . '}';
        my $base = $index * 4;
        push @L, "    my \$_c$index = $out_name;";
        push @L,
            "    \$out->[$base] = \$rt->f32(\$_c$index\->[0]); "
            . "\$out->[" . ($base + 1) . "] = \$rt->f32(\$_c$index\->[1]); "
            . "\$out->[" . ($base + 2) . "] = \$rt->f32(\$_c$index\->[2]); "
            . "\$out->[" . ($base + 3) . "] = \$rt->f32(\$_c$index\->[3]);";
    }
    push @L, '};';
    push @L, '{ kernel => $run_pixel, uses_derivatives => ' . ($self->{uses_deriv} ? 1 : 0)
        . ', output_names => [' . join(', ', map { pq($_) } @{ $self->{outputs} }) . '] };';
    return join('', map { "$_\n" }
        '# Generated by Math::Fractal::Noisemaker::Transpiler - do not edit.',
        'use strict;', 'use warnings;', 'no warnings qw(uninitialized);', @L);
}

sub _emit_func {
    my ($self, $L, $fn) = @_;
    my $indent = 1;
    my $pad    = '    ' x $indent;
    my $scope  = $self->{root}->child;
    my @pynames;
    for my $i (0 .. $#{ $fn->{node}{params} }) {
        my $p = $fn->{node}{params}[$i];
        my $t = $fn->{ptypes}[$i];
        if (!defined $p->[1]) {
            push @pynames, '$_unused' . (++$self->{unused_n});
            next;
        }
        push @pynames, $scope->define($p->[1], $t)->{py};
    }
    my @body_head;
    push @body_head, "$pad    my (" . join(', ', @pynames) . ') = @_;' if @pynames;
    for my $i (0 .. $#{ $fn->{node}{params} }) {
        my $p = $fn->{node}{params}[$i];
        my $t = $fn->{ptypes}[$i];
        if (defined $p->[1] && width_of($t) > 1) {
            my $v = '$' . p_ident($p->[1]);
            push @body_head, "$pad    $v = \$rt->copy($v, " . pq(base_of($t)) . ');';
        }
    }
    my @out_pynames = map { $pynames[$_] } @{ $fn->{out_idxs} || [] };
    my $prev_out    = $self->{cur_out};
    my $prev_decl   = $self->{declared};
    my $prev_ret    = $self->{cur_ret};
    my $prev_func   = $self->{cur_func};
    $self->{cur_func} = $fn->{node}{name};
    $self->{cur_out}  = \@out_pynames;
    $self->{declared} = { map { $_ => 1 } @pynames };
    $self->{cur_ret}  = $fn->{ret};
    my $body = $self->block($fn->{node}{body}, $scope, $indent + 1);
    if (@out_pynames) {    # out/inout params: every exit returns (retval, outs...)
        push @$body, "$pad    return (undef, " . join(', ', @out_pynames) . ');';
    }
    my @locals = sort grep { my $n = $_; !grep { $_ eq $n } @pynames } keys %{ $self->{declared} };
    @locals = grep { !/^\$/ ? 0 : 1 } @locals;
    $self->{cur_out}  = $prev_out;
    $self->{declared} = $prev_decl;
    $self->{cur_ret}  = $prev_ret;
    $self->{cur_func} = $prev_func;
    push @$L, "$pad\$$fn->{mangled} = sub {";
    push @$L, @body_head;
    push @$L, "$pad    my (" . join(', ', @locals) . ');' if @locals;
    push @$L, @$body;
    push @$L, "$pad};";
}

# Register a body local; returns the lvalue name. All body locals are hoisted
# to one `my (...)` at function top (Python function-scope semantics).
sub _local {
    my ($self, $pyname) = @_;
    $self->{declared}{$pyname} = 1 if $self->{declared} && $pyname =~ /^\$/;
    return $pyname;
}

sub block {
    my ($self, $stmts, $scope, $indent) = @_;
    my @out;
    $self->stmt($_, $scope, $indent, \@out) for @$stmts;
    return \@out;
}

sub stmt {
    my ($self, $s, $scope, $indent, $out) = @_;
    my $pad = '    ' x $indent;
    my $k   = $s->{k};
    if ($k eq 'block') {
        push @$out, @{ $self->block($s->{body}, $scope->child, $indent) };
    }
    elsif ($k eq 'decl') {
        for my $dc (@{ $s->{declarators} }) {
            my $t = $self->type_of_name($s->{type}, $dc->{array});
            my $declared_type = $t;
            # Resolve the initializer in the ENCLOSING scope, before the new
            # name is defined (GLSL `float time = time;` reads the outer time).
            # A float vector initializer is stored the way the oracle stores
            # it: an inline value as a Float32Array (see _materialized_operand).
            my $init_code;
            my $init_t;
            if (defined $dc->{init}) {
                (undef, $init_t) = $self->expr($dc->{init}, $scope);
                $init_code = $self->_restore_integer_division($dc->{init}, $scope, $dc->{name});
                if (defined $init_code) { $init_t = $t }
                else { $init_code = $self->_materialized_operand($dc->{init}, $scope) }
            }
            # A scalar declaration can retain the CPU's raw float64 result.
            # int/uint declaration whose initializer computes a float64 value
            # (an untruncated division flowed into it) keeps the value's type,
            # so the arithmetic that consumes the variable stays float64 too.
            $t = { %$t, base => 'float' }
                if defined $init_t
                && width_of($t) == 1
                && width_of($init_t) == 1
                && (base_of($t) eq 'int' || base_of($t) eq 'uint')
                && base_of($init_t) eq 'float';
            # A vector declared from another variable gets its own array, as
            # the canonical kernels' `var z = pos instanceof Float32Array ?
            # copy(pos) : pos` does: later in-place stores to one must not
            # reach the other (mandelbulb's `vec3 z = pos;` would otherwise
            # add z to itself). The components keep their values.
            $init_code = "\$rt->fresh($init_code)"
                if defined $init_code && $dc->{init}{k} eq 'id' && !defined $dc->{array}
                && width_of($t) > 1 && base_of($t) ne 'struct';
            my $kind = (grep { $_ eq 'const' } @{$s->{quals} || []}) ? 'constant'
                : (($self->{cur_func} || '') eq 'main' && defined $dc->{init}
                    ? $self->_divisor_kind($dc->{init}, $scope) : 'unknown');
            my $e = $scope->define($dc->{name}, $t);
            $e->{division_kind} = $kind;
            $e->{declared_type} = $declared_type;
            $self->_local($e->{py});
            if (defined $init_code) {
                push @$out, "$pad$e->{py} = $init_code;";
            }
            elsif (defined $dc->{array}) {
                my $n_code = (ref $dc->{array}) ? ($self->expr($dc->{array}, $scope))[0] : '0';
                push @$out, "$pad$e->{py} = \$rt->new_array($n_code, $t->{width});";
            }
            else {
                push @$out, "$pad$e->{py} = " . $self->_default($t) . ';';
            }
        }
    }
    elsif ($k eq 'expr') {
        my ($code) = $s->{expr}{k} eq 'call'
            ? $self->_e_call($s->{expr}, $scope, 1)
            : $self->expr($s->{expr}, $scope);
        push @$out, "$pad$code;";
    }
    elsif ($k eq 'if') {
        my ($code) = $self->expr($s->{cond}, $scope);
        # Hoist lowered-#if branch declarations to the enclosing scope (see
        # the Python codegen for the full rationale).
        my $hoist = { %{ $self->_branch_decls($s->{then}) } };
        %$hoist = (%$hoist, %{ $self->_branch_decls($s->{els}) }) if defined $s->{els};
        for my $name (sort keys %$hoist) {
            next if $scope->resolve($name);
            my $e = $scope->define($name, $hoist->{$name});
            $self->_local($e->{py});
            push @$out, "$pad$e->{py} = " . $self->_default($hoist->{$name}) . ';';
        }
        push @$out, "${pad}if ($code) {";
        push @$out, @{ $self->_branch($s->{then}, $scope, $indent + 1) };
        if (defined $s->{els}) {
            push @$out, "${pad}} else {";
            push @$out, @{ $self->_branch($s->{els}, $scope, $indent + 1) };
        }
        push @$out, "${pad}}";
    }
    elsif ($k eq 'for') {
        $self->_for($s, $scope, $indent, $out);
    }
    elsif ($k eq 'while' || $k eq 'dowhile') {
        my $lid = $self->{loop_id}++;
        push @$out, "${pad}for my \$_wh$lid (0 .. 1048575) {";
        my ($code) = $self->expr($s->{cond}, $scope);
        push @$out, "$pad    if (!($code)) {";
        push @$out, "$pad        last;";
        push @$out, "$pad    }";
        push @$out, @{ $self->_branch($s->{body}, $scope->child, $indent + 1) };
        push @$out, "${pad}}";
    }
    elsif ($k eq 'return') {
        my $val_node = $s->{value};
        # GLSL permits `return x = expr;` — hoist the assignment.
        if (defined $val_node && ($val_node->{k} || '') eq 'assign') {
            my ($stmt_code) = $self->_e_assign($val_node, $scope);
            push @$out, "$pad$stmt_code;";
            $val_node = $val_node->{target};
        }
        # A vector-valued function returns a Float32Array in the oracle's JS,
        # so an inline return value rounds there (see _materialized_operand).
        if (@{ $self->{cur_out} }) {
            my $val = defined $val_node ? $self->_materialized_operand($val_node, $scope) : 'undef';
            push @$out, "${pad}return ($val, " . join(', ', @{ $self->{cur_out} }) . ');';
        }
        elsif (!defined $val_node) {
            push @$out, "${pad}return;";
        }
        else {
            my $code = $self->_materialized_operand($val_node, $scope);
            push @$out, "${pad}return $code;";
        }
    }
    elsif ($k eq 'break')    { push @$out, "${pad}last;" }
    elsif ($k eq 'continue') { push @$out, "${pad}next;" }
    elsif ($k eq 'discard')  { push @$out, "${pad}return;" }
    else { die "codegen: unhandled statement $k\n" }
}

sub _branch {
    my ($self, $s, $scope, $indent) = @_;
    my @out;
    if ($s->{k} eq 'block') {
        push @out, @{ $self->block($s->{body}, $scope->child, $indent) };
    }
    else {
        $self->stmt($s, $scope->child, $indent, \@out);
    }
    return \@out;
}

# Names (mapped to type) a branch may declare at its top level — the UNION
# over if/elif/else arms, for hoisting lowered-#if declarations.
sub _branch_decls {
    my ($self, $s) = @_;
    return {} unless defined $s;
    my $k = $s->{k} || '';
    if ($k eq 'block') {
        my %decls;
        for my $st (@{ $s->{body} }) {
            next unless ($st->{k} || '') eq 'decl';
            for my $dc (@{ $st->{declarators} }) {
                $decls{ $dc->{name} } = $self->type_of_name($st->{type}, $dc->{array});
            }
        }
        return \%decls;
    }
    if ($k eq 'decl') {
        return {
            map { $_->{name} => $self->type_of_name($s->{type}, $_->{array}) } @{ $s->{declarators} }
        };
    }
    if ($k eq 'if') {
        my $d = { %{ $self->_branch_decls($s->{then}) } };
        %$d = (%$d, %{ $self->_branch_decls($s->{els}) });
        return $d;
    }
    return {};
}

sub _for {
    my ($self, $s, $scope, $indent, $out) = @_;
    my $pad = '    ' x $indent;
    my $lid = $self->{loop_id}++;
    my $ls  = $scope->child;
    $self->stmt($s->{init}, $ls, $indent, $out) if $s->{init};
    $self->_local("\$_for${lid}_first");
    push @$out, "$pad\$_for${lid}_first = 1;";
    push @$out, "${pad}for my \$_for$lid (0 .. 1048575) {";
    push @$out, "$pad    if (!\$_for${lid}_first) {";
    if ($s->{update}) {
        my ($code) = $self->expr($s->{update}, $ls);
        push @$out, "$pad        $code;";
    }
    push @$out, "$pad    }";
    push @$out, "$pad    \$_for${lid}_first = 0;";
    if ($s->{cond}) {
        my ($code) = $self->expr($s->{cond}, $ls);
        push @$out, "$pad    if (!($code)) {";
        push @$out, "$pad        last;";
        push @$out, "$pad    }";
    }
    push @$out, @{ $self->_branch($s->{body}, $ls, $indent + 1) };
    push @$out, "${pad}}";
}

sub _default {
    my ($self, $t) = @_;
    if (base_of($t) eq 'struct') {
        my $fields = $self->{structs}{ $t->{struct} } || [];
        return '[' . join(', ', map { $self->_default($self->type_of_name($_->[0])) } @$fields) . ']';
    }
    if (width_of($t) == 1) {
        return base_of($t) eq 'bool' ? '0'
            : (base_of($t) eq 'int' || base_of($t) eq 'uint') ? '0'
            : '$rt->f(0.0)';
    }
    return "\$rt->construct($t->{width}, 0.0" . _construct_base($t) . ')';
}

# ---- expressions -> (code, type) ----

sub expr {
    my ($self, $node, $scope) = @_;
    my $k = $node->{k};
    my $m = $self->can("_e_$k") or die "codegen: no handler for expr kind $k\n";
    return $self->$m($node, $scope);
}

sub _e_num {
    my ($self, $node) = @_;
    my $raw = $node->{value};
    my $low = lc $raw;
    if ($low =~ /u$/) {
        (my $body = $raw) =~ s/[uU]$//;
        my $v = $body =~ /^0[xX]/ ? hex($body) : ($body + 0);
        return ("\$rt->i($v)", $TYPE{uint});
    }
    if ($low =~ /^0x/) {
        return ('$rt->i(' . hex($raw) . ')', $TYPE{int});
    }
    if ($raw =~ /[.]/ || $low =~ /e/ || $low =~ /f$/) {
        (my $body = $raw) =~ s/[fF]$//;
        return ('$rt->f(' . _fmt_num($body) . ')', $FLOAT);
    }
    return ("\$rt->i(" . ($raw + 0) . ')', $TYPE{int});
}

sub _e_bool {
    my ($self, $node) = @_;
    return ($node->{value} ? '1' : '0', $BOOL);
}

sub _e_id {
    my ($self, $node, $scope) = @_;
    my $name = $node->{name};
    return ('$ctx->{frag_coord}', $VEC4) if $name eq 'gl_FragCoord';
    my $e = $scope->resolve($name);
    if (!$e) {
        if ($name eq 'v_texCoord' || $name eq 'vTexCoord' || $name eq 'texCoord') {
            return ('$ctx->{uv}', $TYPE{vec2});    # undeclared fragment varying
        }
        die "codegen: unresolved identifier '$name'\n";
    }
    return ($e->{py}, $e->{type});
}

sub _e_member {
    my ($self, $node, $scope) = @_;
    my ($obj_code, $obj_t) = $self->expr($node->{obj}, $scope);
    my $field = $node->{field};
    if (base_of($obj_t) eq 'struct') {
        my $fields = $self->{structs}{ $obj_t->{struct} } || [];
        my $idx    = 0;
        for my $i (0 .. $#$fields) {
            if ($fields->[$i][1] eq $field) { $idx = $i; last }
        }
        my $ftype = @$fields ? $self->type_of_name($fields->[$idx][0]) : $FLOAT;
        return ("${obj_code}->[$idx]", $ftype);
    }
    my $w = length $field;
    my $t = { base => base_of($obj_t), width => $w };
    return ("\$rt->swizzle($obj_code, " . pq($field) . ')', $t);
}

sub _e_index {
    my ($self, $node, $scope) = @_;
    my ($obj_code, $obj_t) = $self->expr($node->{obj}, $scope);
    my ($idx_code, $idx_t) = $self->expr($node->{idx}, $scope);
    if ($obj_t->{mat}) {
        my $n = $obj_t->{mat};
        return ("\$rt->mat_col($obj_code, $idx_code, $n)", { base => 'float', width => $n });
    }
    # JS model for the %JS_UINT_MODEL effects: an array read with a
    # fractional, negative or out-of-range index yields undefined, and the
    # bitwise consumers of such a read coerce it to 0 (ToInt32(undefined) is
    # 0). The plain int() wrap would silently read a truncated row instead.
    if ($self->_uses_js_uint_model
        && base_of($idx_t) eq 'float'
        && width_of($idx_t) == 1) {
        my $t = { base => base_of($obj_t), width => $obj_t->{array} ? $obj_t->{width} : 1 };
        return ("(($idx_code) >= 0 && ($idx_code) == int($idx_code) && ($idx_code) < scalar(\@{${obj_code}})"
            . " ? ${obj_code}->[int($idx_code)] : 0)", $t);
    }
    if ($obj_t->{array}) {
        return ("${obj_code}->[int($idx_code)]", { base => base_of($obj_t), width => $obj_t->{width} });
    }
    return ("${obj_code}->[int($idx_code)]", { base => base_of($obj_t), width => 1 });
}

sub _e_unary {
    my ($self, $node, $scope) = @_;
    if ($node->{op} eq '++' || $node->{op} eq '--') {    # prefix
        return $self->_incdec($node->{x}, $node->{op}, $scope);
    }
    my ($code, $t) = $self->expr($node->{x}, $scope);
    if ($node->{op} eq '!') {
        return ("(($code) ? 0 : 1)", $BOOL);
    }
    if ($node->{op} eq '~') {
        return ("\$rt->bit_not($code)", $t);
    }
    return ('$rt->unary(' . pq($node->{op}) . ", $code)", $t);
}

sub _e_post {
    my ($self, $node, $scope) = @_;
    return $self->_incdec($node->{x}, $node->{op}, $scope);
}

sub _incdec {
    my ($self, $target, $op, $scope) = @_;
    my ($code, $t) = $self->expr($target, $scope);
    my $base = $op eq '++' ? '+' : '-';
    my $b = base_of($t) eq 'uint' ? 'uint' : (base_of($t) eq 'int' ? 'int' : 'float');
    return (
        "$code = \$rt->binary(" . pq($base) . ", $code, \$rt->i(1), " . width_of($t) . ', ' . pq($b) . ')',
        $t
    );
}

sub _e_cond {
    my ($self, $node, $scope) = @_;
    my ($c_code) = $self->expr($node->{c}, $scope);
    my ($a_code, $a_t) = $self->expr($node->{a}, $scope);
    my ($b_code, $b_t) = $self->expr($node->{b}, $scope);
    my $w = width_of($a_t) > width_of($b_t) ? width_of($a_t) : width_of($b_t);
    return ("(($c_code) ? ($a_code) : ($b_code))", { base => base_of($a_t), width => $w });
}

sub _divisor_kind {
    my ($self, $node, $scope, $seen) = @_;
    $seen ||= {};
    my @kinds;
    if (ref($node) eq 'HASH') {
        if (($node->{k} || '') eq 'id') {
            my $name = $node->{name};
            return 'runtime' if $name eq 'gl_FragCoord';
            my $entry = $scope->resolve($name);
            return 'constant' unless $entry;
            return 'unknown' unless exists $entry->{division_kind};
            return $entry->{division_kind} if defined $entry->{division_kind};
            return 'unknown' if $seen->{$name};
            return $self->_divisor_kind($entry->{initializer}, $scope, {%$seen, $name=>1});
        }
        @kinds = map { $self->_divisor_kind($_, $scope, $seen) } grep { ref($_) } values %$node;
    } elsif (ref($node) eq 'ARRAY') {
        @kinds = map { $self->_divisor_kind($_, $scope, $seen) } @$node;
    } else { return defined($node) ? 'constant' : 'unknown' }
    return 'unknown' if grep { $_ eq 'unknown' } @kinds;
    return (grep { $_ eq 'runtime' } @kinds) ? 'runtime' : 'constant';
}

sub _grouped_division_name {
    my ($self, $node) = @_;
    return 0 unless ($node->{grouping} || 0) == 1;
    return 1 if $node->{k} eq 'id';
    return 1 if $node->{k} eq 'member' && $node->{obj}{k} eq 'id' && length($node->{field}) == 1;
    return 1 if $node->{k} eq 'index' && $node->{obj}{k} eq 'id' && $node->{idx}{k} eq 'num';
    return 0;
}

sub _lowered_integer_expression {
    my ($self, $node, $scope) = @_;
    if ($node->{k} eq 'id') {
        my $entry = $scope->resolve($node->{name});
        return $entry && base_of($entry->{declared_type}) =~ /^(?:int|uint)$/;
    }
    if ($node->{k} eq 'construct' && $node->{type} eq 'float' && @{$node->{args}} == 1 && $node->{args}[0]{k} eq 'id') {
        return $self->_lowered_integer_expression($node->{args}[0], $scope);
    }
    if ($node->{k} eq 'binary' && $node->{op} =~ m{^[-+*/]$}) {
        return $self->_lowered_integer_expression($node->{l}, $scope) && $self->_lowered_integer_expression($node->{r}, $scope);
    }
    return base_of(($self->expr($node, $scope))[1]) =~ /^(?:int|uint)$/;
}

sub _integer_division_operand {
    my ($self, $node, $scope) = @_;
    return 0 if $self->_grouped_division_name($node);
    return $self->_lowered_integer_expression($node, $scope) if $node->{k} eq 'id';
    return 1 if $node->{grouping} && $node->{k} eq 'construct' && $node->{type} eq 'float' && $self->_lowered_integer_expression($node, $scope);
    return 1 if $node->{k} eq 'binary' && $self->_lowered_integer_expression($node, $scope);
    return 1 if base_of(($self->expr($node, $scope))[1]) =~ /^(?:int|uint)$/;
    return $node->{k} eq 'construct' && $node->{type} =~ /^vec[234]$/ && @{$node->{args}} == 1
        && width_of(($self->expr($node->{args}[0], $scope))[1]) > 1
        && $self->_integer_division_operand($node->{args}[0], $scope);
}

sub _metal_division {
    my ($self, $node, $scope, $left, $right) = @_;
    return 0 unless $node->{op} eq '/' && !$left->{mat} && !$right->{mat}
        && width_of($left) <= 4 && width_of($right) <= 4;
    return 0 unless base_of($left) eq 'float' || base_of($right) eq 'float'
        || $self->_grouped_division_name($node->{l}) || $self->_grouped_division_name($node->{r});
    return 0 if $self->_integer_division_operand($node->{l}, $scope) && $self->_integer_division_operand($node->{r}, $scope);
    return $self->_divisor_kind($node->{r}, $scope) eq 'runtime';
}

sub _truncated_division {
    my ($self, $node, $scope) = @_;
    my $left = ($self->expr($node->{l}, $scope))[0];
    my $right = ($self->expr($node->{r}, $scope))[0];
    return "POSIX::trunc(\$rt->binary('/', $left, $right, 1, 'float'))";
}

sub _restore_integer_division {
    my ($self, $node, $scope, $name) = @_;
    if ($node->{k} eq 'cond') {
        return undef unless $self->{int_names}{$name};
        my $text = join(' ', @{$node->{source_tokens} || []});
        $text =~ s/\bint\s*\(([^()]*)\)/$1|0/g;
        my $name = qr/[A-Za-z_]\w*/;
        if ($text =~ /\A[^;?:]+\?\s*($name|\([^()]*\))\s*\/\s*($name)\s*:\s*($name|\([^()]*\))\s*\/\s*($name)\z/) {
            my ($l, $ld, $r, $rd) = ($1, $2, $3, $4);
            if ($self->{int_names}{$ld} && $self->{int_names}{$rd}
                && ($l =~ /^\(/ || $self->{int_names}{$l}) && ($r =~ /^\(/ || $self->{int_names}{$r})) {
                my @branches = ($node->{a}, $node->{b});
                my @metal = map {
                    my $b = $branches[$_];
                    $self->_metal_division($b, $scope, ($self->expr($b->{l}, $scope))[1], ($self->expr($b->{r}, $scope))[1]);
                } 0, 1;
                my @arms = map { (grep { $_ } @metal) ? ($self->expr($_, $scope))[0] : $self->_truncated_division($_, $scope) } @branches;
                my $condition = ($self->expr($node->{c}, $scope))[0];
                return "(($condition) ? ($arms[0]) : ($arms[1]))";
            }
        }
        return undef;
    }
    return undef unless $node->{k} eq 'binary' && $node->{op} eq '/';
    my ($l, $r) = ($node->{l}, $node->{r});
    return undef if $l->{grouping} || $r->{grouping} || $r->{k} ne 'id';
    return undef unless $self->{int_names}{$r->{name}};
    return undef if $self->_metal_division($node, $scope,
        ($self->expr($l, $scope))[1], ($self->expr($r, $scope))[1]);
    if ($l->{k} eq 'id') {
        return undef unless $self->{int_names}{$l->{name}};
        return undef if $l->{name} eq $r->{name};
    } elsif ($l->{k} eq 'member' && $l->{obj}{k} eq 'id' && length($l->{field}) == 1) {
        return undef unless width_of(($self->expr($l->{obj}, $scope))[1]) > 1;
    } elsif ($l->{k} eq 'index' && $l->{obj}{k} eq 'id' && $l->{idx}{k} eq 'num') {
        return undef unless width_of(($self->expr($l->{obj}, $scope))[1]) > 1;
    } else { return undef }
    return $self->_truncated_division($node, $scope);
}

sub _e_binary {
    my ($self, $node, $scope) = @_;
    my $op = $node->{op};
    my ($l_code, $l_t) = $self->expr($node->{l}, $scope);
    my ($r_code, $r_t) = $self->expr($node->{r}, $scope);
    if ($op =~ /^(?:==|!=|<|>|<=|>=|&&|\|\|)$/) {
        if ($op eq '&&') { return ("(($l_code) && ($r_code) ? 1 : 0)", $BOOL) }
        if ($op eq '||') { return ("(($l_code) || ($r_code) ? 1 : 0)", $BOOL) }
        return ('$rt->binary(' . pq($op) . ", $l_code, $r_code)", $BOOL);
    }
    if ($op eq '*'
        && ($l_t->{mat} || $r_t->{mat})
        && width_of($l_t) > 1
        && width_of($r_t) > 1) {
        my $dim  = $l_t->{mat} || $r_t->{mat};
        my $both = $l_t->{mat} && $r_t->{mat};
        my $t = $both
            ? { base => 'float', width => $dim * $dim, mat => $dim }
            : { base => 'float', width => $dim };
        return ("\$rt->matrix_mult($l_code, $r_code, $dim)", $t);
    }
    my $width = width_of($l_t) > width_of($r_t) ? width_of($l_t) : width_of($r_t);
    my ($lb, $rb) = (base_of($l_t), base_of($r_t));
    my $base;
    if ($lb eq 'uint' || $rb eq 'uint') { $base = 'uint' }
    elsif (($lb eq 'int' && $rb eq 'int') || $op =~ /^(?:&|\||\^|<<|>>|%)$/) { $base = 'int' }
    else { $base = 'float' }
    # Parenthesized uint literals miss the CPU source normalizer's cpu_umul
    # pattern, leaving a raw scalar product before later bitwise coercion.
    $base = 'float' if $op eq '*' && $width == 1 && $base eq 'uint'
        && grep { $_->{k} eq 'num' && $_->{grouping} } ($node->{l}, $node->{r});
    # JavaScript remainder does not coerce a runtime hash's unsigned result
    # through ToInt32; the following explicit int cast supplies that boundary.
    $base = 'float' if $op eq '%' && $width == 1 && $base eq 'uint'
        && $self->_uses_js_uint_model;
    # Scalar divisions remain raw until the CPU's declaration-level restore.
    $base = 'float' if $op eq '/' && $width == 1;
    my $metal = $self->_metal_division($node, $scope, $l_t, $r_t);
    $base = 'float' if $metal;
    my $code = '$rt->binary(' . pq($op) . ", $l_code, $r_code, $width, " . pq($base) . ')';
    $code = "\$rt->metal_divide($l_code, $r_code)" if $metal;
    # Round where the oracle's compiled JS rounds (see _vec_kind); otherwise
    # the result stays raw until its next consumption boundary.
    if ($base eq 'float' && $width > 1 && $op =~ m{^[-+*/]$}) {
        my ($left, $right);
        if ($self->_vec_binary_rounds($node, $scope)) {
            $left = $self->_materialized_operand($node->{l}, $scope);
            $right = $self->_materialized_operand($node->{r}, $scope);
            my $operation = $metal ? "\$rt->metal_divide($left, $right)"
                : '$rt->binary(' . pq($op) . ", $left, $right, $width, 'float')";
            $code = "\$rt->construct($width, $operation)";
        }
        else {
            $left = $self->_fused_operand($node->{l}, $scope);
            $right = $self->_fused_operand($node->{r}, $scope);
            $code = $metal ? "\$rt->metal_divide($left, $right)"
                : '$rt->binary(' . pq($op) . ", $left, $right, $width, 'float')";
        }
    }
    return ($code, { base => $base, width => $width });
}

# An inline operand of fused arithmetic. Its constructors keep float
# components raw (see Runtime::construct_raw), including under a negation;
# an int or uint component still rounds, as the oracle's cpu_float
# conversion does.
sub _fused_operand {
    my ($self, $node, $scope) = @_;
    my ($code, $t) = $self->expr($node, $scope);
    return $code unless base_of($t) eq 'float' && width_of($t) > 1 && !$t->{mat};
    my $k = $node->{k} // q{};
    if ($k eq 'construct' && !defined $node->{array}) {
        return $code if $self->_vec_kind($node, $scope) eq 'typed';    # a new Float32Array
        my @args;
        for my $arg (@{ $node->{args} }) {
            my ($a_code, $a_t) = $self->expr($arg, $scope);
            push @args, base_of($a_t) eq 'float'
                ? $self->_fused_operand($arg, $scope)
                : '$rt->construct(' . width_of($a_t) . ", $a_code)";
        }
        return "\$rt->construct_raw($t->{width}, " . join(', ', @args) . ')';
    }
    if ($k eq 'unary' && $node->{op} eq '-') {
        return '$rt->unary(' . pq('-') . ', ' . $self->_fused_operand($node->{x}, $scope) . ')';
    }
    return $code;
}

# An operand of vecN.add/subtract/multiply/divide, or the vector of a
# Float32Array#map. The oracle materializes an inline operand as a pooled
# Float32Array, which rounds each component before the op reads it; typed and
# plain operands reach the op as they are.
sub _materialized_operand {
    my ($self, $node, $scope) = @_;
    my ($code, $t) = $self->expr($node, $scope);
    return $code unless base_of($t) eq 'float' && width_of($t) > 1 && !$t->{mat};
    my $k    = $node->{k} // q{};
    my $kind = $self->_vec_kind($node, $scope);
    if ($kind eq 'plain') {    # a single-vector constructor passes the Array through
        return $code unless $k eq 'construct';
        return "\$rt->construct_raw($t->{width}, " . ($self->expr($node->{args}[0], $scope))[0] . ')';
    }
    return $code if $kind eq 'typed' || $k eq 'id' || $k eq 'construct';
    return $code if ($k eq 'member' || $k eq 'index') && ($node->{obj}{k} // q{}) eq 'id';
    return "\$rt->construct($t->{width}, $code)";
}

# The oracle's compiled JS holds a float vector in one of three forms, which
# decides where its arithmetic rounds to f32:
#   inline - per-component slot expressions (variables, swizzles, literals,
#            constructors and arithmetic on them): raw f64, rounded once
#            where the value is stored;
#   typed  - a pooled Float32Array: a vector-valued call (builtin, user
#            function or sampler read) or a scalar operation on a typed
#            value, which compiles to Float32Array#map and rounds each
#            component (simplex `1.0 - abs(x)`);
#   plain  - the [] filled by vecN.add/subtract/multiply/divide, which round
#            each component; a scalar .map over a plain Array stays raw.
# Vector-vector arithmetic compiles to vecN.op as soon as either operand is
# not inline. The kinds follow the GLSL operand types, before any splat:
# `call * vec2(64.0)` is vec2.multiply, not a map. A swizzle of a non-inline
# vector (`texture(t, uv).rgb`) and a constructor that has to spread one
# (`vec4(call(), 1.0)`) compile to new Float32Arrays, so they are typed; a
# single-vector constructor (`vec3(call())`) passes its argument through.
sub _vec_kind {
    my ($self, $node, $scope) = @_;
    my $k = $node->{k} // q{};
    if ($k eq 'call') {
        my (undef, $t) = $self->expr($node, $scope);
        return (base_of($t) eq 'float' && width_of($t) > 1 && !$t->{mat}) ? 'typed' : 'inline';
    }
    if ($k eq 'member' || $k eq 'index') {
        my (undef, $t) = $self->expr($node, $scope);
        return 'inline' unless width_of($t) > 1 && !$t->{mat};
        return $self->_spreads($node->{obj}, $scope) ? 'typed' : 'inline';
    }
    if ($k eq 'unary' && $node->{op} eq '-') {
        return $self->_vec_kind($node->{x}, $scope);
    }
    if ($k eq 'construct' && !defined $node->{array}) {
        my $args = $node->{args};
        if (@$args == 1) {
            my (undef, $a_t) = $self->expr($args->[0], $scope);
            if (width_of($a_t) > 1 && !$a_t->{mat}) {
                return 'typed' if ($args->[0]{k} // q{}) eq 'call';
                return base_of($a_t) eq 'float' ? $self->_vec_kind($args->[0], $scope) : 'inline';
            }
        }
        for my $arg (@$args) {
            return 'typed' if $self->_spreads($arg, $scope);
            my $ak = $arg->{k} // q{};
            return 'typed' if ($ak eq 'member' || $ak eq 'index') && $self->_spreads($arg->{obj}, $scope);
        }
        return 'inline';
    }
    if ($k eq 'binary' && $node->{op} =~ m{^[-+*/]$}) {
        my (undef, $l_t) = $self->expr($node->{l}, $scope);
        my (undef, $r_t) = $self->expr($node->{r}, $scope);
        return 'inline' if $l_t->{mat} || $r_t->{mat} || base_of($l_t) ne 'float' || base_of($r_t) ne 'float';
        my ($lk, $rk) = ($self->_vec_kind($node->{l}, $scope), $self->_vec_kind($node->{r}, $scope));
        if (width_of($l_t) > 1 && width_of($r_t) > 1) {
            return ($lk eq 'inline' && $rk eq 'inline') ? 'inline' : 'plain';
        }
        return width_of($l_t) > 1 ? $lk : $rk;
    }
    return 'inline';
}

# A vector the oracle cannot expand per component: a vector-valued call of
# any base, or a float vector that is typed or plain.
sub _spreads {
    my ($self, $node, $scope) = @_;
    my (undef, $t) = $self->expr($node, $scope);
    return 0 unless width_of($t) > 1 && !$t->{mat};
    return 1 if ($node->{k} // q{}) eq 'call';
    return base_of($t) eq 'float' && $self->_vec_kind($node, $scope) ne 'inline';
}

sub _vec_binary_rounds {
    my ($self, $node, $scope) = @_;
    my (undef, $l_t) = $self->expr($node->{l}, $scope);
    my (undef, $r_t) = $self->expr($node->{r}, $scope);
    return 0 if $l_t->{mat} || $r_t->{mat};
    my ($lk, $rk) = ($self->_vec_kind($node->{l}, $scope), $self->_vec_kind($node->{r}, $scope));
    if (width_of($l_t) > 1 && width_of($r_t) > 1) {
        return !($lk eq 'inline' && $rk eq 'inline');    # vecN.op
    }
    return (width_of($l_t) > 1 ? $lk : $rk) eq 'typed';    # Float32Array#map
}

sub _e_assign {
    my ($self, $node, $scope) = @_;
    my $op     = $node->{op};
    my $target = $node->{target};
    my ($v_code, $v_type) = $self->expr($node->{value}, $scope);
    my $base_op = $op eq '=' ? undef : substr($op, 0, length($op) - 1);
    my ($tcode, $tt) = $self->expr($target, $scope);
    if ($target->{k} eq 'id' || $target->{k} eq 'index') {
        my $rhs;
        if ($base_op) {
            my $b = base_of($tt) eq 'uint' ? 'uint' : (base_of($tt) eq 'int' ? 'int' : 'float');
            $b = 'float' if $base_op eq '/' && width_of($tt) == 1;
            $rhs = '$rt->binary(' . pq($base_op) . ", $tcode, $v_code, " . width_of($tt) . ', ' . pq($b) . ')';
            $rhs = "\$rt->metal_divide($tcode, $v_code)"
                if $base_op eq '/' && $b eq 'float' && width_of($tt) > 1
                && width_of($v_type) == 1
                && $self->_divisor_kind($node->{value}, $scope) eq 'runtime';
        }
        else {
            $rhs = $v_code;
        }
        # In-place vector reassignment preserves JS pooled-array aliasing
        # (`prevUV = rayUV` must track later updates). Float stores snap each
        # element to f32 — JS stores into a Float32Array, and accumulator
        # loops (e.g. stamp's gaussian `sum`) feed the stored value straight
        # back into arithmetic, so an unsnapped store drifts. Int vectors
        # store exact.
        if ($target->{k} eq 'id' && width_of($tt) > 1) {
            if (base_of($tt) eq 'int' || base_of($tt) eq 'uint') {
                return ("scalar do { \@{$tcode} = \@{($rhs)}; $tcode }", $tt);
            }
            return ("scalar do { \@{$tcode} = map { \$rt->f32(\$_) } \@{($rhs)}; $tcode }", $tt);
        }
        # An element of a float vector, or of an array of float vectors, is a
        # Float32Array slot in the oracle's JS, so the store rounds; a float
        # array is a plain Array and keeps the value.
        if ($target->{k} eq 'index' && base_of($tt) eq 'float' && !$tt->{mat}) {
            my (undef, $obj_t) = $self->expr($target->{obj}, $scope);
            if (width_of($tt) > 1 && !$obj_t->{mat}) {
                return ("scalar do { \@{$tcode} = map { \$rt->f32(\$_) } \@{($rhs)}; $tcode }", $tt);
            }
            if (width_of($tt) == 1 && width_of($obj_t) > 1 && !$obj_t->{array} && !$obj_t->{mat}) {
                return ("$tcode = \$rt->f32($rhs)", $tt);
            }
        }
        return ("$tcode = $rhs", $tt);
    }
    if ($target->{k} eq 'member') {
        my ($obj_code, $obj_t) = $self->expr($target->{obj}, $scope);
        if (base_of($obj_t) eq 'struct') {
            my $fields = $self->{structs}{ $obj_t->{struct} } || [];
            my $idx    = 0;
            for my $i (0 .. $#$fields) {
                if ($fields->[$i][1] eq $target->{field}) { $idx = $i; last }
            }
            return ("${obj_code}->[$idx] = $v_code", $tt);
        }
        my $sw = $target->{field};
        my $rhs;
        if ($base_op) {
            my $cur = "\$rt->swizzle($obj_code, " . pq($sw) . ')';
            my $ob  = base_of($obj_t);
            my $b   = $ob eq 'uint' ? 'uint' : ($ob eq 'int' ? 'int' : 'float');
            $b = 'float' if $base_op eq '/' && length($sw) == 1;
            $rhs = '$rt->binary(' . pq($base_op) . ", $cur, $v_code, " . length($sw) . ', ' . pq($b) . ')';
            $rhs = "\$rt->metal_divide($cur, $v_code)"
                if $base_op eq '/' && $b eq 'float' && length($sw) > 1
                && $self->_divisor_kind($node->{value}, $scope) eq 'runtime';
        }
        else {
            $rhs = $v_code;
        }
        return (
            "$obj_code = \$rt->assign_swizzle($obj_code, " . pq($sw) . ", $rhs)",
            { base => base_of($obj_t), width => length $sw }
        );
    }
    die "codegen: bad assignment target $target->{k}\n";
}

sub _e_construct {
    my ($self, $node, $scope) = @_;
    my $tname = $node->{type};
    my @args  = map { [$self->expr($_, $scope)] } @{ $node->{args} };
    my $elems = join ', ', map { $_->[0] } @args;
    if (defined $node->{array}) {    # array constructor TYPE[N](...)
        my $elt = $TYPE{$tname} || $FLOAT;
        return ("\$rt->array([$elems])", { base => $elt->{base}, width => $elt->{width}, array => 1 });
    }
    if ($self->{structs}{$tname}) {
        return ("[$elems]", { base => 'struct', width => 0, struct => $tname });
    }
    my $t = $TYPE{$tname};
    if (!$t) {
        my $w = 1;
        for (@args) { $w = width_of($_->[1]) if width_of($_->[1]) > $w }
        $t = { base => 'float', width => $w };
    }
    return ("\$rt->construct($t->{width}" . ($elems ne '' ? ", $elems" : '') . _construct_base($t) . ')', $t);
}

my %ROUTED = (
    texture     => sub { my ($g, $c, $a) = @_; ("\$rt->texture($c->[0], $c->[1])",      $VEC4) },
    textureLod  => sub { my ($g, $c, $a) = @_; ("\$rt->texture($c->[0], $c->[1])",      $VEC4) },
    texelFetch  => sub { my ($g, $c, $a) = @_; ("\$rt->texel_fetch($c->[0], $c->[1], " . (@$c > 2 ? $c->[2] : '0') . ')', $VEC4) },
    textureSize => sub { my ($g, $c, $a) = @_; ("\$rt->texture_size($c->[0])",          $TYPE{ivec2}) },
    length      => sub { my ($g, $c, $a) = @_; ("\$rt->length($c->[0])",                $FLOAT) },
    __array_length => sub { my ($g, $c, $a) = @_; ("scalar(\@{$c->[0]})", $TYPE{int}) },
    distance  => sub { my ($g, $c, $a) = @_; ("\$rt->distance($c->[0], $c->[1])",       $FLOAT) },
    dot       => sub { my ($g, $c, $a) = @_; ("\$rt->dot($c->[0], $c->[1])",            $FLOAT) },
    normalize => sub { my ($g, $c, $a) = @_; ("\$rt->normalize($c->[0])",               $a->[0][1]) },
    cross     => sub { my ($g, $c, $a) = @_; ("\$rt->cross($c->[0], $c->[1])",          $a->[0][1]) },
    reflect   => sub { my ($g, $c, $a) = @_; ("\$rt->reflect($c->[0], $c->[1])",        $a->[0][1]) },
    refract   => sub { my ($g, $c, $a) = @_; ("\$rt->refract($c->[0], $c->[1], $c->[2])", $a->[0][1]) },
    pcg3d     => sub { my ($g, $c, $a) = @_; ("\$rt->pcg3d($c->[0])",                   $TYPE{uvec3}) },
    cpu_umul  => sub { my ($g, $c, $a) = @_; ("\$rt->binary('*', $c->[0], $c->[1], 1, 'uint')", $TYPE{uint}) },
    hashUint  => sub { my ($g, $c, $a) = @_; ("\$rt->hash_uint($c->[0])",               $TYPE{uint}) },
    hash_uint => sub { my ($g, $c, $a) = @_; ("\$rt->hash_uint($c->[0])",               $TYPE{uint}) },
    hash_uint_lcg => sub { my ($g, $c, $a) = @_; ("\$rt->hash_uint_lcg($c->[0])",       $TYPE{uint}) },
    floatBitsToUint => sub { my ($g, $c, $a) = @_; ("\$rt->float_bits_to_uint($c->[0])", $TYPE{uint}) },
    uintBitsToFloat => sub { my ($g, $c, $a) = @_; ("\$rt->uint_bits_to_float($c->[0])", $FLOAT) },
    packHalf2x16    => sub { my ($g, $c, $a) = @_; ("\$rt->pack_half_2x16($c->[0])",     $TYPE{uint}) },
    unpackHalf2x16  => sub { my ($g, $c, $a) = @_; ("\$rt->unpack_half_2x16($c->[0])",   $TYPE{vec2}) },
    cpu_float => sub { my ($g, $c, $a) = @_; ("\$rt->construct(1, $c->[0])", $FLOAT) },
    cpu_ivec2 => sub { my ($g, $c, $a) = @_; ('$rt->construct(2, ' . join(', ', @$c) . ", 'int')",  $TYPE{ivec2}) },
    cpu_ivec3 => sub { my ($g, $c, $a) = @_; ('$rt->construct(3, ' . join(', ', @$c) . ", 'int')",  $TYPE{ivec3}) },
    cpu_uvec2 => sub { my ($g, $c, $a) = @_; ('$rt->construct(2, ' . join(', ', @$c) . ", 'uint')", $TYPE{uvec2}) },
    cpu_uvec3 => sub { my ($g, $c, $a) = @_; ('$rt->construct(3, ' . join(', ', @$c) . ", 'uint')", $TYPE{uvec3}) },
);

sub _e_call {
    my ($self, $node, $scope, $discard) = @_;
    my $name = $node->{name};
    my @args = map { [$self->expr($_, $scope)] } @{ $node->{args} };
    my @codes = map { $_->[0] } @args;
    if ($name eq 'dFdx' || $name eq 'dFdy' || $name eq 'fwidth') {
        $self->{uses_deriv} = 1;
        return ("\$rt->$name($codes[0])", $args[0][1]);
    }
    return ("\$rt->hash_uint($codes[0])", $TYPE{uint}) if $self->{program}{murmur_finalizers}{$name};
    if (my $r = ($name eq 'hash_uint' && $self->{overloads}{$name}) ? undef : $ROUTED{$name}) {
        return $r->($self, \@codes, \@args);
    }
    if ($self->{overloads}{$name}) {
        my $fn = $self->_resolve_overload($name, [map { $_->[1] } @args]);
        # A vector argument reaches the function as the oracle passes it: an
        # inline value materialized as a Float32Array, typed and plain as is.
        @codes = map { $self->_materialized_operand($node->{args}[$_], $scope) } 0 .. $#{ $node->{args} };
        if (@{ $fn->{out_idxs} || [] }) {    # out/inout: unpack outputs
            my @targets = map { ($self->expr($node->{args}[$_], $scope))[0] } @{ $fn->{out_idxs} };
            my $result = $discard ? q{} : ' $_retc';
            return (
                'do { ($_retc, ' . join(', ', @targets) . ") = \$$fn->{mangled}->("
                    . join(', ', @codes) . ");$result }",
                $fn->{ret}
            );
        }
        return ("\$$fn->{mangled}->(" . join(', ', @codes) . ')', $fn->{ret});
    }
    if ($TYPE{$name}) {    # scalar cast: int(x), float(x), uint(x)
        my $t = $TYPE{$name};
        return (
            "\$rt->construct($t->{width}" . (@codes ? ', ' . join(', ', @codes) : '') . _construct_base($t) . ')',
            $t
        );
    }
    # component-wise builtin
    my $width = 1;
    for (@args) { $width = width_of($_->[1]) if width_of($_->[1]) > $width }
    my $base = (@args && !grep { base_of($_->[1]) ne 'int' && base_of($_->[1]) ne 'uint' } @args) ? 'int' : 'float';
    return (
        '$rt->component_wise(' . pq($name) . (@codes ? ', ' . join(', ', @codes) : '') . ')',
        { base => $base, width => $width }
    );
}

sub _resolve_overload {
    my ($self, $name, $argtypes) = @_;
    my $cands = $self->{overloads}{$name};
    return $cands->[0] if @$cands == 1;
    my @same = grep { @{ $_->{ptypes} } == @$argtypes } @$cands;
    for my $c (@same) {
        my $ok = 1;
        for my $i (0 .. $#$argtypes) {
            my ($p, $a) = ($c->{ptypes}[$i], $argtypes->[$i]);
            if (base_of($p) ne base_of($a) || width_of($p) != width_of($a)) { $ok = 0; last }
        }
        return $c if $ok;
    }
    return @same ? $same[0] : $cands->[0];
}

sub _type_name {
    my ($t) = @_;
    for my $k (sort keys %TYPE) {
        my $v = $TYPE{$k};
        if (($v->{base} || '') eq ($t->{base} || '')
            && ($v->{width} || 0) == ($t->{width} || 0)
            && (($v->{mat} || 0) == ($t->{mat} || 0))) {
            return $k;
        }
    }
    return base_of($t) . width_of($t);
}

# Functions whose GLSL definitions are overridden by runtime routing.
my %SKIP_FUNCS = map { $_ => 1 }
    qw(cpu_umul cpu_ivec2 cpu_ivec3 cpu_ivec4 cpu_uvec2 cpu_uvec3 cpu_uvec4 cpu_float);

sub emit_perl {
    my ($program, $outputs, $varyings, $effect_id, $options) = @_;
    $program->{decls} =
        [grep { !(($_->{k} || '') eq 'func' && $SKIP_FUNCS{ $_->{name} || '' }) } @{ $program->{decls} }];
    my $gen = __PACKAGE__->new($program, $outputs, $varyings, $effect_id, $options);
    return $gen->emit;
}

1;
