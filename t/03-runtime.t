use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Math::Fractal::Noisemaker::Runtime;

my $rt = Math::Fractal::Noisemaker::Runtime->new;

sub feq {
    my ($got, $want, $name) = @_;
    cmp_ok(abs($got - $want), '<=', abs($want) * 1e-12 + 1e-12, $name)
        or diag("got $got want $want");
}
sub veq {
    my ($got, $want, $name) = @_;
    is(scalar @$got, scalar @$want, "$name width");
    feq($got->[$_], $want->[$_], "$name [$_]") for 0 .. $#$want;
}

# Goldens generated from the Python runtime (167/167 parity-proven).

# Deferred rounding: the compound (a/b + c) rounds ONCE at the boundary.
my $a = $rt->construct(2, 0.1, 0.2);
my $b = $rt->construct(2, 0.3, 0.7);
my $c = $rt->construct(2, 1e-8, 2.5);
my $chain = $rt->binary('+', $rt->binary('/', $a, $b, 2, 'float'), $c, 2, 'float');
feq($rt->swizzle($chain, 'x'), 0.3333333432674408, 'chain swizzle x (deferred round)');
feq($rt->swizzle($chain, 'y'), 2.7857143878936768, 'chain swizzle y');
feq($rt->dot($chain, $chain), 7.871315956115723, 'chain dot');
feq($rt->length($chain), 2.805586576461792, 'chain length (double-rounded)');

veq($rt->normalize($rt->construct(3, 0.5, 0.5, 1.0)),
    [0.40824827551841736, 0.40824827551841736, 0.8164965510368347], 'normalize');

veq($rt->component_wise('mix', $a, $b, $rt->f(0.3)),
    [0.1600000113248825, 0.3499999940395355], 'mix');
feq($rt->component_wise('smoothstep', $rt->f(0.2), $rt->f(0.8), $rt->f(0.5)),
    0.4999999701976776, 'smoothstep');
feq($rt->component_wise('smoothstep', $rt->f(0.5), $rt->f(0.5), $rt->f(0.7)),
    1.0, 'smoothstep zero-width band (IEEE inf -> clamp)');
feq($rt->component_wise('mod', $rt->f(-1.3), $rt->f(1.0)), 0.7000000476837158, 'glsl mod');
feq($rt->component_wise('pow', $rt->f(2.0), $rt->f(0.5)), 1.4142135381698608, 'pow');
veq($rt->component_wise('fract', $rt->binary('*', $a, $rt->f(7.3), 2, 'float')),
    [0.7300000190734863, 0.46000003814697266], 'fract of deferred product');
veq($rt->component_wise('step', $rt->f(0.15), $a), [0.0, 1.0], 'step');
veq($rt->component_wise('clamp', $rt->construct(2, -0.5, 1.5), $rt->f(0.0), $rt->f(1.0)),
    [0.0, 1.0], 'clamp');
feq($rt->component_wise('atan', $rt->f(1.0), $rt->f(2.0)), 0.46364760398864746, 'atan2');

# int / uint vectors
my $u = $rt->construct(3, $rt->i(7), $rt->i(11), $rt->i(4294967295), 'uint');
is_deeply([@{ $rt->binary('*', $u, $rt->construct(3, $rt->i(1664525), 'uint'), 3, 'uint') }],
          [11651675, 18309775, 4293302771], 'uvec wrapping multiply');
is_deeply([@{ $rt->pcg3d($rt->construct(3, $rt->i(1), $rt->i(2), $rt->i(3), 'uint')) }],
          [4204755366, 1223881804, 1500469937], 'pcg3d via runtime');
is_deeply([@{ $rt->binary('/', $rt->construct(2, $rt->i(-7), $rt->i(9), 'int'),
                               $rt->construct(2, $rt->i(2), $rt->i(-4), 'int'), 2, 'int') }],
          [-3, -2], 'ivec division truncates toward zero');
is($rt->to_int(-2.7), -2, 'to_int truncates toward zero');
is($rt->binary('<<', $rt->i(3), $rt->i(30), 1, 'uint'), 3221225472, 'uint shift');

my $iv = $rt->construct(3, $rt->i(5), $rt->i(6), $rt->i(7), 'int');
is($rt->swizzle($iv, 'z'), 7, 'ivec swizzle scalar stays int');
my $sub = $rt->swizzle($iv, 'xy');
is(ref $sub, 'Math::Fractal::Noisemaker::Runtime::IVec', 'ivec swizzle stays IVec');
is_deeply([@$sub], [5, 6], 'ivec swizzle values');

