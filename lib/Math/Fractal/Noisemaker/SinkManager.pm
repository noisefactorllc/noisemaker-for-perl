package Math::Fractal::Noisemaker::SinkManager;

use strict;
use warnings;
use Scalar::Util qw(blessed refaddr);

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
