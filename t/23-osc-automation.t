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
    ok(is_automation_value({ type => 'Midi' }), 'is_automation_value accepts a Midi value');
    ok(is_automation_value({ type => 'Audio' }), 'is_automation_value accepts an Audio value');
    ok(!is_automation_value({ type => 'Unexpected' }), 'is_automation_value rejects other automation types');
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

# The DSL compiles upstream's midi()/audio() value calls into Midi/Audio
# automation values; with no live input they resolve to their `min` field, and
# an invalid Audio value returns its literal `min` (or 0). Each accepted case
# renders byte-identically to the resolved numeric literal; each rejected
# argument is a DslError with the same message template the compiler uses.
{
    # Accepted cases: [value, resolved 17g literal] — the resolved value scales
    # into the parameter's declared range exactly like the literal render.
    my @ACCEPTED = (
        [ 'midi(channel: 1, mode: midiMode.velocity, min: 0.25, max: 0.75)', '25.75' ],
        [ 'midi(channel: 1)', '1' ],
        [ 'midi(channel: 2, mode: midiMode.cc, cc: 7, min: 0.3, max: 0.8, sensitivity: 2)', '30.7' ],
        [ 'midi(channel: 1, mode: midiMode.nrpn, nrpn: 300, min: 0.15, sensitivity: 2, name: "Port A", id: "abc")', '15.85' ],
        [ 'audio(band: audioBand.low, min: 0.25, max: 0.75)', '25.75' ],
        [ 'audio(band: audioBand.vol, min: 0.55, channel: 3, name: "Mic", id: "dev-1")', '55.45' ],
        [ 'audio(band: audioBand.raw, min: 0.65)', '65.35000000000001' ],
        [ 'midi(2, min: 0.3, mode: midiMode.cc, cc: 7)', '30.7' ],
        [ 'audio(audioBand.mid, 0.35, 0.8)', '35.65' ],
        [ 'audio(audioBand.high, 0.45, channel: 2)', '45.550000000000004' ],
        # let variables holding automation values, and nested automation in both
        # directions.
        [ 'bass', '25.75',
          "let bass = audio(band: audioBand.low, min: 0.25, max: 0.75)\n" ],
        [ 'rate', '30.7',
          "let floor = audio(band: audioBand.low, min: 0.3)\nlet rate = midi(channel: 1, min: floor, max: 1)\n" ],
        [ 'osc(type: oscKind.sine, min: 0.25, max: 0.75, speed: audio(band: audioBand.low, min: 0, max: 1))', '25.75' ],
        [ 'osc(type: oscKind.tri, min: midi(channel: 3, min: 0.2), max: audio(band: audioBand.mid, min: 0.7))', '45.55' ],
        [ 'midi(channel: 1, min: osc(type: oscKind.tri, min: 0.2, max: 0.6))', '40.6' ],
        [ 'audio(band: audioBand.low, min: osc(type: oscKind.saw, min: 0.1, max: 0.5))', '20.8' ],
        # int parameters round the resolved value (upstream uniform1i truncation).
        [ 'audio(band: audioBand.low, min: 0.5)', '4', '', 'octaves' ],
        # Upstream S002 warnings keep the field's fallback and mark _invalid; the
        # resolved value is unchanged where the fallback keeps it.
        [ 'midi(channel: 20, min: 0.25)', '25.75' ],
        [ 'midi(channel: 1, mode: midiMode.bogus, min: 0.25)', '25.75' ],
        [ 'midi(channel: 1, mode: midiMode.nrpn, min: 0.25)', '25.75' ],
        [ 'midi(zone: midiZone.lower, members: 0)', '1' ],
        [ 'midi(channel: 1, min: true)', '100' ],
        [ 'midi(channel: 1, min: 1.5)', '100' ],
        [ 'audio(band: audioBand.low, min: 0.25, channel: 40)', '25.75' ],
        [ 'audio(band: audioBand.bogus, min: 0.25)', '25.75' ],
        [ 'audio(band: audioBand.low, min: true)', '1' ],
        [ 'audio(band: audioBand.low, min: osc(type: oscKind.saw, min: 0.1, max: 0.5), channel: 40)', '1' ],
    );
    for my $case (@ACCEPTED) {
        my ($value, $resolved, $lets, $param) = @$case;
        $lets //= '';
        $param //= 'scaleX';
        my $source = "search synth\n${lets}noise(seed: 1, $param: $value).write(o0)\nrender(o0)";
        my $result = render_dsl($source, width => 8, height => 8, seed => 1, time => 0.25);
        my $numeric = render_dsl("search synth\n${lets}noise(seed: 1, $param: $resolved).write(o0)\nrender(o0)",
            width => 8, height => 8, seed => 1, time => 0.25);
        is($result->to_rgba8, $numeric->to_rgba8, "\"$value\" resolves to $resolved");
    }

    # Arguments the compiler rejects. Each error names the call (P003) or the
    # field (S001/S003) with the same message templates the compiler uses.
    my $MIDI_FIELDS = 'channel, mode, min, max, sensitivity, name, id, cc, nrpn, zone, members';
    my $AUDIO_FIELDS = 'band, min, max, channel, name, id';
    my @REJECTED = (
        [ 'midi(channel: 1, wobble: 2)', qr/Unknown parameter "wobble" for midi\(\); accepted: \Q$MIDI_FIELDS\E$/ ],
        [ 'midi(min: 0.5)', qr/Missing required parameter "channel" for midi\(\)$/ ],
        [ 'midi(1, 2, 3, 4, 5, 6)', qr/Unknown parameter "argument 6" for midi\(\); accepted: / ],
        [ 'midi(channel: 1, zone: midiZone.lower)', qr/Unsupported DSL value Call "midi"$/ ],
        [ 'midi(channel: 1, members: 0)', qr/Missing required parameter "zone" for midi\(\)$/ ],
        [ 'midi(zone: midiZone.lower, members: 0, channel: 1)', qr/Unsupported DSL value Call "midi"$/ ],
        [ 'midi(channel: 1, id: "x")', qr/Missing required parameter "name" for midi\(\)$/ ],
        [ 'midi(channel: 1, name: "")', qr/Unsupported DSL value Call "midi"$/ ],
        [ 'midi(channel: 1, name: port)', qr/Unsupported DSL value Call "midi"$/ ],
        [ 'midi(channel: "1")', qr/Parameter "channel" must be a finite number$/ ],
        [ 'midi(channel: 1, mode: "cc")', qr/Parameter "mode" must be an enum value$/ ],
        [ 'midi(channel: foo)', qr/Parameter "channel" must be a finite number$/ ],
        [ 'audio(min: 0.5)', qr/Missing required parameter "band" for audio\(\)$/ ],
        [ 'audio(audioBand.low, 0.35, 0.8, 1)', qr/Unknown parameter "argument 4" for audio\(\); accepted: \Q$AUDIO_FIELDS\E$/ ],
        [ 'audio(band: audioBand.low, name: "Mic")', qr/Missing required parameter "channel" for audio\(\)$/ ],
        [ 'audio(band: audioBand.low, id: "dev-1")', qr/Missing required parameter "name" for audio\(\)$/ ],
        [ 'audio(band: audioBand.low, name: "", channel: 1)', qr/Unsupported DSL value Call "audio"$/ ],
        [ 'audio(band: audioBand.low, name: "Mic", id: "dev-1")', qr/Missing required parameter "channel" for audio\(\)$/ ],
        [ 'audio(band: audioBand.low, min: osc(type: oscKind.saw, min: 0.1, max: 0.5), channel: "1")', qr/Parameter "channel" must be an integer$/ ],
    );
    for my $case (@REJECTED) {
        my ($value, $pattern) = @$case;
        my $source = "search synth\nnoise(seed: 1, scaleX: $value).write(o0)\nrender(o0)";
        my $err = dsl_error($source, width => 8, height => 8, seed => 1, time => 0.25);
        like($err, $pattern, "\"$value\" is rejected");
    }
}

done_testing();
