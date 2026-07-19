package Math::Fractal::Noisemaker::Surface;

# Surface — an RGBA float32 pixel buffer, top-down row order.
#
# Faithful port of noisemaker-cpu src/runtime/surface.js (via the Python
# port's surface.py). Storage is a flat arrayref of width*height*4 numbers
# holding float32-representable values. Conversion to/from 8-bit RGBA is a
# naive /255 linear scale (no sRGB curve). to_rgba8 clamps to [0,1], maps
# non-finite values to zero, and rounds with floor(x*255 + 0.5) to match JS
# Math.round (ties toward +inf).

use strict;
use warnings;

sub _f32 { unpack('f', pack('f', $_[0])) }

sub _assert_dim {
    my ($value, $name) = @_;
    die "$name must be a positive integer\n"
        unless defined $value && $value =~ /^\d+$/ && $value > 0;
}

sub new {
    my ($class, $width, $height, $data) = @_;
    _assert_dim($width, 'width');
    _assert_dim($height, 'height');
    my $length = $width * $height * 4;
    if (defined $data) {
        die "data must be an array of length $length\n"
            unless ref $data eq 'ARRAY' && @$data == $length;
    }
    else {
        $data = [(0.0) x $length];
    }
    return bless {
        width  => $width,
        height => $height,
        data   => $data,
        # "nearest" (canonical internal default) or "linear" (external images).
        filter => 'nearest',
    }, $class;
}

sub width  { $_[0]{width} }
sub height { $_[0]{height} }
sub data   { $_[0]{data} }
sub filter { @_ > 1 ? ($_[0]{filter} = $_[1]) : $_[0]{filter} }

sub from_rgba8 {
    my ($class, $width, $height, $bytes) = @_;
    _assert_dim($width, 'width');
    _assert_dim($height, 'height');
    my $length = $width * $height * 4;
    my @b = unpack('C*', $bytes);
    die "bytes must have length $length\n" unless @b == $length;
    # Match JS: data[i] = fround(bytes[i] * (1/255)) — float64 product, then f32.
    my @data = map { _f32($_ * (1.0 / 255.0)) } @b;
    return $class->new($width, $height, \@data);
}

sub clone {
    my ($self) = @_;
    my $s = (ref $self)->new($self->{width}, $self->{height}, [@{ $self->{data} }]);
    $s->{filter} = $self->{filter};
    return $s;
}

sub clear {
    my ($self, $color) = @_;
    $color = [0.0, 0.0, 0.0, 0.0] unless defined $color;
    die "color must contain four components\n" unless @$color == 4;
    my $d = $self->{data};
    my @rgba = map { _f32($_) } @$color;
    for (my $i = 0; $i < @$d; $i += 4) {
        @{$d}[$i .. $i + 3] = @rgba;
    }
    return $self;
}

sub to_rgba8 {
    my ($self) = @_;
    my @out;
    for my $v (@{ $self->{data} }) {
        my $x = ($v == $v && $v != 9**9**9 && $v != -(9**9**9)) ? $v : 0.0;
        $x = 0.0 if $x < 0.0;
        $x = 1.0 if $x > 1.0;
        push @out, int($x * 255.0 + 0.5);
    }
    return pack('C*', @out);
}

1;
