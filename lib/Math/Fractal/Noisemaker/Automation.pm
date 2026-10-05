package Math::Fractal::Noisemaker::Automation;

# CPU port of noisemaker-cpu src/runtime/automation.js — upstream oscillator
# parameter automation written as `osc(...)` in the Polymorphic DSL. Upstream
# resolves these per frame inside Pipeline.resolveUniformValue with a normalized
# 0..1 loop time; this port resolves them per render in Renderer::_run_state_once
# with the same `time` the canonical kernels receive as their `time` uniform.
#
# The upstream Midi/Audio automation nodes are not compiled by the DSL (value-position
# calls other than osc() are rejected at compile time), so only the Oscillator branch
# of upstream's evaluateAutomation is reachable here. The math below is a verbatim
# port of the upstream oscillator evaluation, including the noise2d two-stage
# periodic noise (speed applied once, after the first periodic wrap, matching the
# osc2d shader).
#
# Float fidelity: JS numbers are float64 and `%` follows the dividend's sign, so
# every JS remainder is POSIX::fmod and every Math.* call maps to its libc
# counterpart — except sin/cos, which are the bit-exact V8 fdlibm port in
# JsTrig (the platform libm diverges from V8 by 1 ulp on some arguments and
# the upstream oracle fixture pins those bits). Math.round is js_round:
# nearest integer with exact .5 ties toward +infinity, unlike floor(x + 0.5)
# for x = 0.49999999999999994.

use strict;
use warnings;
use Scalar::Util qw(looks_like_number);
use POSIX        ();
use Exporter 'import';

use Math::Fractal::Noisemaker::JsTrig qw(js_sin js_cos);

our @EXPORT_OK = qw(
    MAX_AUTOMATION_DEPTH
    evaluate_automation
    is_automation_value
    is_finite_number
    js_round
    resolve_automation_uniform
);

use constant TAU => 3.141592653589793 * 2;

use constant MAX_AUTOMATION_DEPTH => 8;

my $RANGES = {
    unit             => { min => 0, max => 1 },
    oscillatorSpeed  => { min => -20, max => 20 },
    oscillatorOffset => { min => -1, max => 1 },
    oscillatorSeed   => { min => 1, max => 9999 },
};

# 16-point Gauss-Legendre nodes and weights on [-1, 1]. Fixed quadrature keeps
# noise and deeply nested rate modulation deterministic and seekable.
my @INTEGRATION_NODES = (
    -0.9894009349916499, -0.9445750230732326, -0.8656312023878318, -0.755404408355003,
    -0.6178762444026438, -0.4580167776572274, -0.2816035507792589, -0.0950125098376374,
    0.0950125098376374,  0.2816035507792589,  0.4580167776572274,  0.6178762444026438,
    0.755404408355003,   0.8656312023878318,  0.9445750230732326,  0.9894009349916499,
);
my @INTEGRATION_WEIGHTS = (
    0.0271524594117541, 0.0622535239386479, 0.0951585116824928, 0.1246289712555339,
    0.1495959888165767, 0.1691565193950025, 0.1826034150449236, 0.1894506104550685,
    0.1894506104550685, 0.1826034150449236, 0.1691565193950025, 0.1495959888165767,
    0.1246289712555339, 0.0951585116824928, 0.0622535239386479, 0.0271524594117541,
);
my @INTEGRATION_RULES = (
    { nodes => \@INTEGRATION_NODES, weights => \@INTEGRATION_WEIGHTS },
    {
        nodes => [
            -0.9602898564975363, -0.7966664774136267, -0.525532409916329,
            -0.1834346424956498, 0.1834346424956498,  0.525532409916329,
            0.7966664774136267,  0.9602898564975363,
        ],
        weights => [
            0.1012285362903763, 0.2223810344533745, 0.3137066458778873,
            0.362683783378362,  0.362683783378362,  0.3137066458778873,
            0.2223810344533745, 0.1012285362903763,
        ],
    },
    {
        nodes   => [-0.8611363115940526, -0.3399810435848563, 0.3399810435848563, 0.8611363115940526],
        weights => [0.3478548451374538, 0.6521451548625461, 0.6521451548625461, 0.3478548451374538],
    },
    {
        nodes   => [-0.5773502691896257, 0.5773502691896257],
        weights => [1, 1],
    },
);

