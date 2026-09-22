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

use constant MAX_SURFACE_PIXELS => 16_777_216;

sub _f32 { unpack('f', pack('f', $_[0])) }

sub _assert_dim {
    my ($value, $name) = @_;
    die "$name must be a positive integer within the safe integer range\n"
        unless defined $value && $value =~ /^\d+$/ && $value > 0
            && $value <= 9_007_199_254_740_991;
}

sub _surface_length {
    my ($width, $height) = @_;
    _assert_dim($width, 'width');
    _assert_dim($height, 'height');
    die "Surface exceeds the 16,777,216 pixel limit\n"
        if $height > int(MAX_SURFACE_PIXELS / $width);
    return $width * $height * 4;
}

sub new {
    my ($class, $width, $height, $data) = @_;
    my $length = _surface_length($width, $height);
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
    my $length = _surface_length($width, $height);
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

__END__

=head1 NAME

Math::Fractal::Noisemaker::Surface - top-down RGBA pixel storage

=head1 SYNOPSIS

    use Math::Fractal::Noisemaker::Surface;
    my $image = Math::Fractal::Noisemaker::Surface->new(32, 32);
    $image->clear([0.25, 0.5, 0.75, 1]);
    my $rgba = $image->to_rgba8;

=head1 METHODS

=head2 new($width, $height, $data)

Creates a surface. Dimensions must be positive integers, with at most
16,777,216 pixels. Omit C<$data> for a zero-filled image. Supplied data must be
an array reference with exactly C<width * height * 4> numeric components in
RGBA order, left to right, top to bottom. The array is borrowed, not copied
or rounded by this constructor. Call C<clone> for independent storage.

=head2 from_rgba8($width, $height, $bytes)

Class method accepting exactly four packed bytes per pixel. Divides components
by 255 and rounds to float32. There is no color-profile or gamma conversion.

=head2 width(), height(), data()

Return dimensions and the live mutable component array reference. Pixel
C<($x, $y)> begins at index C<4 * ($y * $image-E<gt>width + $x)>.

=head2 clear($rgba)

Fills the surface with four components rounded to float32; defaults to
transparent black. Returns the surface itself.

=head2 clone()

Returns an independent copy of the components and sampling filter.

=head2 filter(), filter($mode)

Gets or sets the sampling mode. Use C<nearest> (default) or C<linear>.

=head2 to_rgba8()

Returns packed, top-down RGBA bytes, with straight alpha and no gamma transform.
Finite components are clamped to 0..1 and rounded to the nearest byte;
non-finite components become zero. Does not modify the surface.

=head1 ERRORS

Invalid dimensions and buffer lengths throw exceptions. The pixel limit is
not a memory reservation: Perl arrays use far more memory than packed bytes.

=cut
