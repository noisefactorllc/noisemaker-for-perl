package Math::Fractal::Noisemaker::DrawOps;

# CPU-only draw operations for drawMode passes (no GLSL kernel). The one in
# the eligible catalog is wormhole's point-scatter deposit.

use strict;
use warnings;

my %DRAW_OPS;    # "effect_id:program" -> sub { my ($src, $dest, $uniforms) = @_; }

sub register {
    my ($effect_id, $program, $op) = @_;
    $DRAW_OPS{"$effect_id:$program"} = $op;
}

sub get_draw_op {
    my ($effect_id, $program) = @_;
    return $DRAW_OPS{"$effect_id:$program"};
}

1;
