package Math::Fractal::Noisemaker::Runtime;

# CSL/GLSL CPU runtime — the vector-math core that transpiled kernels call.
#
# Faithful port of the (parity-proven) Python runtime, itself a port of
# noisemaker-cpu src/csl/runtime.js + glsl-runtime.js semantics. The float
# model that achieved 167/167 byte-parity is baked in:
#
# - Scalars are Perl NVs (float64). Scalar arithmetic accumulates raw f64,
#   rounded to float32 only at boundaries.
# - Vectors are plain arrayrefs. binary/unary DEFER float32 rounding (raw
#   f64 element math), and every consumption boundary — swizzle, dot,
#   component_wise, assign_swizzle, texture, construct, the output stage —
#   snaps to f32. This mirrors JS, which evaluates a whole component
#   expression in float64 and rounds once when storing into a Float32Array.
#   Per-op rounding double-rounds and accumulates sub-ULP error (the bug
#   that broke wormhole in the Python port until fixed).
# - Integer vectors are arrayrefs blessed into ...::Runtime::IVec so int-ness
#   survives swizzles and copies (uvec hash seeds keep full precision).
# - float32 rounding is pack/unpack('f') (Perl has no native float32).
# - Screen-space derivatives use the FINE 2x2-quad record/replay model.

use strict;
use warnings;
use POSIX ();

use Math::Fractal::Noisemaker::UintMath qw(
    u32 umul uadd usub ushl ushr uand uor uxor fdiv
);
use Math::Fractal::Noisemaker::Sampler ();

use constant _U32 => 0xFFFFFFFF;

my $INF = 9**9**9;
my $NAN = $INF - $INF;
my $PI  = 3.141592653589793;

# Callable both as a plain function f32($x) and as the kernel-facing method
# $rt->f32($x) (the first arg is the blessed runtime in that case).
sub f32 { unpack('f', pack('f', ref $_[0] ? $_[1] : $_[0])) }

sub _s32 { ((int($_[0]) + 0x80000000) & _U32) - 0x80000000 }

sub _is_vec { ref $_[0] eq 'ARRAY' || ref $_[0] eq 'Math::Fractal::Noisemaker::Runtime::IVec' }
sub _is_ivec { ref $_[0] eq 'Math::Fractal::Noisemaker::Runtime::IVec' }

sub _ivec { bless [@{ $_[0] }], 'Math::Fractal::Noisemaker::Runtime::IVec' }

# Snap a float vector to f32 at a storage/consumption boundary. Int vectors
# pass through unchanged.
sub _snap32 {
    my ($v) = @_;
    return $v unless _is_vec($v);
    return $v if _is_ivec($v);
    return [map { f32($_) } @$v];
}

# ---- construction ----

sub new {
    my ($class) = @_;
    return bless {
        _deriv_mode  => undef,    # undef | 'record' | 'replay'
        _deriv_log   => [],
        _deriv_diffs => undef,
        _deriv_i     => 0,
        # Per-render stdlib overrides (CPU adapters replace e.g. sin with a
        # range-reduced variant): name -> coderef(@args) returning the value.
        stdlib_override => {},
    }, $class;
}

sub begin_pixel { }

# ---- screen-space derivatives (2x2-quad record/replay) ----

sub deriv_reset {
    my ($self, $mode, $diffs) = @_;
    $self->{_deriv_mode}  = $mode;
    $self->{_deriv_i}     = 0;
    $self->{_deriv_log}   = [];
    $self->{_deriv_diffs} = $diffs;
}

sub deriv_log { $_[0]{_deriv_log} }

sub _zero_like {
    my ($v) = @_;
    return 0.0 unless _is_vec($v);
    return [(0.0) x scalar @$v];
}

