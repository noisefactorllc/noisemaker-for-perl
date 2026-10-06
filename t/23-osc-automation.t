use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use POSIX qw(strtod);
use JSON::PP qw(decode_json);

use Math::Fractal::Noisemaker::Automation qw(
    evaluate_automation
    is_automation_value
    js_round
    resolve_automation_uniform
);
use Math::Fractal::Noisemaker::DSL   ();
use Math::Fractal::Noisemaker::Renderer qw(render_dsl);

# osc() parameter automation: evaluator parity against the pinned upstream
# oracle plus DSL-level render/error contracts — port of noisemaker-cpu
# test/dsl-osc-automation.test.js against the real catalog bundle.
#
# The fixture's expected values were captured from the pinned upstream tree's
# own automation evaluator (Pipeline.prototype.resolveUniformValue) at the
# recorded sourceRevision. The JS port additionally re-proves the fixture live
# against NM_REFERENCE_ROOT with the upstream JavaScript evaluator; that leg
# needs a JS runtime and stays in noisemaker-for-cpu's own suite.
#
# JS number semantics come from correctly-rounded strtod. Perl's string-to-NV
# conversion (what JSON::PP numification uses) is not correctly rounded on all
# supported perl versions — 17-digit literals can land 1 ulp off, which would
# flip bit-exact comparisons per perl build. So the fixture's numbers are
# re-read through libc strtod: each unquoted numeric literal is wrapped in a
# sentinel string before decoding, then converted with strtod (the fixture is
# machine-generated with one `"key": value` per line, so only genuine numbers
# match).

sub _strtod_number {
    my ($value) = @_;
    return $value unless defined $value && !ref $value && $value =~ /\A__N__(.+)\z/s;
    my $literal = $1;
    return int(strtod($literal)) if $literal =~ /\A-?\d+\z/;
    return strtod($literal);
}

sub _hydrate_numbers {
    my ($node) = @_;
    if (ref $node eq 'HASH') {
        $_ = _hydrate_numbers($_) for values %$node;
    }
    elsif (ref $node eq 'ARRAY') {
        $_ = _hydrate_numbers($_) for @$node;
    }
    else {
        return _strtod_number($node);
    }
    return $node;
}

my $FIXTURE = do {
    open my $fh, '<:raw', "$FindBin::Bin/data/osc-automation-golden.json"
        or die "cannot read osc-automation-golden.json: $!";
    local $/;
    my $text = <$fh>;
    $text =~ s/("[A-Za-z0-9_]+"[ \t]*:[ \t]*)((?:-?)(?:\d+)(?:\.\d+)?(?:[eE][+-]?\d+)?)[ \t]*(?=\n|$)/$1"__N__$2"/g;
    _hydrate_numbers(decode_json($text));
};
my @SPECS = (
    undef,
    { min => 0, max => 1 },
    { min => -2, max => 3 },
    { type => 'int' },
    { type => 'int', min => 1, max => 5 },
);

sub dsl_error {
    my ($source, %opt) = @_;
    my $ok = eval { render_dsl($source, %opt); 1 };
    return undef if $ok;
    return $@;
}

# --- evaluator parity against the captured upstream oracle --------------------

{
    my $cases = $FIXTURE->{cases};
    ok(@$cases > 0, 'osc automation fixture has cases');
    my $failures = 0;
    for my $case (@$cases) {
        my $spec = $SPECS[ $case->{specIndex} ];
        my $resolved = resolve_automation_uniform($case->{config}, $case->{time}, $spec);
        # The oracle pins exact bits; compare as doubles and via their IEEE
        # patterns so a -0/+0 or 1-ulp slip cannot hide behind numeric ==.
        my $ok_case = defined $resolved
            && unpack('Q<', pack('d<', $resolved)) eq unpack('Q<', pack('d<', $case->{expected}));
        if (!$ok_case) {
            $failures++;
            last if $failures > 5;
        }
    }
    is($failures, 0, 'every fixture case resolves bit-exactly against the upstream oracle');
    my %kind6 = map { $_->{label} => 1 } grep { $_->{config}{oscType} == 6 } @$cases;
    my @kind6_suffixes = qw(defaults range speed2.5 offset0.3 seed42 fm-speed nested-min negative-speed);
    my @missing = grep { !$kind6{"kind6-$_"} } @kind6_suffixes;
    is_deeply(\@missing, [], 'every noise2d (kind 6) case from the upstream range is covered');
}

