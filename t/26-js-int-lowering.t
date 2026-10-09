use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Math::Fractal::Noisemaker::Runtime;
use Math::Fractal::Noisemaker::Transpiler::Codegen qw(emit_perl);
use Math::Fractal::Noisemaker::Transpiler::Parser qw(parse);
use Math::Fractal::Noisemaker::Transpiler::Preprocess qw(normalize);

# filter/spookyTicker's pinned authority capture follows the oracle's
# transpiled-JS lowering, not strict GLSL integer semantics: scalar int/int
# divisions stay float64 (the noisemaker-for-cpu restoreIntegerDivision
# scalar/scalar rewrite is exempt for this effect), the float64 flows through
# the arithmetic that consumes it, scalar uint bitwise ops coerce through
# ToInt32 (arithmetic >>, signed ^, signed %), and array reads with fractional,
# negative or out-of-range indices yield undefined (bitwise consumers coerce
# that to 0). Every other effect keeps the strict GLSL lowering.

my $GLYPH_GLSL = <<'GLSL';
precision highp float;
precision highp int;
out vec4 fragColor;
int GLYPHS[8];
int sample_glyph(int digit, int localX, int localY, int iScale) {
    int gx = localX / iScale;
    int gy = localY / iScale;
    if (gx < 0 || gx >= 7 || gy < 0 || gy >= 8) { return 0; }
    int row = GLYPHS[digit * 8 + gy];
    return int((row >> (6 - gx)) & 1);
}
void main() {
    int a = 48;
    int w = 21;
    int cellX = a >= 0 ? a / w : (a - w + 1) / w;
    int localX = a - cellX * w;
    fragColor = vec4(float(sample_glyph(1, localX, 0, 3)));
}
GLSL

# --- codegen: the effect-scoped lowering -----------------------------------

sub emit_for {
    my ($effect_id) = @_;
    my $norm = normalize($GLYPH_GLSL, {});
    return emit_perl(parse($norm->{source}), $norm->{outputs}, $norm->{varyings}, $effect_id);
}

my $js   = emit_for('filter/spookyTicker');
my $glsl = emit_for('filter/invert');

# Scalar/scalar int division stays float64 for the exempted effect only.
like $js,   qr{binary\('/', \$localX, \$iScale, 1, 'float'\)}, 'spookyTicker gx division stays float64';
like $glsl, qr{binary\('/', \$localX, \$iScale, 1, 'int'\)},   'other effects keep truncating int division';

# The float64 result keeps flowing float64 through consuming arithmetic.
like $js,   qr{binary\('\*', \$cellX, \$w, 1, 'float'\)}, 'spookyTicker localX multiply stays float64';
like $glsl, qr{binary\('\*', \$cellX, \$w, 1, 'int'\)},   'other effects truncate cellX at the multiply';

# Fractional/negative/out-of-range array reads yield the JS undefined (0).
like $js, qr{binary\('\+', .*'float'\)\) >= 0 .* scalar\(\@\{\$g->\{GLYPHS\}\}\)}, 'spookyTicker array read is JS-guarded';
unlike $glsl, qr{scalar\(\@\{\$g->\{GLYPHS\}\}\)}, 'other effects read arrays with the plain int() wrap';

# The kernel opts into the runtime's JS-native uint lowering, scoped locally.
like $js,   qr{local \$rt->\{js_native_ints\} = 1;}, 'spookyTicker kernel sets the JS-native uint flag';
unlike $glsl, qr{js_native_ints}, 'other kernels do not set the flag';

# The vec-index restoreIntegerDivision form still truncates for every effect.
my $vec_norm = normalize(<<'GLSL', {});
precision highp float;
precision highp int;
out vec4 fragColor;
uniform ivec3 texel;
uniform int volSize;
void main() {
    int z = texel[1] / volSize;
    fragColor = vec4(float(z));
}
GLSL
my $vec_js = emit_perl(parse($vec_norm->{source}), $vec_norm->{outputs}, $vec_norm->{varyings}, 'filter/spookyTicker');
like $vec_js, qr{binary\('/', .*?1, 'int'\)}, 'vec-index int division truncates even for the exempted effect';

# --- runtime: the JS-native uint semantics ---------------------------------

my $rt = Math::Fractal::Noisemaker::Runtime->new;

# Without the flag: GLSL uint semantics (logical shift, unsigned modulo).
is $rt->binary('>>', 4241615619, 15, 1, 'uint'), 129443, 'default >> stays a logical u32 shift';
is $rt->binary('%', 4241615619, 10, 1, 'uint'), 9,      'default % is an unsigned u32 modulo';

# With the flag: the oracle's transpiled JS operators.
{
    local $rt->{js_native_ints} = 1;
    is $rt->binary('>>', 4241615619, 15, 1, 'uint'), -1629, 'js >> is an arithmetic ToInt32 shift';
    is $rt->binary('>>', 4294967295, 16, 1, 'uint'), -1,    'js >> sign-fills negative int32 values';
    is $rt->binary('%', -5, 10, 1, 'uint'), -5,             'js % keeps the dividend sign';
    # The spookyTicker hash chain end to end (uint(1) * 7919 -> 7919), exactly
    # as the oracle's canonical kernel evaluates it.
    my $v = $rt->binary('*', 1, 7919, 1, 'uint');
    $v = $rt->binary('^', $v, $rt->binary('>>', $v, 16, 1, 'uint'), 1, 'uint');
    $v = $rt->binary('*', $v, 2146121005, 1, 'uint');
    $v = $rt->binary('^', $v, $rt->binary('>>', $v, 15, 1, 'uint'), 1, 'uint');
    $v = $rt->binary('*', $v, 2221713035, 1, 'uint');
    $v = $rt->binary('^', $v, $rt->binary('>>', $v, 16, 1, 'uint'), 1, 'uint');
    is $v, 174598519, 'js uint chain matches the oracle hash_mix body';
    is $rt->binary('^', $v, 17, 1, 'uint') & 65535, 10598, 'masking a signed xor result keeps the u32 bits';
}

# The flag is dynamically scoped: an unqualified runtime stays GLSL-faithful.
is $rt->{js_native_ints}, undef, 'the JS-native flag does not leak past its scope';

done_testing();
