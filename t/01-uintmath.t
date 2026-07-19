use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Math::Fractal::Noisemaker::UintMath qw(
    u32 umul uadd usub ushl ushr uand uor uxor
    glsl_mod pcg3d hash_uint32
    float_bits_to_uint uint_bits_to_float
    pack_half_2x16 unpack_half_2x16 fdiv
);

# Golden vectors generated from the Python port (itself proven bit-exact
# against the JS oracle across 167 effects).

my @umul = ([4294967295,374761393,3920205903],[1664525,1013904223,182531539],
            [2654435761,97,4077198353],[123456789,987654321,4227814277],
            [2147483648,3,2147483648],[4294967295,4294967295,1]);
is(umul($_->[0],$_->[1]), $_->[2], "umul($_->[0],$_->[1])") for @umul;

my @uadd = ([4294967295,1,0],[2147483647,2147483647,4294967294],[7,9,16]);
is(uadd($_->[0],$_->[1]), $_->[2], "uadd") for @uadd;

my @usub = ([0,1,4294967295],[5,10,4294967291],[4294967295,4294967294,1]);
is(usub($_->[0],$_->[1]), $_->[2], "usub") for @usub;

my @ushl = ([1,31,2147483648],[4294967295,4,4294967280],[3,33,6]);
is(ushl($_->[0],$_->[1]), $_->[2], "ushl (shift count masked)") for @ushl;

my @ushr = ([2147483648,31,1],[4294967295,16,65535],[7,33,3]);
is(ushr($_->[0],$_->[1]), $_->[2], "ushr (shift count masked)") for @ushr;

my @pcg = ([[0,0,0],[2611992518,2833812075,1058359340]],
           [[1,2,3],[4204755366,1223881804,1500469937]],
           [[4294967295,12345,67890],[4093664991,2632112527,615798276]],
           [[2147483648,4000000000,999999999],[1605979321,1388827049,3948892479]]);
for my $c (@pcg) {
    is_deeply(pcg3d($c->[0]), $c->[1], "pcg3d(@{$c->[0]})");
}

my @hash = ([0,0],[1,1753845952],[42,388445122],[4294967295,1734902346],[2654435761,1834104592]);
is(hash_uint32($_->[0]), $_->[1], "hash_uint32($_->[0])") for @hash;

my @fbits = ([0.0,0],[1.0,1065353216],[-1.0,3212836864],[0.5,1056964608],
             [3.14159,1078530000],[1e-40,71362]);
is(float_bits_to_uint($_->[0]), $_->[1], "float_bits_to_uint($_->[0])") for @fbits;

# round trip
for my $bits (0, 1065353216, 3212836864, 1078530000) {
    is(float_bits_to_uint(uint_bits_to_float($bits)), $bits, "bits round trip $bits");
}

my @packh = ([[0.0,0.0],0],[[1.0,-1.0],3154131968],[[0.5,65504.0],2080323584],
             [[1e-08,-2.5],3238002688],[[70000.0,0.1],778468352]);
is(pack_half_2x16($_->[0]), $_->[1], "pack_half_2x16") for @packh;

# unpack inverse (on exactly-representable halves)
my $pair = unpack_half_2x16(pack_half_2x16([1.0, -2.5]));
cmp_ok(abs($pair->[0] - 1.0),  '<', 1e-7, "unpack half lo");
cmp_ok(abs($pair->[1] + 2.5),  '<', 1e-7, "unpack half hi");

# u32 coercion of floats / negatives / huge values (JS ToUint32 semantics)
my @u32f = ([-1,4294967295],[-2.7,4294967294],[3.9,3],[1e+20,1661992960],[-1e+20,2632974336]);
is(u32($_->[0]), $_->[1], "u32($_->[0])") for @u32f;
my $nan = fdiv(0,0);
is(u32($nan), 0, "u32(NaN) == 0");
is(u32(9**9**9), 0, "u32(Inf) == 0");

# glsl_mod: floored modulo + IEEE zero-divide propagation
is(glsl_mod(5.5, 2.0), 1.5, "glsl_mod positive");
is(glsl_mod(-1.0, 3.0), 2.0, "glsl_mod floored (not truncated)");
my $gm = glsl_mod(1.0, 0.0);
ok($gm != $gm, "glsl_mod(x, 0) is NaN");

# fdiv IEEE semantics
is(fdiv(1,0), 9**9**9, "fdiv 1/0 = +Inf");
is(fdiv(-1,0), -(9**9**9), "fdiv -1/0 = -Inf");
ok(fdiv(0,0) != fdiv(0,0), "fdiv 0/0 = NaN");

done_testing();
