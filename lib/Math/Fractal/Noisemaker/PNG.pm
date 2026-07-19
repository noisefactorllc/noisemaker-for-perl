package Math::Fractal::Noisemaker::PNG;

# PNG codec — faithful port of noisemaker-cpu src/node/png.js (via the
# Python port's png.py). Core-module-only (Compress::Zlib / Compress::Raw::Zlib).
#
# Encodes Surface objects as 8-bit RGBA PNGs (color type 6, no interlace,
# filter type 0/None per scanline) and decodes arbitrary well-formed 8-bit
# non-interlaced PNGs (grayscale, RGB, palette, gray+alpha, RGBA; all five
# row filters) back into Surface objects. Mirrors png.js's structural
# validation (chunk ordering, CRC32 checks) and its decompression-bomb /
# pixel-count guards.

use strict;
use warnings;
use Compress::Zlib ();
use Compress::Raw::Zlib qw(Z_OK Z_STREAM_END Z_BUF_ERROR);
use Exporter 'import';

use Math::Fractal::Noisemaker::Surface;

our @EXPORT_OK = qw(encode_png decode_png);

my $SIGNATURE = pack('C*', 137, 80, 78, 71, 13, 10, 26, 10);
use constant MAX_PNG_PIXELS        => 16_777_216;
use constant MAX_PNG_ENCODED_BYTES => 256 * 1024 * 1024;
use constant MAX_PNG_DECODED_BYTES => 96 * 1024 * 1024;

my %COMPONENTS_BY_COLOR_TYPE = (0 => 1, 2 => 3, 3 => 1, 4 => 2, 6 => 4);

sub _chunk {
    my ($chunk_type, $data) = @_;
    $data = '' unless defined $data;
    my $body = $chunk_type . $data;
    my $crc  = Compress::Zlib::crc32($body) & 0xFFFFFFFF;
    return pack('N', length $data) . $body . pack('N', $crc);
}

# Encode a Surface (RGBA float32, top-down) as 8-bit RGBA PNG bytes.
sub encode_png {
    my ($surface) = @_;
    my ($width, $height) = ($surface->width, $surface->height);
    die "PNG exceeds the 16,777,216 pixel limit\n"
        if $height > int(MAX_PNG_PIXELS / $width);

    my $ihdr = pack('N N C C C C C', $width, $height, 8, 6, 0, 0, 0);

    my $rgba   = $surface->to_rgba8;
    my $stride = $width * 4;
    my $scanlines = '';
    for my $y (0 .. $height - 1) {
        $scanlines .= "\x00" . substr($rgba, $y * $stride, $stride);
    }

    my $idat = Compress::Zlib::compress($scanlines, 9);

    return $SIGNATURE
        . _chunk('IHDR', $ihdr)
        . _chunk('IDAT', $idat)
        . _chunk('IEND');
}

sub _paeth {
    my ($left, $up, $upper_left) = @_;
    my $estimate = $left + $up - $upper_left;
    my $ld = abs($estimate - $left);
    my $ud = abs($estimate - $up);
    my $uld = abs($estimate - $upper_left);
    return $left if $ld <= $ud && $ld <= $uld;
    return $up   if $ud <= $uld;
    return $upper_left;
}

# Match Node's Buffer#toString('ascii'): mask off the high bit of each byte.
sub _ascii {
    my ($data) = @_;
    return join '', map { chr($_ & 0x7F) } unpack('C*', $data);
}

# Inflate a zlib stream, dying if the output would exceed max_length.
# Mirrors Node's inflateSync(compressed, { maxOutputLength }).
sub _bounded_inflate {
    my ($compressed, $max_length) = @_;
    my ($inflater, $err) = Compress::Raw::Zlib::Inflate->new(LimitOutput => 1);
    die "zlib init failed: $err\n" unless $inflater;
    my $out   = '';
    my $input = $compressed;
    my $stalls = 0;
    while (1) {
        my $buf    = '';
        my $status = $inflater->inflate($input, $buf);
        $out .= $buf;
        die "decompressed data exceeds the expected length\n" if length($out) > $max_length;
        last if $status == Z_STREAM_END;
        if ($status == Z_BUF_ERROR || $status == Z_OK) {
            # LimitOutput: Z_BUF_ERROR means the output buffer was the limit;
            # continue. Guard against a stalled stream (no input, no output).
            if (!length $buf) {
                die "invalid or truncated zlib stream\n" if ++$stalls > 2;
            }
            else { $stalls = 0 }
            next if length($buf) || length($input);
            last;    # input consumed, nothing pending — truncated stream
        }
        die "invalid zlib stream (status $status)\n";
    }
    return $out;
}

