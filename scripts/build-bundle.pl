#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Math::Fractal::Noisemaker::Transpiler::Build qw(run);
run(@ARGV);