# --- unit contract and depth guard -------------------------------------------

{
    my $sine = { type => 'Oscillator', oscType => 0, min => 0, max => 1, speed => 1, offset => 0, seed => 1 };
    ok(abs(evaluate_automation($sine, 0.25) - 0.5) < 1e-12, 'sine at t=0.25 is 0.5');
    is(evaluate_automation($sine, 0), 0, 'sine at t=0 is 0');
    ok(abs(evaluate_automation($sine, 1)) < 1e-12, 'sine at t=1 is 0');
    ok(is_automation_value($sine), 'is_automation_value accepts an Oscillator');
    ok(!is_automation_value({ type => 'Midi' }), 'is_automation_value rejects other automation types');
    # Depth > 8 collapses nested fields to the range-scaled zero, as upstream's
    # evaluator does; the top-level oscillator still evaluates deterministically.
    my $deep = $sine;
    $deep = { type => 'Oscillator', oscType => 0, min => $deep, max => 1, speed => 1, offset => 0, seed => 1 }
        for 1 .. 10;
    my $deep_value = evaluate_automation($deep, 0.5);
    ok((!ref $deep_value) && $deep_value == $deep_value
        && $deep_value >= 0 && $deep_value <= 1, 'depth guard keeps the 0..1 contract');
}

# --- DSL-level renders --------------------------------------------------------

{
    my $time = 0.25;
    my $animated = render_dsl(
        "search synth, filter\nnoise().threshold(level: osc(type: sine, min: 0.1, max: 0.4)).write(o0)\nrender(o0)",
        width => 3, height => 2, time => $time,
    );
    my $expected_value = evaluate_automation(
        { type => 'Oscillator', oscType => 0, min => 0.1, max => 0.4, speed => 1, offset => 0, seed => 1 }, $time);
    my $numeric = render_dsl(
        'search synth, filter' . "\n"
            . 'noise().threshold(level: ' . sprintf('%.17g', $expected_value) . ").write(o0)\nrender(o0)",
        width => 3, height => 2, time => $time,
    );
    is($animated->to_rgba8, $numeric->to_rgba8,
        'an osc() parameter renders byte-identically to its resolved numeric value');
}

{
    my $source = "search synth, filter\nnoise().threshold(level: osc(tri)).write(o0)\nrender(o0)";
    my $early  = render_dsl($source, width => 2, height => 1, time => 0.1);
    my $mid    = render_dsl($source, width => 2, height => 1, time => 0.5);
    isnt($early->to_rgba8, $mid->to_rgba8, 'an osc() value animates across time');
}

{
    # The conditional int selector receives Math.round of the resolved automation
    # value (upstream resolveUniformValue's spec.type === 'int' contract); a
    # fractional value leaking into the integer uniform would render differently.
    my $time = 0.25;
    my $raw  = evaluate_automation(
        { type => 'Oscillator', oscType => 0, min => 0, max => 1, speed => 1, offset => 0, seed => 1 }, $time);
    my $result = render_dsl(
        "search synth, filter\nnoise().invert(mode: osc(sine)).write(o0)\nrender(o0)",
        width => 2, height => 1, time => $time,
    );
    my $numeric = render_dsl(
        'search synth, filter' . "\n"
            . 'noise().invert(mode: ' . js_round($raw) . ").write(o0)\nrender(o0)",
        width => 2, height => 1, time => $time,
    );
    is($result->to_rgba8, $numeric->to_rgba8,
        'int choices params round the resolved automation value');
    my $mode0 = render_dsl("search synth, filter\nnoise().invert(mode: 0).write(o0)\nrender(o0)",
        width => 2, height => 1, time => $time);
    my $mode1 = render_dsl("search synth, filter\nnoise().invert(mode: 1).write(o0)\nrender(o0)",
        width => 2, height => 1, time => $time);
    isnt($mode0->to_rgba8, $mode1->to_rgba8, 'the rounded selection is observable');
}