# assign_swizzle copy-on-write
my $v0 = $rt->construct(3, 1.0, 2.0, 3.0);
my $v1 = $rt->assign_swizzle($v0, 'xz', $rt->construct(2, 9.0, 8.0));
is_deeply([@$v0], [1.0, 2.0, 3.0], 'assign_swizzle leaves source untouched');
is_deeply([@$v1], [9.0, 2.0, 8.0], 'assign_swizzle result');

# matrices, reflect/refract
veq($rt->matrix_mult($rt->construct(4, 1.0, 2.0, 3.0, 4.0), $rt->construct(2, 5.0, 6.0), 2),
    [23.0, 34.0], 'mat2 * vec2');
veq($rt->matrix_mult($rt->construct(4, 1.0, 2.0, 3.0, 4.0),
                     $rt->construct(4, 7.0, 8.0, 9.0, 10.0), 2),
    [31.0, 46.0, 39.0, 58.0], 'mat2 * mat2 (column-major)');
veq($rt->reflect($rt->construct(2, 1.0, -1.0), $rt->construct(2, 0.0, 1.0)), [1.0, 1.0], 'reflect');
veq($rt->refract($rt->construct(2, 0.0, -1.0), $rt->construct(2, 0.0, 1.0), $rt->f(0.9)),
    [0.0, -1.0], 'refract');

is($rt->float_bits_to_uint(0.7), 1060320051, 'float_bits_to_uint');
is($rt->pack_half_2x16($rt->construct(2, 0.25, -3.5)), 3271570432, 'pack_half_2x16');

# stdlib_override hook
$rt->{stdlib_override}{sin} = sub { 42.0 };
is($rt->component_wise('sin', $rt->f(1.0)), 42.0, 'stdlib_override wins');
delete $rt->{stdlib_override}{sin};

# derivatives record/replay basics
$rt->deriv_reset('record');
my $z = $rt->dFdx(1.5);
is($z, 0.0, 'record mode returns zero');
is_deeply($rt->deriv_log->[0], ['dFdx', 1.5], 'record captured op+value');
$rt->deriv_reset('replay', [{ dFdx => 0.25, dFdy => 0.5, fwidth => 0.75 }]);
is($rt->dFdx(1.5), 0.25, 'replay returns fine diff');
$rt->deriv_reset(undef);

# --- review regression goldens (python-verified) ---

# negative int >> is ARITHMETIC (Perl's raw >> on negative IVs is logical-64)
is($rt->binary('>>', -8, 2, 1, 'int'), -2, 'negative int >> arithmetic');
is($rt->binary('>>', -1, 31, 1, 'int'), -1, 'int -1 >> 31 stays -1');

# huge floats WRAP mod 2^32 (Perl int() saturates past IV_MAX)
is($rt->to_uint(1e20), 1661992960, 'to_uint(1e20) wraps like JS >>> 0');
is($rt->to_int(-1e20), -1661992960, 'to_int(-1e20) wraps signed');

# NaN propagation through min/max/clamp/sign (numpy semantics)
my $qnan = 9**9**9 - 9**9**9;
my $mn = $rt->component_wise('min', $rt->f(1.0), $qnan);
ok($mn != $mn, 'min(1, NaN) is NaN');
my $sg = $rt->component_wise('sign', $qnan);
ok($sg != $sg, 'sign(NaN) is NaN');

# deriv record snaps raw deferred-f64 vectors to f32 (Float32Array semantics)
$rt->deriv_reset('record');
my $rawv = $rt->binary('/', $rt->construct(2, 0.1, 0.2), $rt->construct(2, 0.3, 0.7), 2, 'float');
$rt->dFdx($rawv);
my $rec = $rt->deriv_log->[0][1];
feq($rec->[0], 0.3333333134651184, 'deriv record snaps [0]');
feq($rec->[1], 0.2857142984867096, 'deriv record snaps [1]');
$rt->deriv_reset(undef);

# fdiv honors negative-zero denominators
is(Math::Fractal::Noisemaker::UintMath::fdiv(5.0, -0.0), -(9**9**9), 'fdiv(5, -0.0) = -Inf');

done_testing();
