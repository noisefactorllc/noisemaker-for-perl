package Math::Fractal::Noisemaker::SinkManager;

use strict;
use warnings;
use Scalar::Util qw(blessed refaddr looks_like_number);
use JSON::PP ();

sub new {
    my ($class, %options) = @_;
    return bless {
        on_error          => $options{on_error},
        registrations     => [],
        registrations_by_id => {},
        stats             => {},
        descriptor        => {},
        configured        => 0,
        closed            => 0,
        iteration_depth   => 0,
        has_tombstones    => 0,
    }, $class;
}

sub _validate_sink {
    my ($sink) = @_;
    die "Sink must implement configure, submit, and close\n"
        unless blessed($sink)
            && $sink->can('configure')
            && $sink->can('submit')
            && $sink->can('close');
}

sub stats { $_[0]{stats} }

sub stats_for {
    my ($self, $sink) = @_;
    return undef unless ref $sink;
    my $id = refaddr($sink);
    my $registration = $self->{registrations_by_id}{$id};
    return undef unless $registration && $registration->{sink} == $sink;
    return $self->{stats}{$id};
}

sub add {
    my ($self, $sink) = @_;
    die "SinkManager is closed\n" if $self->{closed};
    _validate_sink($sink);
    my $id = refaddr($sink);
    my $existing = $self->{registrations_by_id}{$id};
    die "Sink is already registered\n" if $existing && $existing->{sink} == $sink;
    $sink->configure($self->{descriptor}) if $self->{configured};

    my $stats = { accepted => 0, dropped => 0, failed => 0 };
    my $registration = { sink => $sink, stats => $stats, active => 1 };
    push @{ $self->{registrations} }, $registration;
    $self->{registrations_by_id}{$id} = $registration;
    $self->{stats}{$id} = $stats;
    my $removed = 0;
    return sub {
        return if $removed;
        $removed = 1;
        $self->_remove_registration($registration);
    };
}

sub remove {
    my ($self, $sink) = @_;
    return unless ref $sink;
    my $registration = $self->{registrations_by_id}{ refaddr($sink) };
    $self->_remove_registration($registration)
        if $registration && $registration->{sink} == $sink;
}

sub _remove_registration {
    my ($self, $registration) = @_;
    return unless $registration && $registration->{active};
    my $sink = $registration->{sink};
    my $id = refaddr($sink);
    $registration->{active} = 0;
    $registration->{sink} = undef;
    $self->{has_tombstones} = 1;
    my $current = $self->{registrations_by_id}{$id};
    if ($current && refaddr($current) == refaddr($registration)) {
        delete $self->{registrations_by_id}{$id};
        delete $self->{stats}{$id};
    }

    my $ok = eval { $sink->close; 1 };
    my $error = $@;
    $self->_compact_registrations if $self->{iteration_depth} == 0;
    die $error unless $ok;
}

sub _compact_registrations {
    my ($self) = @_;
    return unless $self->{has_tombstones};
    $self->{registrations} = [grep { $_->{active} } @{ $self->{registrations} }];
    $self->{has_tombstones} = 0;
}

sub configure {
    my ($self, $descriptor) = @_;
    return if $self->{closed};
    $self->{descriptor} = defined $descriptor ? $descriptor : {};
    $self->{configured} = 1;
    $self->{iteration_depth}++;
    for my $registration (@{ $self->{registrations} }) {
        next unless $registration->{active};
        my $sink = $registration->{sink};
        my $ok = eval { $sink->configure($self->{descriptor}); 1 };
        if (!$ok) {
            my $error = $@;
            $registration->{stats}{failed}++;
            $self->_report($error, $sink);
        }
    }
    $self->{iteration_depth}--;
    $self->_compact_registrations if $self->{iteration_depth} == 0;
}

sub submit {
    my ($self, $frame, $timestamp) = @_;
    return if $self->{closed};
    $self->{iteration_depth}++;
    for my $registration (@{ $self->{registrations} }) {
        next unless $registration->{active};
        my $sink = $registration->{sink};
        my $result;
        my $ok = eval { $result = $sink->submit($frame, $timestamp); 1 };
        if (!$ok) {
            my $error = $@;
            $registration->{stats}{failed}++;
            $self->_report($error, $sink);
            next;
        }
        if (defined $result) {
            if ($result) { $registration->{stats}{accepted}++ }
            else         { $registration->{stats}{dropped}++ }
        }
    }
    $self->{iteration_depth}--;
    $self->_compact_registrations if $self->{iteration_depth} == 0;
}

