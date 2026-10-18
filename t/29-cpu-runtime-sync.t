use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP qw(decode_json);
use Digest::SHA qw(sha256_hex);
use POSIX ();
use Math::Fractal::Noisemaker::MetalDivision ();
use Math::Fractal::Noisemaker::MetalReciprocalData ();
use Math::Fractal::Noisemaker::Runtime;
use Math::Fractal::Noisemaker::Surface;

sub fixture {
    open my $fh, '<:raw', "$FindBin::Bin/data/cpu-sync/$_[0].json" or die $!;
    local $/;
    return decode_json(scalar <$fh>);
}
sub from_bits { unpack('f<', pack('V', $_[0])) }
sub bits { unpack('V', pack('f<', $_[0])) }
my $rt = Math::Fractal::Noisemaker::Runtime->new;
my $nearest = fixture('nearest-texel-m4');
my %surfaces;
for my $case (@{ $nearest->{boundaries} }) {
    my ($w, $u, $x) = @$case;
    $surfaces{$w} ||= Math::Fractal::Noisemaker::Surface->new($w, 1,
        [map { ($_, 0, 0, 1) } 0 .. $w - 1]);
    is($rt->texture($surfaces{$w}, [from_bits($u), 0])->[0], $x,
        "GPU nearest width=$w u=$u");
}
my $surface = Math::Fractal::Noisemaker::Surface->new(41, 3,
    [map { my $row = $_; map { ($_, 2 - $row, 0, 1) } 0 .. 40 } 0 .. 2]);
for my $case (@{ $nearest->{special41x3} }) {
    my ($u, $v, $x, $y) = @$case;
    my $got = $rt->texture($surface, [from_bits($u), from_bits($v)]);
    is_deeply([@$got[0, 1]], [$x, $y], "GPU nearest specials u=$u v=$v");
}
ok($rt->can('metal_divide'), 'runtime exposes measured division');
if ($rt->can('metal_divide')) {
    my $division = fixture('metal-division-m4');
    for my $case (@{ $division->{runtime} }, @{ $division->{special} }) {
        my ($a, $b, $expected) = @$case;
        my $got = bits($rt->metal_divide(from_bits($a), from_bits($b)));
        if (($expected & 0x7fffffff) > 0x7f800000) {
            ok(($got & 0x7fffffff) > 0x7f800000, "division $a/$b is NaN");
        } else {
            is($got, $expected, "division $a/$b");
        }
    }
    is_deeply($rt->metal_divide([41, 82], 41),
        [map { $rt->metal_divide($_, 41) } 41, 82], 'scalar divisor broadcasts');
    is_deeply($rt->metal_divide([41, 82], [41, 23]),
        [$rt->metal_divide(41, 41), $rt->metal_divide(82, 23)], 'vector divisor broadcasts');
    my $raw = $rt->metal_divide(1.3, 41);
    isnt($raw, unpack('f<', pack('f<', $raw)), 'division keeps raw product for following fused add');
}
for my $case (
    [0x80000000, 0x3f800000, 0x80000000],
    [0x00000000, 0xbf800000, 0x80000000],
    [0x80000000, 0xbf800000, 0x00000000],
    [0x3f800000, 0xff800000, 0x80000000],
    [0x80000001, 0x3f800000, 0x80000000],
    [0x80000000, 0x7f7fffff, 0x80000000],
) {
    my ($a, $b, $expected) = @$case;
    is(bits($rt->metal_divide(from_bits($a), from_bits($b))), $expected,
        "division preserves zero sign $a/$b");
}
my $deviations = Math::Fractal::Noisemaker::MetalDivision::_deviations();
my $table = "\0" x (1 << 21);
my ($positive, $negative) = (0, 0);
for my $mantissa (1 .. (1 << 23) - 1) {
    next unless vec($deviations, $mantissa, 1);
    my $scaled = 140737488355328.0 / (8388608 + $mantissa);
    my $up = $scaled - POSIX::floor($scaled) < 0.5;
    vec($table, $mantissa, 2) = $up ? 1 : 2;
    $up ? $positive++ : $negative++;
}
is_deeply([$positive, $negative], [859417, 8757], 'all measured reciprocal deviation counts');
is(sha256_hex($table), '9e62e57b1413fcfbcf95d9809e463498a30a917fc6c8b351015bffd3e6855a79',
    'all 8388608 mantissas reconstruct the captured table');
done_testing();
