package Math::Fractal::Noisemaker::MetalDivision;

use strict;
use warnings;
use POSIX ();
use MIME::Base64 qw(decode_base64);
use Math::Fractal::Noisemaker::MetalReciprocalData ();
use Math::Fractal::Noisemaker::UintMath ();

use constant MIN_NORMAL => 1.1754943508222875e-38;
my $DEVIATIONS;

sub _f32 { unpack('f<', pack('f<', $_[0])) }
sub _bits { unpack('V', pack('f<', $_[0])) }
sub _float { unpack('f<', pack('V', $_[0])) }

sub _deviations {
    return $DEVIATIONS if defined $DEVIATIONS;
    my $data = $Math::Fractal::Noisemaker::MetalReciprocalData::DATA;
    my $stream = decode_base64($data->{bits});
    my $set = "\0" x (1 << 20);
    my ($bit, $count) = (0, 0);
    for my $mantissa (1 .. (1 << 23) - 1) {
        my $scaled = 140737488355328.0 / (8388608 + $mantissa);
        my $position = $scaled - POSIX::floor($scaled);
        next unless $position >= $data->{bandLow} && $position <= $data->{bandHigh};
        if (vec($stream, $bit, 1)) {
            vec($set, $mantissa, 1) = 1;
            $count++;
        }
        $bit++;
    }
    die "Metal reciprocal data is corrupt: $bit band bits and $count deviations\n"
        unless $bit == $data->{bandBits}
            && $count == $data->{positiveDeviations} + $data->{negativeDeviations};
    $DEVIATIONS = $set;
    return $DEVIATIONS;
}

sub reciprocal {
    my ($value) = @_;
    my $word = _bits($value);
    my $exponent = ($word >> 23) & 0xff;
    return _float(($word & 0x80000000) | 0x7f800000) if $exponent == 0;
    return _f32(Math::Fractal::Noisemaker::UintMath::fdiv(1, $value)) if $exponent == 0xff;
    my $exact = 1.0 / abs(_float($word));
    my $result = _f32($exact);
    my $mantissa = $word & 0x7fffff;
    if ($mantissa && vec(_deviations(), $mantissa, 1)) {
        my $rounded = _bits($result);
        $result = _float($rounded + ($result < $exact ? 1 : -1));
    }
    $result = 0.0 if $result < MIN_NORMAL;
    return ($word & 0x80000000) ? -$result : $result;
}

sub divide {
    my ($dividend, $divisor) = @_;
    my $rounded = _f32($dividend);
    $rounded = _float(_bits($rounded) & 0x80000000)
        if $rounded != 0 && abs($rounded) < MIN_NORMAL;
    my $reciprocal = reciprocal($divisor);
    my $product = $rounded * $reciprocal;
    return _float((_bits($rounded) ^ _bits($reciprocal)) & 0x80000000)
        if $product == 0;
    return _float(_bits($product) & 0x80000000)
        if $product != 0 && abs($product) < MIN_NORMAL;
    return $product;
}

1;
