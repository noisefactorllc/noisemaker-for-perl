package Math::Fractal::Noisemaker::OverlayGen;

# Procedural overlayTex generator for the worm-overlay effects
# (fibers/scratches/strayHair). Ported when the parity grind reaches them.

use strict;
use warnings;

my %OVERLAY_EFFECTS;    # effect_id -> 1

sub is_overlay_effect { $OVERLAY_EFFECTS{ $_[0] } ? 1 : 0 }

sub register_overlay_effect { $OVERLAY_EFFECTS{ $_[0] } = 1 }

sub render_worm_overlay {
    my ($effect_id) = @_;
    die "overlay generator for $effect_id not yet ported\n";
}

1;