sub _deriv {
    my ($self, $op, $v) = @_;
    my $mode = $self->{_deriv_mode} || '';
    if ($mode eq 'record') {
        # Recorded values snap to f32 — the reference records into a
        # Float32Array (numpy F32 array in the Python port); recording raw
        # deferred f64 would double-round differently in deriv_fine.
        push @{ $self->{_deriv_log} }, [$op, _is_vec($v) ? [map { f32($_) } @$v] : $v + 0];
        $self->{_deriv_i}++;
        return _zero_like($v);
    }
    if ($mode eq 'replay') {
        my $d;
        if ($self->{_deriv_i} < @{ $self->{_deriv_diffs} }) {
            $d = $self->{_deriv_diffs}[ $self->{_deriv_i} ]{$op};
        }
        else {
            $d = _zero_like($v);
        }
        $self->{_deriv_i}++;
        return $d;
    }
    return _zero_like($v);
}

sub dFdx   { $_[0]->_deriv('dFdx',   $_[1]) }
sub dFdy   { $_[0]->_deriv('dFdy',   $_[1]) }
sub fwidth { $_[0]->_deriv('fwidth', $_[1]) }

# Per-pixel FINE screen-space derivatives, matching the reference engine's
# wrapDerivatives: dFdx uses the pixel's own row (chosen by y-parity), dFdy
# its own column (x-parity). `lanes` are the 4 recorded quad-corner logs in
# [LL, LR, UL, UR] order (lower/upper x left/right, bottom-left space).
sub deriv_fine {
    my ($self, $lanes, $x_parity, $y_parity) = @_;
    my ($left, $right)  = ($lanes->[ $y_parity * 2 ], $lanes->[ $y_parity * 2 + 1 ]);
    my ($bottom, $top)  = ($lanes->[$x_parity],       $lanes->[ $x_parity + 2 ]);
    my $n = 0;
    for ($left, $right, $bottom, $top) { $n = @$_ if @$_ > $n }
    my @diffs;
    for my $i (0 .. $n - 1) {
        my $lv = $i < @$left   ? $left->[$i][1]   : 0.0;
        my $rv = $i < @$right  ? $right->[$i][1]  : $lv;
        my $bv = $i < @$bottom ? $bottom->[$i][1] : 0.0;
        my $tv = $i < @$top    ? $top->[$i][1]    : $bv;
        my ($xd, $yd, $wd);
        if (!_is_vec($lv) && !_is_vec($rv) && !_is_vec($bv) && !_is_vec($tv)) {
            $xd = f32($rv - $lv);
            $yd = f32($tv - $bv);
            $wd = f32(abs($xd) + abs($yd));
        }
        else {
            my $w = 0;
            for ($lv, $rv, $bv, $tv) { $w = @$_ if _is_vec($_) && @$_ > $w }
            my (@xdv, @ydv, @wdv);
            for my $k (0 .. $w - 1) {
                my $l = _is_vec($lv) ? $lv->[$k] : $lv;
                my $r = _is_vec($rv) ? $rv->[$k] : $rv;
                my $b = _is_vec($bv) ? $bv->[$k] : $bv;
                my $t = _is_vec($tv) ? $tv->[$k] : $tv;
                my $x = f32($r - $l);
                my $y = f32($t - $b);
                push @xdv, $x;
                push @ydv, $y;
                push @wdv, f32(abs($x) + abs($y));
            }
            ($xd, $yd, $wd) = (\@xdv, \@ydv, \@wdv);
        }
        push @diffs, { dFdx => $xd, dFdy => $yd, fwidth => $wd };
    }
    return \@diffs;
}

# ---- literals ----

sub f { f32($_[1]) }    # float literal
sub i { int($_[1]) }    # int literal

# ---- construction of vectors ----

