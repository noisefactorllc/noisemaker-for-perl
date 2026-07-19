package Math::Fractal::Noisemaker::Transpiler::SharedEnums;

# Shared enum registries referenced by type:"member" params via enum:"<name>".
#
# The per-effect CDN bundle carries only the enum NAME for a shared member
# enum (e.g. filter/palette's `index` is enum:"palette"); the name->index
# choices are resolved from a shared registry at the reference engine's build
# time and are not served per effect. We vendor the stable mapping here so
# Build can inline `choices` and the renderer can resolve a non-zero member
# default (e.g. "palette.brushedMetal" -> 7).

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(%SHARED_ENUMS);

# The 56 palettes backing the cosine-palette adapter, in paletteData order.
my %PALETTE = (
    none => 0, seventiesShirt => 1, fiveG => 2, afterimage => 3, barstow => 4,
    bloob => 5, blueSkies => 6, brushedMetal => 7, burningSky => 8,
    california => 9, columbia => 10, cottonCandy => 11, darkSatin => 12,
    dealerHat => 13, dreamy => 14, eventHorizon => 15, ghostly => 16,
    grayscale => 17, hazySunset => 18, heatmap => 19, hypercolor => 20,
    jester => 21, justBlue => 22, justCyan => 23, justGreen => 24,
    justPurple => 25, justRed => 26, justYellow => 27, mars => 28,
    modesto => 29, moss => 30, neptune => 31, netOfGems => 32, organic => 33,
    papaya => 34, radioactive => 35, royal => 36, santaCruz => 37,
    sherbet => 38, sherbetDouble => 39, silvermane => 40, skykissed => 41,
    solaris => 42, spooky => 43, springtime => 44, sproingtime => 45,
    sulphur => 46, summoning => 47, superhero => 48, toxic => 49,
    tropicalia => 50, tungsten => 51, vaporwave => 52, vibrant => 53,
    vintage => 54, vintagePhoto => 55,
);

our %SHARED_ENUMS = (palette => \%PALETTE);

1;