sub _is_strict_boolean_true {
    my ($val) = @_;
    return 0 unless defined $val;
    if (eval { JSON::PP::is_bool($val) }) {
        return $val ? 1 : 0;
    }
    if (ref($val) eq 'SCALAR') {
        return (defined $$val && looks_like_number($$val) && $$val == 1) ? 1 : 0;
    }
    return 1 if !ref($val) && looks_like_number($val) && $val == 1;
    return 0;
}

sub should_defer_render {
    my ($self) = @_;
    return 0 if $self->{closed};
    $self->{iteration_depth}++;
    my $defer = 0;
    my $outer_error;
    eval {
        for my $registration (@{ $self->{registrations} }) {
            next unless $registration->{active};
            my $sink = $registration->{sink};
            next unless blessed($sink);
            my $method = $sink->can('deferRender') || $sink->can('defer_render');
            next unless $method;
            my $result;
            my $ok = eval { $result = $sink->$method(); 1 };
            if (!$ok) {
                my $error = $@;
                $registration->{stats}{failed}++;
                $self->_report($error, $sink);
                next;
            }
            if (_is_strict_boolean_true($result)) {
                $defer = 1;
                last;
            }
        }
        1;
    } or do {
        $outer_error = $@;
    };
    $self->{iteration_depth}--;
    $self->_compact_registrations if $self->{iteration_depth} == 0;
    die $outer_error if defined $outer_error;
    return $defer;
}
*shouldDeferRender = \&should_defer_render;

sub close {
    my ($self, $options) = @_;
    return if $self->{closed};
    $self->{closed} = 1;
    my $first_error;
    for my $registration (@{ $self->{registrations} }) {
        next unless $registration->{active};
        my $sink = $registration->{sink};
        $registration->{active} = 0;
        $registration->{sink} = undef;
        my $ok = eval {
            defined $options ? $sink->close($options) : $sink->close;
            1;
        };
        $first_error = $@ if !$ok && !defined $first_error;
    }
    $self->{registrations} = [];
    $self->{registrations_by_id} = {};
    %{ $self->{stats} } = ();
    $self->{has_tombstones} = 0;
    die $first_error if defined $first_error;
}

sub _report {
    my ($self, $error, $sink) = @_;
    return unless ref $self->{on_error} eq 'CODE';
    eval { $self->{on_error}->($error, $sink) };
}

1;

__END__

=head1 NAME

Math::Fractal::Noisemaker::SinkManager - deliver rendered frames to output sinks

=head1 SYNOPSIS

    my $renderer = Math::Fractal::Noisemaker::Renderer->new(
        on_sink_error => sub { my ($error, $sink) = @_; warn $error },
    );
    my $unsubscribe = $renderer->add_sink($sink);
    # Render frames, then release the registration:
    $unsubscribe->();
    $renderer->dispose;

=head1 SINK CONTRACT

A sink is a blessed object with C<configure($descriptor)>,
C<submit($surface, $timestamp_ms)>, and C<close($options)> methods.
The descriptor describes width, height, format, colorSpace, alphaMode, and fps.
Callbacks run synchronously. Frames and descriptors are borrowed; do not mutate
them. Clone a surface when retaining an independent image.

C<submit> returns true for accepted, false for dropped, or C<undef> for an
untracked submission. Thrown configure/submit exceptions increment failed
counts, invoke the optional error callback, and allow later sinks to run.

=head1 METHODS

=head2 new(on_error => $callback)

Creates an empty manager. The optional callback receives C<($error, $sink)>;
exceptions from the error callback are contained.

=head2 add($sink), remove($sink)

C<add> returns an idempotent unsubscribe coderef. Adding the same sink twice
or adding after closure throws. A newly added sink is immediately configured
if the manager already has a descriptor. C<remove> or unsubscribe closes the
sink and removes its statistics; close errors propagate.

=head2 configure($descriptor), submit($surface, $timestamp_ms)

Configure all active sinks or deliver a frame to them in registration order.
Neither method starts a worker, schedules frames, nor waits for asynchronous
completion. Calls on a closed manager do nothing.

=head2 stats(), stats_for($sink)

Return live, read-only-by-convention statistics: C<accepted>, C<dropped>, and
C<failed>. C<stats> maps object identities to those hashes; C<stats_for> returns
C<undef> for an unregistered sink. These are sink submission counts, not the
completion counters of C<FrameExportQueue>.

=head2 should_defer_render(), shouldDeferRender()

Returns true (1) if any active registered sink requests deferral via a
C<deferRender> or C<defer_render> method returning strict boolean true.
Exceptions thrown by sinks are isolated: they increment the sink's C<failed>
counter and invoke the optional error callback without preventing other sinks
from being checked. Returns 0 if no sink defers or if the manager is closed.

=head2 close($options)

Closes every registered sink and clears registrations. Repeated calls do
nothing. The first close error is rethrown after all sinks have been visited.
Optional options are forwarded unchanged to sinks.

=cut
