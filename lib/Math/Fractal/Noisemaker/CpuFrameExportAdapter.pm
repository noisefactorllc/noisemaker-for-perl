package Math::Fractal::Noisemaker::CpuFrameExportAdapter;

use strict;
use warnings;
use POSIX ();
use Scalar::Util qw(blessed looks_like_number);

use Math::Fractal::Noisemaker::Surface;

use constant MAX_SAFE_INTEGER => 9_007_199_254_740_991;
use constant MAX_SURFACE_PIXELS => 16_777_216;

sub new { bless {}, shift }

sub _validate_descriptor {
    my ($descriptor) = @_;
    die "Frame export descriptor must be a hash reference\n" unless ref $descriptor eq 'HASH';
    for my $name (qw(width height)) {
        my $value = $descriptor->{$name};
        die "Frame export $name must be a positive integer\n"
            unless defined $value
                && $value =~ /^\d+$/
                && $value > 0
                && $value <= MAX_SAFE_INTEGER;
    }
    die "CPU frame export format must be 'rgba8unorm'\n"
        unless defined $descriptor->{format} && $descriptor->{format} eq 'rgba8unorm';
    die "CPU frame export colorSpace must be 'srgb' or 'display-p3'\n"
        unless defined $descriptor->{colorSpace}
            && ($descriptor->{colorSpace} eq 'srgb' || $descriptor->{colorSpace} eq 'display-p3');
    die "CPU frame export alphaMode must be 'opaque', 'straight', or 'premultiplied'\n"
        unless defined $descriptor->{alphaMode}
            && $descriptor->{alphaMode} =~ /^(?:opaque|straight|premultiplied)$/;
    die "Frame export fps must be finite and positive\n"
        unless looks_like_number($descriptor->{fps})
            && POSIX::isfinite(0 + $descriptor->{fps})
            && $descriptor->{fps} > 0;
    die "Surface exceeds the 16,777,216 pixel limit\n"
        if $descriptor->{height} > int(MAX_SURFACE_PIXELS / $descriptor->{width});
    return $descriptor->{width} * $descriptor->{height} * 4;
}

sub create_slot {
    my ($self, $index, $descriptor) = @_;
    my $byte_length = _validate_descriptor($descriptor);
    my $data = "\0" x $byte_length;
    my $data_ref = \$data;
    my $frame = bless {
        width => $descriptor->{width},
        height => $descriptor->{height},
        row_stride => $descriptor->{width} * 4,
        data => $data_ref,
    }, 'Math::Fractal::Noisemaker::FrameExportFrame';
    return {
        index => $index,
        width => $descriptor->{width},
        height => $descriptor->{height},
        alpha_mode => $descriptor->{alphaMode},
        data => $data_ref,
        frame => $frame,
        ready => 0,
        destroyed => 0,
    };
}

sub _byte_from_float {
    my ($value) = @_;
    return 0 unless POSIX::isfinite($value) && $value > 0;
    return 255 if $value >= 1;
    return int($value * 255 + 0.5);
}

sub begin {
    my ($self, $slot, $surface, $timestamp) = @_;
    $self->_assert_usable($slot);
    die "CPU frame export slot is already pending\n" if $slot->{ready};
    die "CPU frame export requires a Surface frame\n"
        unless blessed($surface) && $surface->isa('Math::Fractal::Noisemaker::Surface');
    die "CPU frame export source extent " . $surface->width . 'x' . $surface->height
        . " does not match configured extent $slot->{width}x$slot->{height}\n"
        unless $surface->width == $slot->{width} && $surface->height == $slot->{height};

    my @bytes;
    my $source = $surface->data;
    for (my $index = 0; $index < @$source; $index += 4) {
        my $alpha = $source->[ $index + 3 ];
        my $color_scale = $slot->{alpha_mode} eq 'premultiplied' ? $alpha : 1;
        push @bytes,
            _byte_from_float($source->[$index] * $color_scale),
            _byte_from_float($source->[ $index + 1 ] * $color_scale),
            _byte_from_float($source->[ $index + 2 ] * $color_scale),
            _byte_from_float($slot->{alpha_mode} eq 'opaque' ? 1 : $alpha);
    }
    ${ $slot->{data} } = pack('C*', @bytes);
    $slot->{ready} = 1;
}

sub poll {
    my ($self, $slot) = @_;
    $self->_assert_usable($slot);
    return $slot->{ready};
}

sub read {
    my ($self, $slot) = @_;
    $self->_assert_usable($slot);
    die "CPU frame export slot is not ready\n" unless $slot->{ready};
    $slot->{ready} = 0;
    return $slot->{frame};
}

sub destroy_slot {
    my ($self, $slot) = @_;
    return unless $slot && !$slot->{destroyed};
    $slot->{destroyed} = 1;
    $slot->{ready} = 0;
}

sub _assert_usable {
    my ($self, $slot) = @_;
    die "CPU frame export slot is not usable\n" unless $slot && !$slot->{destroyed};
}

package Math::Fractal::Noisemaker::FrameExportFrame;

use strict;
use warnings;

sub width      { $_[0]{width} }
sub height     { $_[0]{height} }
sub row_stride { $_[0]{row_stride} }
sub data       { $_[0]{data} }

1;