# Build a vecN (width>1) or scalar (width==1) from scalars/vectors. One
# scalar arg splats. Otherwise components are flattened in order and
# truncated to exactly `width`. base int/uint builds an IVec (values kept
# exact, not float32-rounded).
sub construct {
    my ($self, $width, @rest) = @_;
    # The codegen appends the base tag ('int'/'uint') as a literal trailing
    # string argument only for integer constructs; floats pass no tag.
    my $base = 'float';
    if (@rest && defined $rest[-1] && !ref $rest[-1] && ($rest[-1] eq 'int' || $rest[-1] eq 'uint')) {
        $base = pop @rest;
    }
    my @supplied = grep { defined } @rest;
    if ($base eq 'int' || $base eq 'uint') {
        # Truncate-and-wrap via u32 (Perl int() saturates past IV_MAX where
        # GLSL/JS wrap mod 2^32); _s32 restores the sign for int.
        my $wrap = $base eq 'uint'
            ? \&Math::Fractal::Noisemaker::UintMath::u32
            : sub { _s32(Math::Fractal::Noisemaker::UintMath::u32($_[0])) };
        if (@supplied == 1 && !_is_vec($supplied[0]) && $width > 1) {
            my $iv = $wrap->($supplied[0]);
            return bless [($iv) x $width], 'Math::Fractal::Noisemaker::Runtime::IVec';
        }
        my @ivals;
        for my $c (@supplied) {
            if (_is_vec($c)) { push @ivals, map { $wrap->($_) } @$c }
            else             { push @ivals, $wrap->($c) }
        }
        return $ivals[0] if $width == 1;
        return bless [@ivals[0 .. $width - 1]], 'Math::Fractal::Noisemaker::Runtime::IVec';
    }
    if ($width == 1) {
        my $c = $supplied[0];
        die "construct(1) requires a component\n" unless defined $c;
        return f32(_is_vec($c) ? $c->[0] : $c);
    }
    if (@supplied == 1 && !_is_vec($supplied[0])) {
        my $v = f32($supplied[0]);
        return [($v) x $width];
    }
    my @vals;
    for my $c (@supplied) {
        if (_is_vec($c)) { push @vals, map { f32($_) } @$c }
        else             { push @vals, f32($c) }
    }
    die "construct($width) with no components\n" unless @vals;
    if (@vals < $width) {    # pad by repeating last (defensive)
        push @vals, ($vals[-1]) x ($width - @vals);
    }
    return [@vals[0 .. $width - 1]];
}

# Pass-by-value copy of a function argument, coerced to the DECLARED
# parameter's element type. Float params force float32 (GLSL implicit
# conversion at the call boundary); int/uint params stay integer so a uvecN
# hash seed keeps full precision.
sub copy {
    my ($self, $vec, $base) = @_;
    return f32($vec) unless _is_vec($vec);
    if (defined $base && ($base eq 'int' || $base eq 'uint')) {
        return bless [map { int $_ } @$vec], 'Math::Fractal::Noisemaker::Runtime::IVec';
    }
    return [map { f32($_) } @$vec];
}

# ---- swizzles ----

my %SWIZZLE = (
    x => 0, y => 1, z => 2, w => 3,
    r => 0, g => 1, b => 2, a => 3,
    s => 0, t => 1, p => 2, q => 3,
);

sub swizzle {
    my ($self, $vec, $sw) = @_;
    my @idx = map { $SWIZZLE{$_} } split //, $sw;
    if (_is_ivec($vec)) {
        return int($vec->[ $idx[0] ]) if @idx == 1;
        return bless [@{$vec}[@idx]], 'Math::Fractal::Noisemaker::Runtime::IVec';
    }
    # JS reads a stored f32 element (binary defers the round).
    return f32($vec->[ $idx[0] ]) if @idx == 1;
    return [map { f32($vec->[$_]) } @idx];
}

# Copy-on-write with GLSL value semantics; the emitted
# `$obj = $rt->assign_swizzle($obj, ...)` rebinds obj to this fresh copy.
# A stored vector is f32 in JS; snap the base and the assigned value.
sub assign_swizzle {
    my ($self, $vec, $sw, $value) = @_;
    my @idx = map { $SWIZZLE{$_} } split //, $sw;
    my $v;
    if (_is_ivec($vec)) {
        $v = bless [@$vec], 'Math::Fractal::Noisemaker::Runtime::IVec';
        if (_is_vec($value)) {
            my @val = @$value;
            $v->[ $idx[$_] ] = int $val[$_] for 0 .. $#idx;
        }
        else {
            $v->[$_] = int $value for @idx;
        }
        return $v;
    }
    $v = [map { f32($_) } @$vec];
    if (_is_vec($value)) {
        my @val = map { f32($_) } @$value;
        $v->[ $idx[$_] ] = $val[$_] for 0 .. $#idx;
    }
    else {
        # Scalar writes snap too — the store is into f32 storage (numpy's
        # float32 dtype / JS's Float32Array both round scalar assignments).
        my $sv = f32($value);
        $v->[$_] = $sv for @idx;
    }
    return $v;
}

