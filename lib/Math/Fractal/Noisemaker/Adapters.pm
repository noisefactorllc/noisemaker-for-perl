package Math::Fractal::Noisemaker::Adapters;

# Per-effect CPU adapter registry. An adapter wraps or replaces a transpiled
# kernel (or installs stdlib_override entries on the runtime) for effects
# whose reference implementation is native CPU code rather than pure GLSL —
# crt's range-reduced sine, snow's TV static, the cosine-palette sampler.
# Registered lazily as each is ported; get_adapter returns undef when the
# effect has no adapter (the common case).

use strict;
use warnings;

my %ADAPTERS;    # "effect_id:program" -> sub { my ($rt, $compiled) = @_; returns kernel coderef }

sub register {
    my ($effect_id, $program, $adapter) = @_;
    $ADAPTERS{"$effect_id:$program"} = $adapter;
}

sub get_adapter {
    my ($effect_id, $program) = @_;
    return $ADAPTERS{"$effect_id:$program"};
}

1;