sub is_automation_value {
    my ($value) = @_;
    return 0 unless ref $value eq 'HASH';
    my $type = $value->{type};
    return 0 if ref $type;
    return defined $type && $type eq 'Oscillator' ? 1 : 0;
}

sub is_finite_number {
    # JS Number.isFinite: booleans and non-numbers are not finite numbers.
    my ($value) = @_;
    return 0 if !defined $value || ref $value;
    return 0 unless looks_like_number($value);
    return POSIX::isfinite(0 + $value) ? 1 : 0;
}

sub _scale {
    my ($value, $range) = @_;
    return $value
        if !ref $range
        || !is_finite_number($range->{min})
        || !is_finite_number($range->{max});
    return $range->{min} + $value * ($range->{max} - $range->{min});
}

sub _resolve_field {
    my ($value, $normalized_time, $range, $depth, $stack, $fallback) = @_;
    return evaluate_automation($value, $normalized_time, $range, $depth + 1, $stack)
        if is_automation_value($value);
    return is_finite_number($value) ? 0 + $value : $fallback;
}

sub _can_integrate_exactly {
    my ($config) = @_;
    my $osc_type = $config->{oscType};
    return 0 if !is_finite_number($osc_type) || $osc_type < 0 || $osc_type > 4;
    for my $field (qw(min max speed offset seed)) {
        return 0 unless is_finite_number($config->{$field});
    }
    return 1;
}

sub _osc_primitive {
    my ($osc_type, $x) = @_;
    my $whole    = POSIX::floor($x);
    my $fraction = $x - $whole;
    return $x * 0.5 - js_sin($x * TAU) / (2 * TAU) if $osc_type == 0;
    if ($osc_type == 1) {
        my $partial = $fraction < 0.5 ? $fraction * $fraction : 2 * $fraction - $fraction * $fraction - 0.5;
        return $whole * 0.5 + $partial;
    }
    return $whole * 0.5 + $fraction * $fraction * 0.5 if $osc_type == 2;
    return $x - ($whole * 0.5 + $fraction * $fraction * 0.5) if $osc_type == 3;
    return $whole * 0.5 + ($fraction - 0.5 > 0 ? $fraction - 0.5 : 0.0) if $osc_type == 4;
    return undef;
}

sub _integrate_simple {
    my ($config, $normalized_time) = @_;
    my $osc_type  = $config->{oscType};
    my $min_value = $config->{min};
    my $max_value = $config->{max};
    my $speed     = $config->{speed};
    my $offset    = $config->{offset};
    if ($speed == 0) {
        return _evaluate_oscillator($config, 0, 0, {}) * $normalized_time;
    }
    my $start       = _osc_primitive($osc_type, $offset);
    my $end         = _osc_primitive($osc_type, $offset + $speed * $normalized_time);
    my $raw_integral = ($end - $start) / $speed;
    return $min_value * $normalized_time + ($max_value - $min_value) * $raw_integral;
}