# ---- operators ----

sub _bc2 {
    my ($fn, $a, $b) = @_;
    if (_is_vec($a)) {
        if (_is_vec($b)) { return [map { $fn->($a->[$_], $b->[$_]) } 0 .. $#$a] }
        return [map { $fn->($_, $b) } @$a];
    }
    if (_is_vec($b)) { return [map { $fn->($a, $_) } @$b] }
    return $fn->($a, $b);
}

sub binary {
    my ($self, $op, $a, $b, $width, $base) = @_;
    $base = 'float' unless defined $base;
    if ($op eq '==' || $op eq '!=' || $op eq '<' || $op eq '>' || $op eq '<=' || $op eq '>='
        || $op eq '&&' || $op eq '||') {
        return _logical($op, $a, $b);
    }
    if ($base eq 'int' || $base eq 'uint'
        || $op eq '&' || $op eq '|' || $op eq '^' || $op eq '<<' || $op eq '>>') {
        return _int_binary($op, $a, $b, $base eq 'uint' ? 'uint' : 'int');
    }
    # Float path: compute raw f64 and DEFER the f32 rounding to the
    # consumption boundaries (see module header).
    my $fn =
          $op eq '+' ? sub { $_[0] + $_[1] }
        : $op eq '-' ? sub { $_[0] - $_[1] }
        : $op eq '*' ? sub { $_[0] * $_[1] }
        : $op eq '/' ? sub { fdiv($_[0], $_[1]) }
        : $op eq '%' ? sub { $_[1] == 0 ? $NAN : POSIX::fmod($_[0], $_[1]) }
        : die "unsupported binary op '$op'\n";
    return _bc2($fn, $a, $b);
}

sub _int_binary {
    my ($op, $a, $b, $base) = @_;
    if (!_is_vec($a) && !_is_vec($b)) {
        return _int_scalar($op, int($a), int($b), $base);
    }
    my $r = _bc2(sub { _int_scalar($op, int($_[0]), int($_[1]), $base) }, $a, $b);
    return bless $r, 'Math::Fractal::Noisemaker::Runtime::IVec';
}

sub _int_scalar {
    my ($op, $a, $b, $base) = @_;
    if ($base eq 'uint') {
        $a &= _U32;
        $b &= _U32;
        return uadd($a, $b) if $op eq '+';
        return usub($a, $b) if $op eq '-';
        return umul($a, $b) if $op eq '*';
        return uand($a, $b) if $op eq '&';
        return uor($a, $b)  if $op eq '|';
        return uxor($a, $b) if $op eq '^';
        return ushl($a, $b) if $op eq '<<';
        return ushr($a, $b) if $op eq '>>';
        return $b ? int($a / $b) : 0 if $op eq '/';
        return $b ? $a % $b : 0       if $op eq '%';
        die "unsupported uint op '$op'\n";
    }
    return _s32($a + $b) if $op eq '+';
    return _s32($a - $b) if $op eq '-';
    return _s32($a * $b) if $op eq '*';
    return _s32($a & $b) if $op eq '&';
    return _s32($a | $b) if $op eq '|';
    return _s32($a ^ $b) if $op eq '^';
    return _s32($a << ($b & 31)) if $op eq '<<';
    if ($op eq '>>') {
        # Perl's >> on a negative IV is a 64-bit LOGICAL shift; GLSL/JS/Python
        # use an arithmetic shift. The low 32 bits of the logical result equal
        # the arithmetic-shift result for int32-range operands; _s32 restores
        # the sign.
        return _s32($a >> ($b & 31));
    }
    if ($op eq '/') { return $b ? _s32(int($a / $b)) : 0 }
    if ($op eq '%') { return $b ? _s32($a - $b * int($a / $b)) : 0 }
    die "unsupported int op '$op'\n";
}

sub _truthy {
    my ($v) = @_;
    return scalar grep { $_ } @$v if _is_vec($v);
    return $v ? 1 : 0;
}

sub _logical {
    my ($op, $a, $b) = @_;
    if ($op eq '==' || $op eq '!=') {
        if (_is_vec($a) || _is_vec($b)) {
            my $all_eq = 1;
            my $n = _is_vec($a) ? scalar @$a : scalar @$b;
            for my $i (0 .. $n - 1) {
                my $x = _is_vec($a) ? $a->[$i] : $a;
                my $y = _is_vec($b) ? $b->[$i] : $b;
                $all_eq = 0, last if $x != $y;
            }
            return $op eq '==' ? $all_eq : (1 - $all_eq);
        }
        return $op eq '==' ? ($a == $b ? 1 : 0) : ($a != $b ? 1 : 0);
    }
    # Ordering comparisons are scalar-only (the codegen routes vector
    # comparisons to lessThan/greaterThan/...). Comparing arrayrefs here
    # would silently compare addresses — fail loudly instead.
    die "scalar relational '$op' applied to a vector\n" if _is_vec($a) || _is_vec($b);
    return ($a < $b  ? 1 : 0) if $op eq '<';
    return ($a > $b  ? 1 : 0) if $op eq '>';
    return ($a <= $b ? 1 : 0) if $op eq '<=';
    return ($a >= $b ? 1 : 0) if $op eq '>=';
    return ((_truthy($a) && _truthy($b)) ? 1 : 0) if $op eq '&&';
    return ((_truthy($a) || _truthy($b)) ? 1 : 0) if $op eq '||';
    die "unsupported logical op '$op'\n";
}

sub unary {
    my ($self, $op, $a, $width) = @_;
    if ($op eq '-') {
        # Defer f32 rounding for vectors (negation is exact); scalars stay f64.
        return -$a unless _is_vec($a);
        return [map { -$_ } @$a];
    }
    return (_truthy($a) ? 0 : 1) if $op eq '!';
    return $a if $op eq '+';
    die "unsupported unary op '$op'\n";
}

# ---- component-wise builtins ----

sub _sign { my $x = $_[0]; return $x if $x != $x; return $x > 0 ? 1.0 : $x < 0 ? -1.0 : 0.0 }
sub _safe_sqrt { my $x = $_[0]; return $NAN if $x != $x || $x < 0; return sqrt $x }
sub _safe_log {
    my $x = $_[0];
    return $NAN  if $x != $x || $x < 0;
    return -$INF if $x == 0;
    return log $x;
}
sub _nmin { my ($a, $b) = @_; return $NAN if $a != $a || $b != $b; $a < $b ? $a : $b }
sub _nmax { my ($a, $b) = @_; return $NAN if $a != $a || $b != $b; $a > $b ? $a : $b }
sub _pow {
    my ($x, $y) = @_;
    my $r = eval { $x**$y };
    return defined $r ? $r : $NAN;
}
sub _clampf { my ($x, $lo, $hi) = @_; _nmin(_nmax($x, $lo), $hi) }
sub _mixf { my ($a, $b, $t) = @_; $a * (1.0 - $t) + $b * $t }
sub _smoothstepf {
    my ($e0, $e1, $x) = @_;
    # IEEE zero-width band: e0==e1 yields nan/inf like JS, clamp resolves it.
    my $t = _clampf(fdiv($x - $e0, $e1 - $e0), 0.0, 1.0);
    return $t * $t * (3.0 - 2.0 * $t);
}
sub _glsl_modf {
    my ($x, $y) = @_;
    my $q = fdiv($x, $y);
    return $NAN if $q != $q;
    return $x - $y * POSIX::floor($q);
}

my %COMPONENT = (
    abs         => sub { abs $_[0] },
    isnan       => sub { $_[0] != $_[0] ? 1.0 : 0.0 },
    floor       => sub { POSIX::floor($_[0]) },
    ceil        => sub { POSIX::ceil($_[0]) },
    fract       => sub { $_[0] - POSIX::floor($_[0]) },
    sign        => \&_sign,
    sqrt        => \&_safe_sqrt,
    inversesqrt => sub { fdiv(1.0, _safe_sqrt($_[0])) },
    sin         => sub { sin $_[0] },
    cos         => sub { cos $_[0] },
    tan         => sub { POSIX::tan($_[0]) },
    asin        => sub { POSIX::asin($_[0]) },
    acos        => sub { POSIX::acos($_[0]) },
    atan        => sub { POSIX::atan($_[0]) },    # native libm atan, matching Math.atan/np.arctan
    sinh        => sub { POSIX::sinh($_[0]) },
    cosh        => sub { POSIX::cosh($_[0]) },
    tanh        => sub { POSIX::tanh($_[0]) },
    exp         => sub { exp $_[0] },
    log         => \&_safe_log,
    exp2        => sub { 2**$_[0] },              # the JS oracle uses Math.pow(2, x) too
    log2        => sub { POSIX::log2($_[0]) },    # native libm log2 (log(x)/log(2) differs ~1 ULP often)
    radians     => sub { $_[0] * ($PI / 180.0) },
    degrees     => sub { $_[0] * (180.0 / $PI) },
    min         => \&_nmin,
    max         => \&_nmax,
    pow         => \&_pow,
    clamp       => \&_clampf,
    mix         => \&_mixf,
    step        => sub { $_[1] < $_[0] ? 0.0 : 1.0 },
    smoothstep  => \&_smoothstepf,
    mod         => \&_glsl_modf,
    trunc       => sub { POSIX::trunc($_[0]) },
    round       => sub { POSIX::floor($_[0] + 0.5) },
);

my %RELATIONAL = (
    lessThan         => sub { $_[0] < $_[1] ? 1 : 0 },
    lessThanEqual    => sub { $_[0] <= $_[1] ? 1 : 0 },
    greaterThan      => sub { $_[0] > $_[1] ? 1 : 0 },
    greaterThanEqual => sub { $_[0] >= $_[1] ? 1 : 0 },
    equal            => sub { $_[0] == $_[1] ? 1 : 0 },
    notEqual         => sub { $_[0] != $_[1] ? 1 : 0 },
);

sub _bcn {
    my ($fn, @args) = @_;
    my $w;
    for (@args) { $w = scalar @$_ if _is_vec($_) && !defined $w }
    return $fn->(@args) unless defined $w;
    my @out;
    for my $i (0 .. $w - 1) {
        push @out, $fn->(map { _is_vec($_) ? $_->[$i] : $_ } @args);
    }
    return \@out;
}

sub component_wise {
    my ($self, $name, @args) = @_;
    my $ov = $self->{stdlib_override}{$name};
    return $ov->(@args) if $ov;
    if ($name eq 'atan' && @args == 2) {    # atan(y, x) -> atan2
        my $r = _bcn(sub { atan2($_[0], $_[1]) }, @args);
        return _is_vec($r) ? [map { f32($_) } @$r] : f32($r);
    }
    if (my $rel = $RELATIONAL{$name}) {     # lessThan/equal/... -> bvec
        my ($a, $b) = map { _snap32($_) } @args;
        my $r = _bcn($rel, $a, $b);
        return _is_vec($r) ? $r : [$r];
    }
    if ($name eq 'any') { return _truthy($args[0]) ? 1 : 0 }
    if ($name eq 'all') {
        my $v = $args[0];
        return ($v ? 1 : 0) unless _is_vec($v);
        for (@$v) { return 0 unless $_ }
        return 1;
    }
    if ($name eq 'not') {
        my $v = $args[0];
        return ($v ? 0 : 1) unless _is_vec($v);
        return [map { $_ ? 0 : 1 } @$v];
    }
    # Snap vector args to f32 first (JS applies these to stored Float32Array
    # values), then compute in float64 and round the result to f32.
    my $fn = $COMPONENT{$name} or die "unsupported builtin '$name'\n";
    my @snapped = map { _is_vec($_) ? _snap32($_) : $_ } @args;
    my $r = _bcn($fn, @snapped);
    return _is_vec($r) ? [map { f32($_) } @$r] : f32($r);
}

# ---- texture ----

sub texture {
    my ($self, $sampler, $uv) = @_;
    # Sample at f32 coords — JS reads the uv from a stored Float32Array
    # (binary defers the round).
    my $u = f32($uv->[0]);
    my $v = f32($uv->[1]);
    if (($sampler->filter || 'nearest') eq 'linear') {
        return Math::Fractal::Noisemaker::Sampler::sample_bilinear($sampler, $u, $v);
    }
    return Math::Fractal::Noisemaker::Sampler::sample_nearest_bottom_left($sampler, $u, $v);
}

sub texture_size {
    my ($self, $sampler) = @_;
    return [0.0 + $sampler->width, 0.0 + $sampler->height];
}

sub texel_fetch {
    my ($self, $sampler, $coord, $lod) = @_;
    my ($w, $h) = ($sampler->width, $sampler->height);
    my $x = int($coord->[0]);
    $x = 0 if $x < 0;
    $x = $w - 1 if $x > $w - 1;
    # GL bottom-left origin -> top-down storage row flip (integer texel).
    my $ty = $h - 1 - int($coord->[1]);
    $ty = 0 if $ty < 0;
    $ty = $h - 1 if $ty > $h - 1;
    my $i = ($ty * $w + $x) * 4;
    my $d = $sampler->data;
    return [@{$d}[$i .. $i + 3]];
}

# ---- uint32 / half-float primitives (delegate to bit-exact UintMath) ----

sub pcg3d {
    my ($self, $v) = @_;
    my $r = Math::Fractal::Noisemaker::UintMath::pcg3d([map { int($_) & _U32 } @$v]);
    return bless $r, 'Math::Fractal::Noisemaker::Runtime::IVec';
}

sub hash_uint { Math::Fractal::Noisemaker::UintMath::hash_uint32(int($_[1]) & _U32) }

sub float_bits_to_uint { Math::Fractal::Noisemaker::UintMath::float_bits_to_uint(0.0 + $_[1]) }

sub uint_bits_to_float { f32(Math::Fractal::Noisemaker::UintMath::uint_bits_to_float(int($_[1]) & _U32)) }

sub pack_half_2x16 { Math::Fractal::Noisemaker::UintMath::pack_half_2x16([0.0 + $_[1][0], 0.0 + $_[1][1]]) }

sub unpack_half_2x16 {
    my $r = Math::Fractal::Noisemaker::UintMath::unpack_half_2x16(Math::Fractal::Noisemaker::UintMath::u32($_[1]));
    return [map { f32($_) } @$r];
}

sub to_int {
    my ($self, $x) = @_;
    # GLSL int(float) truncates toward zero, then wraps. Route through u32 so
    # huge floats WRAP mod 2^32 (Perl int() saturates at IV_MAX past 2^63).
    # The vector path mirrors the reference's plain int64 cast (no 32-bit wrap).
    return _s32(Math::Fractal::Noisemaker::UintMath::u32($x)) unless _is_vec($x);
    return bless [map { int $_ } @$x], 'Math::Fractal::Noisemaker::Runtime::IVec';
}

sub to_uint {
    my ($self, $x) = @_;
    return Math::Fractal::Noisemaker::UintMath::u32($x) unless _is_vec($x);
    return bless [map { Math::Fractal::Noisemaker::UintMath::u32($_) } @$x],
        'Math::Fractal::Noisemaker::Runtime::IVec';
}

# ---- vector geometry (snap args to f32, accumulate float64, round once) ----
#
# NB: this package defines subs named `length`, `f`, and `i` (kernel-facing
# methods). Inside this file, always call the builtins as CORE::length etc.
# if ever needed — a bareword call would resolve to the method.

sub _dot_raw {
    my ($a, $b) = @_;
    my $s = 0;
    $s += $a->[$_] * $b->[$_] for 0 .. $#$a;
    return $s;
}

sub dot {
    my ($self, $a, $b) = @_;
    return f32(_dot_raw(_snap32($a), _snap32($b)));
}

sub length {
    my ($self, $a) = @_;
    # JS length is F32(sqrt(dot)), and its dot is itself F32-rounded — so the
    # squared magnitude is rounded to f32 before the sqrt.
    my $v = _snap32($a);
    return f32(sqrt(f32(_dot_raw($v, $v))));
}

sub distance {
    my ($self, $a, $b) = @_;
    my $av = _snap32($a);
    my $bv = _snap32($b);
    my @d = map { $av->[$_] - $bv->[$_] } 0 .. $#$av;
    return f32(sqrt(_dot_raw(\@d, \@d)));
}

sub normalize {
    my ($self, $a) = @_;
    my $v = _snap32($a);
    # JS normalize divides by length(), which is f32-rounded.
    my $mag = f32(sqrt(_dot_raw($v, $v)));
    return [(0.0) x scalar @$v] if $mag == 0.0;
    return [map { f32($_ / $mag) } @$v];
}

sub cross {
    my ($self, $a, $b) = @_;
    my ($ax, $ay, $az) = @$a;
    my ($bx, $by, $bz) = @$b;
    return [
        f32($ay * $bz - $az * $by),
        f32($az * $bx - $ax * $bz),
        f32($ax * $by - $ay * $bx),
    ];
}

sub reflect {
    my ($self, $i, $n) = @_;
    my $d = _dot_raw($n, $i);
    return [map { f32($i->[$_] - 2.0 * $d * $n->[$_]) } 0 .. $#$i];
}

sub refract {
    my ($self, $i, $n, $eta) = @_;
    my $e = 0.0 + $eta;
    my $d = _dot_raw($n, $i);
    my $k = 1.0 - $e * $e * (1.0 - $d * $d);
    return [(0.0) x scalar @$i] if $k < 0.0;
    my $c = $e * $d + sqrt($k);
    return [map { f32($e * $i->[$_] - $c * $n->[$_]) } 0 .. $#$i];
}

# ---- matrices (flat, column-major: element [col*N + row]) ----

sub matrix_mult {
    my ($self, $a, $b, $dim) = @_;
    my $n = int $dim;
    my $a_mat = @$a == $n * $n;
    my $b_mat = @$b == $n * $n;
    my @r;
    if ($a_mat && $b_mat) {    # GLSL A*B, both column-major
        for my $i (0 .. $n - 1) {
            for my $j (0 .. $n - 1) {
                my $s = 0;
                $s += $b->[ $i * $n + $_ ] * $a->[ $_ * $n + $j ] for 0 .. $n - 1;
                $r[ $i * $n + $j ] = f32($s);
            }
        }
    }
    elsif ($a_mat) {           # mat * vec
        for my $j (0 .. $n - 1) {
            my $s = 0;
            $s += $b->[$_] * $a->[ $_ * $n + $j ] for 0 .. $n - 1;
            $r[$j] = f32($s);
        }
    }
    else {                     # vec * mat
        for my $i (0 .. $n - 1) {
            my $s = 0;
            $s += $b->[ $i * $n + $_ ] * $a->[$_] for 0 .. $n - 1;
            $r[$i] = f32($s);
        }
    }
    return \@r;
}

sub mat_col {
    my ($self, $mat, $i, $dim) = @_;
    my $n = int $dim;
    my $c = int $i;
    return [map { f32($_) } @{$mat}[ $c * $n .. ($c + 1) * $n - 1 ]];
}

# ---- arrays (GLSL fixed-size arrays -> Perl arrayrefs) ----

sub new_array {
    my ($self, $n, $width) = @_;
    $n = int $n;
    $width = 1 unless defined $width;
    return [(0.0) x $n] if $width <= 1;
    return [map { [(0.0) x $width] } 1 .. $n];
}

sub array {
    my ($self, $elems) = @_;
    return [@$elems];
}

sub bit_not {
    my ($self, $x) = @_;
    return _s32(-int($x) - 1) unless _is_vec($x);
    return bless [map { -int($_) - 1 } @$x], 'Math::Fractal::Noisemaker::Runtime::IVec';
}

package Math::Fractal::Noisemaker::Runtime::IVec;
# Blessed arrayref marking an integer (ivec/uvec) vector.

1;
