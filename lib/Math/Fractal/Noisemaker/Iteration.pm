package Math::Fractal::Noisemaker::Iteration;

# Pure grouping and schedule helpers for stateful/particle CPU effects.

use strict;
use warnings;
use Exporter 'import';
use Scalar::Util ();

our @EXPORT_OK = qw(
    compute_iteration_groups
    is_particle_state_name
    iteration_delta_time
    wrap01
);

sub iteration_delta_time { 1 / 600 }

sub wrap01 {
    my ($value) = @_;
    return $value - int($value) + ($value < 0 && $value != int($value) ? 1 : 0);
}

sub is_particle_state_name {
    my ($name) = @_;
    return defined $name && !ref $name
        && $name =~ /\A(?:global_(?:xyz|vel|rgba|life_data)|global_.*_trail)\z/ ? 1 : 0;
}

sub _definition {
    my ($step, $effects) = @_;
    return {} unless ($step->{kind} || '') eq 'effect';
    return $effects->{ $step->{effect_id} } || {};
}

sub _declares_xyz {
    my ($step, $effects) = @_;
    my $definition = _definition($step, $effects);
    return exists(($definition->{textures} || {})->{global_xyz}) ? 1 : 0;
}

sub _references_particle_state {
    my ($step, $effects) = @_;
    my $definition = _definition($step, $effects);
    for my $pass (@{ $definition->{passes} || [] }) {
        for my $name (values %{ $pass->{inputs} || {} }, values %{ $pass->{outputs} || {} }) {
            return 1 if is_particle_state_name($name);
        }
    }
    return 0;
}

sub _iterated {
    my ($step, $effects) = @_;
    return _definition($step, $effects)->{iterated} ? 1 : 0;
}

# JS-coercion mirrors for the animated-input merge rule: JS reads
# `undefined > 0` as false and `undefined !== 0` as true, so a missing
# iterationCount blocks the merge while a missing speed allows it.
sub _positive_param {
    my ($value) = @_;
    return defined $value && !ref $value
        && Scalar::Util::looks_like_number($value) && $value > 0 ? 1 : 0;
}

sub _zero_param {
    my ($value) = @_;
    return defined $value && !ref $value
        && Scalar::Util::looks_like_number($value) && $value == 0 ? 1 : 0;
}

sub compute_iteration_groups {
    my ($steps, $effects) = @_;
    $effects ||= {};
    my @groups;
    my $open;
    my $open_loop;
    my $close = sub {
        return unless $open;
        push @groups, $open;
        $open = undef;
    };

    for my $step (@$steps) {
        my $kind = $step->{kind} || '';
        my $role = _definition($step, $effects)->{loopRole} || '';
        if ($open_loop) {
            die "Loop iteration group cannot cross a read/write boundary\n"
                if $kind eq 'read' || $kind eq 'write';
            die "Nested loop iteration groups are not supported\n" if $role eq 'begin';
            push @{ $open_loop->{steps} }, $step;
            if ($role eq 'end') {
                push @groups, { steps => $open_loop->{steps}, iterated => 1, loop => 1 };
                $open_loop = undef;
            }
            next;
        }
        if ($kind eq 'read' || $kind eq 'write') {
            $close->();
            push @groups, { steps => [$step], iterated => 0 };
            next;
        }
        die "loopEnd has no matching loopBegin\n" if $role eq 'end';
        if ($role eq 'begin') {
            $close->();
            $open_loop = { steps => [$step] };
            next;
        }
        if (_declares_xyz($step, $effects)) {
            $close->();
            $open = { steps => [$step], iterated => _iterated($step, $effects) };
            next;
        }
        if ($open && _references_particle_state($step, $effects)) {
            push @{ $open->{steps} }, $step;
            next;
        }
        # The authority re-runs animated noise3d before every flow3d tick:
        # a single preceding synth3d/noise3d step with a non-zero speed joins
        # the flow3d step in one iterated group (mirrors cpu's
        # computeIterationGroups animated-input rule).
        my $previous = $groups[-1];
        if (!$open
            && ($step->{effect_id} // '') eq 'filter3d/flow3d'
            && _positive_param($step->{params}{iterationCount})
            && $previous
            && @{ $previous->{steps} } == 1
            && ($previous->{steps}[0]{effect_id} // '') eq 'synth3d/noise3d'
            && !_zero_param($previous->{steps}[0]{params}{speed})) {
            pop @groups;
            push @groups, { steps => [ $previous->{steps}[0], $step ], iterated => 1 };
            next;
        }
        $close->();
        push @groups, { steps => [$step], iterated => _iterated($step, $effects) };
    }
    die "loopBegin has no matching loopEnd\n" if $open_loop;
    $close->();
    return \@groups;
}

1;