{
    # An iterated step re-resolves its osc() params against each iteration's own
    # rewound time (the JS refreshIterationParams contract).
    my $time   = 0.25;
    my $early  = render_dsl(
        "search synth, filter\nnoise().write(o0)\nread(o0).feedback(mix: osc(tri), iterationCount: 6).write(o1)\nrender(o1)",
        width => 8, height => 8, time => $time,
    );
    my $later  = render_dsl(
        "search synth, filter\nnoise().write(o0)\nread(o0).feedback(mix: osc(tri), iterationCount: 6).write(o1)\nrender(o1)",
        width => 8, height => 8, time => $time + 0.5,
    );
    isnt($early->to_rgba8, $later->to_rgba8,
        'an iterated step animates its osc() params across rewound iteration time');
}

# --- compile-error contracts ---------------------------------------------------

{
    my $err = dsl_error("search synth, filter\nnoise().threshold(level: osc(wobble)).write(o0)\nrender(o0)",
        width => 1, height => 1);
    like($err, qr/osc\(\) type must resolve to a supported oscKind value; got "wobble"/, 'unknown kind name is a DslError');
    $err = dsl_error("search synth, filter\nnoise().threshold(level: osc(7)).write(o0)\nrender(o0)",
        width => 1, height => 1);
    like($err, qr/oscKind value \(0-6\)/, 'out-of-range integer kind is a DslError');
    $err = dsl_error("search synth, filter\nnoise().threshold(level: osc(type: sine, phase: 1)).write(o0)\nrender(o0)",
        width => 1, height => 1);
    like($err, qr/osc\(\) unknown parameter 'phase'; valid: type, min, max, speed, offset, seed/, 'unknown parameter is a DslError');
    $err = dsl_error("search synth, filter\nnoise().threshold(level: osc(type: sine, min: [1, 2])).write(o0)\nrender(o0)",
        width => 1, height => 1);
    like($err, qr/osc\(\) min must be a number or a nested osc\(\)/, 'non-numeric field is a DslError');
    # A color param rejects automation (the JS EffectDefinition rejects anything
    # but float/int at normalization); this port surfaces the rejection at
    # parameter validation instead of compile time.
    $err = dsl_error("search synth\nsolid(color: osc(sine)).write(o0)\nrender(o0)", width => 1, height => 1);
    like($err, qr/does not accept an osc\(\) automation value/, 'color param rejects automation');
}

{
    my $nested = 'osc(type: sine)';
    $nested = "osc(type: sine, min: $nested)" for 1 .. 9;
    my $err = dsl_error(
        "search synth, filter\nnoise().threshold(level: $nested).write(o0)\nrender(o0)", width => 1, height => 1);
    like($err, qr/Automation nesting exceeds the maximum depth of 8/,
        'osc() nesting beyond the upstream depth limit is rejected at compile time');
}

{
    my $time = 0.25;
    my $bound = render_dsl(
        "search synth, filter\nlet wobble = osc(type: sine, min: 0.1, max: 0.4)\n"
            . "noise().threshold(level: wobble).write(o0)\nrender(o0)",
        width => 3, height => 2, time => $time,
    );
    my $expected_value = evaluate_automation(
        { type => 'Oscillator', oscType => 0, min => 0.1, max => 0.4, speed => 1, offset => 0, seed => 1 }, $time);
    my $numeric = render_dsl(
        'search synth, filter' . "\n"
            . 'noise().threshold(level: ' . sprintf('%.17g', $expected_value) . ").write(o0)\nrender(o0)",
        width => 3, height => 2, time => $time,
    );
    is($bound->to_rgba8, $numeric->to_rgba8, 'a binding can hold an osc() value for reuse across steps');
}

done_testing();
