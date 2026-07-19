use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Math::Fractal::Noisemaker::Surface;
use Math::Fractal::Noisemaker::TextureFormat qw(float16_truncate quantize_texture);
use Math::Fractal::Noisemaker::Sampler qw(sample_nearest sample_nearest_bottom_left sample_bilinear);
use Math::Fractal::Noisemaker::PNG qw(encode_png decode_png);

# Goldens generated from the Python port (proven vs the JS oracle).

sub feq {
    my ($got, $want, $name) = @_;
    if ($want != $want) { ok($got != $got, $name); return }
    cmp_ok(abs($got - $want), '<=', abs($want) * 1e-12 + 1e-12, $name)
        or diag("got $got want $want");
}

# --- float16 truncate ---
my @f16 = ([0.0,0.0],[1.0,1.0],[-1.0,-1.0],[0.1,0.0999755859375],
           [0.30000001192092896,0.2998046875],[3.14159,3.140625],
           [100000.0,65504.0],[-70000.0,-65504.0],
           [1e-05,9.953975677490234e-06],[6.1e-05,6.097555160522461e-05],
           [5.96e-08,0.0],[1e-10,0.0],[-0.333333333,-0.333251953125]);
feq(float16_truncate($_->[0]), $_->[1], "f16_truncate($_->[0])") for @f16;

# --- Surface to_rgba8 edge cases (nan/inf/clamp/rounding) ---
my $inf = 9**9**9;
my $nan = $inf - $inf;
my $s = Math::Fractal::Noisemaker::Surface->new(2, 2,
    [0.0,0.5,1.0,2.0, -1.0,$nan,$inf,0.24901961, 0.25098039,0.99803922,0.001,0.998, 0.5019608,0.25,0.75,1.0]);
is_deeply([unpack('C*', $s->to_rgba8)],
          [0,128,255,255, 0,0,0,64, 64,255,0,254, 128,64,191,255],
          'to_rgba8 edge cases match python');

# --- from_rgba8 f32 scaling ---
my $s8 = Math::Fractal::Noisemaker::Surface->from_rgba8(1, 1, pack('C4', 0, 127, 128, 255));
my @from8 = ([0,0.0],[127,0.49803921580314636],[128,0.501960813999176],[255,1.0]);
feq($s8->data->[$_], $from8[$_][1], "from_rgba8 byte $from8[$_][0]") for 0 .. 3;

# --- Samplers on a 4x4 arange surface ---
my $sf = Math::Fractal::Noisemaker::Surface->new(4, 4, [map { $_ + 0.0 } 0 .. 63]);
my @coords = ([0.3,0.3],[0.55,0.7],[0.1,0.9],[0.42,0.18],[0.77,0.63],
              [0.0,0.0],[1.0,1.0],[-0.2,0.5],[0.5,1.3]);
my @nearest = ([20,21,22,23],[40,41,42,43],[48,49,50,51],[4,5,6,7],[44,45,46,47],
               [0,1,2,3],[60,61,62,63],[32,33,34,35],[56,57,58,59]);
my @nearest_bl = ([36,37,38,39],[24,25,26,27],[0,1,2,3],[52,53,54,55],[28,29,30,31],
                  [48,49,50,51],[12,13,14,15],[16,17,18,19],[8,9,10,11]);
my @bilinear = ([39.599998474121094,40.599998474121094,41.599998474121094,42.599998474121094],
                [18,19,20,21],[0,1,2,3],
                [49.20000076293945,50.20000076293945,51.20000076293945,52.20000076293945],
                [26,27,28,29],[48,49,50,51],[12,13,14,15],[24,25,26,27],[6,7,8,9]);
for my $i (0 .. $#coords) {
    my ($u, $v) = @{ $coords[$i] };
    is_deeply(sample_nearest($sf, $u, $v), $nearest[$i], "nearest($u,$v)");
    is_deeply(sample_nearest_bottom_left($sf, $u, $v), $nearest_bl[$i], "nearest_bl($u,$v)");
    my $b = sample_bilinear($sf, $u, $v);
    feq($b->[$_], $bilinear[$i][$_], "bilinear($u,$v)[$_]") for 0 .. 3;
}

# --- quantize_texture rgba16f in place ---
my $q = Math::Fractal::Noisemaker::Surface->new(1, 1, [0.1, 0.30000001192092896, 3.14159, 1.0]);
quantize_texture($q, 'rgba16f');
feq($q->data->[0], 0.0999755859375, 'quantize rgba16f [0]');
feq($q->data->[1], 0.2998046875,    'quantize rgba16f [1]');
feq($q->data->[2], 3.140625,        'quantize rgba16f [2]');

# --- PNG round trip ---
my $img = Math::Fractal::Noisemaker::Surface->new(3, 2,
    [map { $_ / 23 } 0 .. 23]);
my $png = encode_png($img);
is(substr($png, 1, 3), 'PNG', 'encode produces PNG signature');
my $back = decode_png($png);
is($back->width, 3, 'decode width');
is($back->height, 2, 'decode height');
is($back->to_rgba8, $img->to_rgba8, 'PNG round trip rgba8-exact');

# error paths
eval { decode_png('not a png') };
like($@, qr/not a PNG/, 'decode rejects non-PNG');
my $corrupt = $png;
substr($corrupt, 20, 1) ^= "\x01";
eval { decode_png($corrupt) };
ok($@, 'decode rejects corrupt CRC');

# rgba8 quantize: NaN propagates (oracle semantics), clamp handles the rest
my $qn = Math::Fractal::Noisemaker::Surface->new(1, 1, [$nan, -0.5, 0.5, 2.0]);
quantize_texture($qn, 'rgba8unorm');
ok($qn->data->[0] != $qn->data->[0], 'rgba8 quantize keeps NaN');
is($qn->data->[1], 0.0, 'rgba8 quantize clamps negative to 0');
feq($qn->data->[2], 0.501960813999176, 'rgba8 quantize rounds 0.5 (f32 of 128/255)');
is($qn->data->[3], 1.0, 'rgba8 quantize clamps >1 to 1');

done_testing();