sub _decode_scanlines {
    my ($compressed, $width, $height, $bpp) = @_;
    my $stride   = $width * $bpp;
    my $expected = ($stride + 1) * $height;
    die "PNG decoded scanlines exceed the 96 MiB limit\n" if $expected > MAX_PNG_DECODED_BYTES;
    my $filtered = eval { _bounded_inflate($compressed, $expected) };
    die "PNG decompressed data exceeds the expected scanline length or is invalid: $@" if $@;
    die "PNG scanline data has an invalid length\n" if length($filtered) != $expected;

    my @filt = unpack('C*', $filtered);
    my @decoded = (0) x ($stride * $height);
    for my $y (0 .. $height - 1) {
        my $source_row = $y * ($stride + 1);
        my $target_row = $y * $stride;
        my $filter = $filt[$source_row];
        die "Unsupported PNG row filter $filter\n" if $filter > 4;
        for my $x (0 .. $stride - 1) {
            my $raw  = $filt[$source_row + $x + 1];
            my $left = $x >= $bpp ? $decoded[$target_row + $x - $bpp] : 0;
            my $up   = $y > 0     ? $decoded[$target_row + $x - $stride] : 0;
            my $ul   = ($y > 0 && $x >= $bpp) ? $decoded[$target_row + $x - $stride - $bpp] : 0;
            my $predictor =
                  $filter == 0 ? 0
                : $filter == 1 ? $left
                : $filter == 2 ? $up
                : $filter == 3 ? (($left + $up) >> 1)
                :                _paeth($left, $up, $ul);
            $decoded[$target_row + $x] = ($raw + $predictor) & 0xFF;
        }
    }
    return \@decoded;
}