sub _integrate_automation {
    my ($config, $normalized_time, $range, $depth, $stack) = @_;
    my $integral;
    if (_can_integrate_exactly($config)) {
        $integral = _integrate_simple($config, $normalized_time);
    }
    else {
        # Decrease the quadrature order as rate modulators nest. This bounds an
        # eight-level graph to thousands, rather than millions, of evaluations
        # while retaining the highest precision at the user-visible output.
        my $rule      = $INTEGRATION_RULES[ $depth < $#INTEGRATION_RULES ? $depth : $#INTEGRATION_RULES ];
        my $midpoint  = $normalized_time * 0.5;
        my $half_width = $normalized_time * 0.5;
        my $total     = 0.0;
        for my $i (0 .. $#{ $rule->{nodes} }) {
            my $sample_time = $midpoint + $half_width * $rule->{nodes}[$i];
            $total += $rule->{weights}[$i] * evaluate_automation($config, $sample_time, undef, $depth + 1, $stack);
        }
        $integral = $half_width * $total;
    }
    return $integral
        if !ref $range
        || !is_finite_number($range->{min})
        || !is_finite_number($range->{max});
    return $range->{min} * $normalized_time + $integral * ($range->{max} - $range->{min});
}

sub _hash21 {
    my ($px, $py, $s) = @_;
    my $x = POSIX::fmod($px * 234.34 + $s, 1);
    my $y = POSIX::fmod($py * 435.345 + $s, 1);
    $x += 1 if $x < 0;
    $y += 1 if $y < 0;
    my $p = $x + $y + ($x + $y) * 34.23;
    return POSIX::fmod($x * $y * $p, 1);
}

sub _noise2d {
    my ($px, $py, $s) = @_;
    my $ix = POSIX::floor($px);
    my $iy = POSIX::floor($py);
    my $fx = $px - $ix;
    my $fy = $py - $iy;
    $fx = $fx * $fx * (3 - 2 * $fx);
    $fy = $fy * $fy * (3 - 2 * $fy);

    my $a = _hash21($ix,       $iy,       $s);
    my $b = _hash21($ix + 1,   $iy,       $s);
    my $c = _hash21($ix,       $iy + 1,   $s);
    my $d = _hash21($ix + 1,   $iy + 1,   $s);

    return $a * (1 - $fx) * (1 - $fy) + $b * $fx * (1 - $fy) + $c * (1 - $fx) * $fy + $d * $fx * $fy;
}

sub _osc_noise {
    # Looping noise - samples on a circle for seamless temporal loops
    my ($t, $seed) = @_;
    my $temporal = POSIX::fmod($t, 1);
    my $angle    = $temporal * TAU;
    my $radius   = 2;
    my $loop_x   = js_cos($angle) * $radius;
    my $loop_y   = js_sin($angle) * $radius;
    my $n1 = _noise2d($loop_x + $seed,       $loop_y + $seed,       $seed);
    my $n2 = _noise2d($loop_x + $seed * 2,   $loop_y + $seed * 2,   $seed);
    return ($n1 + $n2) / 2;
}

sub _osc_noise2d {
    # Two-stage periodic noise (noise2d, kind 6) - mirrors the osc2d effect:
    #   scaledTime = periodicValue(time, timeNoise) * speed
    #   value      = periodicValue(scaledTime, valueNoise)
    # `time` is the normalized loop time plus the phase offset; speed is applied
    # once, after the first periodic wrap, exactly as in the osc2d shader.
    # osc() has no spatial position, so both noise stages are sampled at a fixed
    # position derived from the seed (the osc2d shader salts the second stage with
    # +12345). periodicValue() has period 1 in time, so whole-number speeds loop
    # seamlessly.
    my ($time, $speed, $seed) = @_;
    my $periodic_value = sub { my ($x, $v) = @_; return (js_sin(($x - $v) * TAU) + 1) * 0.5 };

    my $px = (abs(POSIX::fmod($seed, 16)) + 0.5) / 16;
    my $py = (abs(POSIX::fmod(POSIX::floor($seed / 16), 16)) + 0.5) / 16;
    my $time_noise  = _noise2d($px, $py, $seed + 12345);
    my $value_noise = _noise2d($px, $py, $seed);
    my $scaled_time = $periodic_value->($time, $time_noise) * $speed;
    return $periodic_value->($scaled_time, $value_noise);
}

sub _evaluate_oscillator {
    my ($osc, $normalized_time, $depth, $stack) = @_;
    my $osc_type = $osc->{oscType};
    my $min_value = _resolve_field($osc->{min},    $normalized_time, $RANGES->{unit},             $depth, $stack, 0);
    my $max_value = _resolve_field($osc->{max},    $normalized_time, $RANGES->{unit},             $depth, $stack, 1);
    my $offset    = _resolve_field($osc->{offset}, $normalized_time, $RANGES->{oscillatorOffset}, $depth, $stack, 0);
    my $seed      = _resolve_field($osc->{seed},   $normalized_time, $RANGES->{oscillatorSeed},   $depth, $stack, 1);

    # A modulated rate is frequency modulation, so phase is the integral of
    # rate. Literal rates keep the existing closed form exactly.
    my $phase;
    if (is_automation_value($osc->{speed})) {
        $phase = _integrate_automation($osc->{speed}, $normalized_time, $RANGES->{oscillatorSpeed}, $depth, $stack);
    }
    else {
        my $speed = $osc->{speed};
        $phase = $normalized_time * (is_finite_number($speed) ? 0 + $speed : 1);
    }
    my $t = $phase + $offset;

    # Get raw oscillator value (0..1)
    my $value;
    if    ($osc_type == 0) { $value = (1.0 - js_cos($t * TAU)) * 0.5 }
    elsif ($osc_type == 1) {
        my $tf = $t - POSIX::floor($t);
        $value = 1.0 - abs($tf * 2.0 - 1.0);
    }
    elsif ($osc_type == 2) { $value = $t - POSIX::floor($t) }
    elsif ($osc_type == 3) { $value = 1.0 - ($t - POSIX::floor($t)) }
    elsif ($osc_type == 4) { $value = ($t - POSIX::floor($t)) >= 0.5 ? 1.0 : 0.0 }
    elsif ($osc_type == 5) { $value = _osc_noise($t, $seed) }
    elsif ($osc_type == 6) {
        my $speed = _resolve_field(
            $osc->{speed}, $normalized_time, $RANGES->{oscillatorSpeed}, $depth, $stack, 1);
        $value = _osc_noise2d($normalized_time + $offset, is_finite_number($speed) ? 0 + $speed : 1, $seed);
    }
    else { $value = 0 }

    # Map to min..max range
    return $min_value + $value * ($max_value - $min_value);
}

sub evaluate_automation {
    my ($config, $normalized_time, $range, $depth, $stack) = @_;
    $depth = 0 unless defined $depth;
    $stack = {} unless defined $stack;
    if (!is_automation_value($config) || $depth > MAX_AUTOMATION_DEPTH || $stack->{ $config + 0 }) {
        return _scale(0, $range);
    }
    $stack->{ $config + 0 } = 1;
    my $value = eval { _evaluate_oscillator($config, $normalized_time, $depth, $stack) };
    my $error = $@;
    delete $stack->{ $config + 0 };
    die $error if $error;
    return _scale($value, $range);
}

sub resolve_automation_uniform {
    # Port of upstream Pipeline.resolveUniformValue: resolve an automation value
    # for the current frame, scaled into the consumer parameter's declared range,
    # with the upstream integer rounding for `type: 'int'` consumers. Non-automation
    # values pass through unchanged.
    my ($value, $normalized_time, $spec) = @_;
    return $value unless is_automation_value($value);
    my $resolved = evaluate_automation($value, $normalized_time, $spec);
    return js_round($resolved) if ref $spec eq 'HASH' && ($spec->{type} || '') eq 'int';
    return $resolved;
}

sub js_round {
    # JS Math.round: nearest integer, exact .5 ties toward +infinity. Unlike
    # floor(x + 0.5), this is exact for x = 0.49999999999999994, where the
    # addition rounds up to 1.0 but Math.round returns 0 (the fixture pins
    # that case).
    my ($x) = @_;
    my $floor = POSIX::floor($x);
    my $diff  = $x - $floor;
    return $floor + 1 if $diff > 0.5 || $diff == 0.5;
    return $floor;
}

1;

__END__

=head1 NAME

Math::Fractal::Noisemaker::Automation - the DSL C<osc()> oscillator-automation evaluator

=head1 SYNOPSIS

    use Math::Fractal::Noisemaker::Automation
        qw(resolve_automation_uniform is_automation_value);
    my $number = resolve_automation_uniform(
        { type => 'Oscillator', oscType => 0, min => 0, max => 1, speed => 1, offset => 0, seed => 1 },
        0.25,
        { min => 0, max => 1 },
    );

=head1 DESCRIPTION

Port of noisemaker-cpu C<src/runtime/automation.js>: the upstream oscillator
evaluator (Pipeline.resolveUniformValue) that resolves C<osc(...)> parameter
automation values against a normalized 0..1 loop time. Kinds 0-4 are the
periodic primitives with their exact-integration closed forms, kind 5 is the
looping value noise, and kind 6 is the two-stage periodic noise2d (speed
applied once, after the first periodic wrap). Nested C<osc()> fields resolve
recursively with 16/8/4/2-point Gauss-Legendre quadrature for modulated
rates; the result scales into the consumer parameter's declared range
(C<spec>), with integer selectors rounded the way JS C<Math.round> rounds.

C<evaluate_automation($config, $time, $range, $depth, $stack)> evaluates an
Oscillator value; C<resolve_automation_uniform($value, $time, $spec)> is the
per-uniform entry point; C<is_automation_value> and C<is_finite_number> are
shared predicates; C<js_round> is JS C<Math.round>. Non-automation values
pass through C<resolve_automation_uniform> unchanged. Sin/cos come from
L<Math::Fractal::Noisemaker::JsTrig> to stay bit-identical with the JS
oracle.

=cut
