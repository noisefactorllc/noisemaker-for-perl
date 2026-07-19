package Math::Fractal::Noisemaker::PassRunner;

# Per-pixel pass runner — turns a compiled kernel into filled Surface data.
#
# Faithful port of noisemaker-cpu src/runtime/pass-runner.js. GLSL uses a
# BOTTOM-LEFT origin with pixel centers at (x+0.5, y+0.5); surface storage is
# top-down. So for top-down row y we feed the kernel fy = height-y-0.5
# (bottom-left) and uv = fragCoord / resolution. The kernel writes 4 floats
# into $out; we store them into the top-down row.

use strict;
use warnings;
use Exporter 'import';

use Math::Fractal::Noisemaker::Surface;
use Math::Fractal::Noisemaker::Runtime;

our @EXPORT_OK = qw(run_pass run_pass_deriv);

sub _f32 { unpack('f', pack('f', $_[0])) }

package Math::Fractal::Noisemaker::Ctx;

# Per-render context handed to each kernel invocation. rt/uniforms/textures/
# resolution/time/seed are set once per pass; frag_coord/uv per pixel.

sub new {
    my ($class, %args) = @_;
    my $self = bless {
        rt         => $args{rt},
        uniforms   => defined $args{uniforms} ? $args{uniforms} : {},
        textures   => defined $args{textures} ? $args{textures} : {},
        resolution => $args{resolution},
        time       => Math::Fractal::Noisemaker::PassRunner::_f32(defined $args{time} ? $args{time} : 0.0),
        seed       => defined $args{seed} ? $args{seed} : 1,
        blank      => $args{blank},    # 1x1 blank surface for unbound samplers
        frag_coord => undef,
        uv         => undef,
    }, $class;
    return $self;
}

sub rt         { $_[0]{rt} }
sub uniforms   { $_[0]{uniforms} }
sub textures   { $_[0]{textures} }
sub resolution { $_[0]{resolution} }
sub time       { $_[0]{time} }
sub seed       { $_[0]{seed} }
sub frag_coord { $_[0]{frag_coord} }
sub uv         { $_[0]{uv} }

# Sampler lookup with the WebGL unbound-sampler default: a missing binding
# reads as a 1x1 black surface (the Python port's _DefaultTex).
sub texture_binding {
    my ($self, $name) = @_;
    my $t = $self->{textures}{$name};
    return defined $t ? $t : $self->{blank};
}

package Math::Fractal::Noisemaker::PassRunner;

sub run_pass {
    my ($kernel, $ctx, $width, $height) = @_;
    my $surf = Math::Fractal::Noisemaker::Surface->new($width, $height);
    my $data = $surf->data;
    my $out  = [0.0, 0.0, 0.0, 0.0];
    my $fw   = 0.0 + $width;
    my $fh   = 0.0 + $height;
    $ctx->{resolution} = [$fw, $fh] unless defined $ctx->{resolution};
    for my $y (0 .. $height - 1) {
        my $fy   = $height - $y - 0.5;
        my $base = $y * $width * 4;
        for my $x (0 .. $width - 1) {
            my $fx = $x + 0.5;
            $ctx->{frag_coord} = [$fx, $fy, 0.0, 1.0];
            $ctx->{uv}         = [_f32($fx / $fw), _f32($fy / $fh)];
            $kernel->($ctx, $out);
            my $i = $base + $x * 4;
            @{$data}[$i .. $i + 3] = @$out;
        }
    }
    return $surf;
}

# Pass runner for kernels using dFdx/dFdy/fwidth. Mirrors the reference
# engine's wrapDerivatives: derivatives are computed in bottom-left pixel
# space over 2x2 quads. Each quad's 4 corners are probed in 'record' mode
# (arguments captured, no edge clamping — probes may fall outside the image
# like the GPU); each real pixel then replays with FINE derivatives selected
# by its parity.
sub run_pass_deriv {
    my ($kernel, $ctx, $width, $height) = @_;
    my $surf = Math::Fractal::Noisemaker::Surface->new($width, $height);
    my $data = $surf->data;
    my $rt   = $ctx->{rt};
    my $fw   = 0.0 + $width;
    my $fh   = 0.0 + $height;
    $ctx->{resolution} = [$fw, $fh] unless defined $ctx->{resolution};

    my $set_frag = sub {
        my ($fx, $fy) = @_;
        $ctx->{frag_coord} = [$fx, $fy, 0.0, 1.0];
        $ctx->{uv}         = [_f32($fx / $fw), _f32($fy / $fh)];
    };
    my $probe = sub {
        my ($fx, $fy) = @_;
        $set_frag->($fx, $fy);
        $rt->deriv_reset('record');
        $kernel->($ctx, [0.0, 0.0, 0.0, 0.0]);
        return $rt->deriv_log;
    };

    my (%lane_cache, %diff_cache);
    for my $y (0 .. $height - 1) {
        my $fy = $height - $y - 0.5;
        for my $x (0 .. $width - 1) {
            my $fx      = $x + 0.5;
            my $pixel_x = $x;
            my $pixel_y = $height - 1 - $y;    # bottom-left pixel row
            my ($quad_x, $quad_y) = ($pixel_x >> 1, $pixel_y >> 1);
            my $qkey  = "$quad_x,$quad_y";
            my $lanes = $lane_cache{$qkey};
            if (!$lanes) {
                my ($x0, $y0) = ($quad_x * 2 + 0.5, $quad_y * 2 + 0.5);
                $lanes = [
                    $probe->($x0,     $y0),
                    $probe->($x0 + 1, $y0),
                    $probe->($x0,     $y0 + 1),
                    $probe->($x0 + 1, $y0 + 1),
                ];
                $lane_cache{$qkey} = $lanes;
            }
            my ($xp, $yp) = ($pixel_x & 1, $pixel_y & 1);
            my $dkey  = "$qkey,$xp,$yp";
            my $diffs = $diff_cache{$dkey};
            if (!$diffs) {
                $diffs = $rt->deriv_fine($lanes, $xp, $yp);
                $diff_cache{$dkey} = $diffs;
            }
            $set_frag->($fx, $fy);
            $rt->deriv_reset('replay', $diffs);
            my $out = [0.0, 0.0, 0.0, 0.0];
            $kernel->($ctx, $out);
            my $i = ($y * $width + $x) * 4;
            @{$data}[$i .. $i + 3] = @$out;
        }
    }
    $rt->deriv_reset(undef);
    return $surf;
}

1;