# Decode a non-interlaced, 8-bit PNG into a Surface (RGBA float32, top-down).
sub decode_png {
    my ($png) = @_;
    die "PNG exceeds the 256 MiB encoded input limit\n" if length($png) > MAX_PNG_ENCODED_BYTES;
    die "Input is not a PNG image\n"
        if length($png) < length($SIGNATURE)
        || substr($png, 0, length $SIGNATURE) ne $SIGNATURE;

    my $offset = length $SIGNATURE;
    my ($width, $height, $bit_depth, $color_type, $interlace) = (0, 0, 0, -1, 0);
    my ($palette, $transparency);
    my ($seen_header, $seen_palette, $seen_transparency) = (0, 0, 0);
    my ($seen_idat, $idat_closed, $seen_end) = (0, 0, 0);
    my @idat_chunks;

    while ($offset + 12 <= length $png) {
        my $length = unpack('N', substr($png, $offset, 4));
        my $end    = $offset + 12 + $length;
        die "PNG contains a truncated chunk\n" if $end > length $png;
        my $chunk_type = _ascii(substr($png, $offset + 4, 4));
        my $chunk_data = substr($png, $offset + 8, $length);
        my $expected_crc = unpack('N', substr($png, $offset + 8 + $length, 4));
        my $actual_crc = Compress::Zlib::crc32(substr($png, $offset + 4, 4 + $length)) & 0xFFFFFFFF;
        die "PNG CRC mismatch in $chunk_type\n" if $actual_crc != $expected_crc;

        if ($chunk_type eq 'IHDR') {
            die "PNG IHDR must appear exactly once and first\n"
                if $seen_header || $offset != length $SIGNATURE;
            die "PNG IHDR has an invalid length\n" if $length != 13;
            $seen_header = 1;
            ($width, $height) = unpack('N N', $chunk_data);
            die "PNG dimensions must be positive\n" if $width == 0 || $height == 0;
            die "PNG exceeds the 16,777,216 pixel limit\n"
                if $height > int(MAX_PNG_PIXELS / $width);
            ($bit_depth, $color_type) = unpack('C C', substr($chunk_data, 8, 2));
            my ($compression, $filter_method) = unpack('C C', substr($chunk_data, 10, 2));
            die "Unsupported PNG compression or filter method\n"
                if $compression != 0 || $filter_method != 0;
            $interlace = unpack('C', substr($chunk_data, 12, 1));
        }
        elsif ($chunk_type eq 'PLTE') {
            die "PNG PLTE must appear at most once before IDAT\n"
                if !$seen_header || $seen_palette || $seen_idat;
            $seen_palette = 1;
            $palette = $chunk_data;
        }
        elsif ($chunk_type eq 'tRNS') {
            die "PNG tRNS must appear at most once before IDAT\n"
                if !$seen_header || $seen_transparency || $seen_idat;
            $seen_transparency = 1;
            $transparency = $chunk_data;
        }
        elsif ($chunk_type eq 'IDAT') {
            die "PNG IDAT chunks must be consecutive and follow IHDR\n"
                if !$seen_header || $idat_closed;
            $seen_idat = 1;
            push @idat_chunks, $chunk_data;
        }
        elsif ($chunk_type eq 'IEND') {
            die "PNG IEND must be empty and follow IDAT\n" if !$seen_idat || $length != 0;
            $seen_end = 1;
            $offset = $end;
            last;
        }
        else {
            $idat_closed = 1 if $seen_idat;
            die "Unsupported critical PNG chunk $chunk_type\n"
                if substr($chunk_type, 0, 1) eq uc substr($chunk_type, 0, 1);
        }
        $offset = $end;
    }

    die "PNG is missing required IHDR, IDAT, or IEND chunks\n"
        unless $seen_header && $seen_idat && $seen_end;
    die "PNG contains trailing data after IEND\n" if $offset != length $png;
    die "Unsupported PNG bit depth $bit_depth; expected 8\n" if $bit_depth != 8;
    die "Interlaced PNG images are not supported\n" if $interlace != 0;

    my $components = $COMPONENTS_BY_COLOR_TYPE{$color_type}
        or die "Unsupported PNG color type $color_type\n";
    if ($color_type == 3) {
        die "Indexed PNG is missing a valid palette\n"
            if !defined $palette || !length $palette || length($palette) % 3 != 0;
    }
    if (defined $transparency) {
        die "Grayscale PNG tRNS must contain one 16-bit sample\n"
            if $color_type == 0 && length($transparency) != 2;
        die "True-color PNG tRNS must contain three 16-bit samples\n"
            if $color_type == 2 && length($transparency) != 6;
        die "Indexed PNG tRNS exceeds its palette length\n"
            if $color_type == 3 && length($transparency) > length($palette) / 3;
        die "PNG color type $color_type cannot contain tRNS\n"
            if $color_type == 4 || $color_type == 6;
    }

    my $transparent_gray  = ($color_type == 0 && defined $transparency) ? unpack('n', $transparency) : -1;
    my ($transparent_red, $transparent_green, $transparent_blue) = (-1, -1, -1);
    if ($color_type == 2 && defined $transparency) {
        ($transparent_red, $transparent_green, $transparent_blue) = unpack('n n n', $transparency);
    }

    my $decoded = _decode_scanlines(join('', @idat_chunks), $width, $height, $components);
    my @trns = defined $transparency ? unpack('C*', $transparency) : ();
    my @pal  = defined $palette      ? unpack('C*', $palette)      : ();
    my $rgba = "\x00" x ($width * $height * 4);
    my @out;
    for my $pixel (0 .. $width * $height - 1) {
        my $source = $pixel * $components;
        if ($color_type == 0) {
            my $value = $decoded->[$source];
            push @out, $value, $value, $value, ($value == $transparent_gray ? 0 : 255);
        }
        elsif ($color_type == 2) {
            my ($r, $g, $b) = @{$decoded}[$source .. $source + 2];
            my $a = ($r == $transparent_red && $g == $transparent_green && $b == $transparent_blue) ? 0 : 255;
            push @out, $r, $g, $b, $a;
        }
        elsif ($color_type == 3) {
            my $index = $decoded->[$source];
            die "PNG palette index $index is out of range\n" if $index * 3 + 2 >= @pal;
            my $a = (defined $transparency && $index < @trns) ? $trns[$index] : 255;
            push @out, @pal[$index * 3 .. $index * 3 + 2], $a;
        }
        elsif ($color_type == 4) {
            my $value = $decoded->[$source];
            push @out, $value, $value, $value, $decoded->[$source + 1];
        }
        else {
            push @out, @{$decoded}[$source .. $source + 3];
        }
    }
    return Math::Fractal::Noisemaker::Surface->from_rgba8($width, $height, pack('C*', @out));
}

1;
