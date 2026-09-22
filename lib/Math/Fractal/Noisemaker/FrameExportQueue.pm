package Math::Fractal::Noisemaker::FrameExportQueue;

use strict;
use warnings;
use Scalar::Util qw(blessed looks_like_number);

sub _validate_adapter {
    my ($adapter) = @_;
    die "Frame export adapter must implement create_slot, begin, poll, read, and destroy_slot\n"
        unless blessed($adapter)
            && $adapter->can('create_slot')
            && $adapter->can('begin')
            && $adapter->can('poll')
            && $adapter->can('read')
            && $adapter->can('destroy_slot');
}

sub new {
    my ($class, $adapter, %options) = @_;
    _validate_adapter($adapter);
    my $count = defined $options{slots} ? $options{slots} : 3;
    die "Frame export slots must be an integer from 2 through 8\n"
        unless $count =~ /^\d+$/ && $count >= 2 && $count <= 8;
    my @slots = map {
        {
            adapter_slot => undef, created => 0, pending => 0,
            frame => undef, timestamp => undef, on_frame => undef, context => undef,
        }
    } 1 .. $count;
    return bless {
        adapter => $adapter,
        on_error => $options{on_error},
        slots => \@slots,
        configured => 0,
        closed => 0,
        stats => { accepted => 0, dropped => 0, completed => 0, failed => 0 },
    }, $class;
}

sub stats { $_[0]{stats} }

sub available {
    my ($self) = @_;
    return 0 unless $self->{configured} && !$self->{closed};
    return (grep { !$_->{pending} } @{ $self->{slots} }) ? 1 : 0;
}

sub configure {
    my ($self, $descriptor) = @_;
    return if $self->{closed};
    my $destroy_error = $self->_destroy_slots;
    $self->{configured} = 0;
    die $destroy_error if defined $destroy_error;

    my $ok = eval {
        for my $index (0 .. $#{ $self->{slots} }) {
            my $record = $self->{slots}[$index];
            $record->{adapter_slot} = $self->{adapter}->create_slot($index, $descriptor);
            $record->{created} = 1;
        }
        1;
    };
    if (!$ok) {
        my $error = $@;
        my $cleanup_error = $self->_destroy_slots;
        $self->_report($cleanup_error) if defined $cleanup_error;
        die $error;
    }
    $self->{configured} = 1;
}

sub enqueue {
    my ($self, $frame, $timestamp, $on_frame, $context) = @_;
    die "Frame export callback must be a code reference\n" unless ref $on_frame eq 'CODE';
    if (!$self->{configured} || $self->{closed}) {
        $self->{stats}{dropped}++;
        return 0;
    }
    my ($record) = grep { !$_->{pending} } @{ $self->{slots} };
    if (!$record) {
        $self->{stats}{dropped}++;
        return 0;
    }
    $record->{pending} = 1;
    $record->{frame} = $frame;
    $record->{timestamp} = $timestamp;
    $record->{on_frame} = $on_frame;
    $record->{context} = $context;
    my $ok = eval { $self->{adapter}->begin($record->{adapter_slot}, $frame, $timestamp); 1 };
    if (!$ok) {
        my $error = $@;
        _release($record);
        $self->{stats}{failed}++;
        $self->_report($error);
        return 0;
    }
    $self->{stats}{accepted}++;
    return 1;
}

sub poll {
    my ($self) = @_;
    return unless $self->{configured} && !$self->{closed};
    for my $record (@{ $self->{slots} }) {
        next unless $record->{pending};
        my ($ready, $frame, $timestamp, $on_frame, $context);
        my $ok = eval {
            $ready = $self->{adapter}->poll($record->{adapter_slot});
            die "Frame export adapter poll must return a boolean\n"
                unless defined $ready
                    && !ref $ready
                    && looks_like_number($ready)
                    && ($ready == 0 || $ready == 1);
            $ready = $ready == 1 ? 1 : 0;
            if ($ready) {
                $frame = $self->{adapter}->read($record->{adapter_slot});
                $timestamp = $record->{timestamp};
                $on_frame = $record->{on_frame};
                $context = $record->{context};
            }
            1;
        };
        if (!$ok) {
            my $error = $@;
            _release($record);
            $self->{stats}{failed}++;
            $self->_report($error);
            next;
        }
        next unless $ready;
        _release($record);
        $ok = eval { $on_frame->($frame, $timestamp, $context); 1 };
        if ($ok) { $self->{stats}{completed}++ }
        else {
            my $error = $@;
            $self->{stats}{failed}++;
            $self->_report($error);
        }
    }
}

sub close {
    my ($self, @args) = @_;
    return if $self->{closed};
    my %options = @args == 1 && ref $args[0] eq 'HASH' ? %{ $args[0] } : @args;
    $self->{closed} = 1;
    $self->{configured} = 0;
    my $destroy_error;
    if ($options{backend_lost} || $options{backendLost}) { $self->_abandon_slots }
    else { $destroy_error = $self->_destroy_slots }
    $self->{adapter} = undef;
    die $destroy_error if defined $destroy_error;
}

sub _release {
    my ($record) = @_;
    $record->{pending} = 0;
    $record->{frame} = undef;
    $record->{timestamp} = undef;
    $record->{on_frame} = undef;
    $record->{context} = undef;
}

sub _destroy_slots {
    my ($self) = @_;
    my $first_error;
    for my $record (@{ $self->{slots} }) {
        next unless $record->{created};
        my $adapter_slot = $record->{adapter_slot};
        $record->{created} = 0;
        $record->{adapter_slot} = undef;
        _release($record);
        my $ok = eval { $self->{adapter}->destroy_slot($adapter_slot); 1 };
        $first_error = $@ if !$ok && !defined $first_error;
    }
    return $first_error;
}

sub _abandon_slots {
    my ($self) = @_;
    for my $record (@{ $self->{slots} }) {
        $record->{created} = 0;
        $record->{adapter_slot} = undef;
        _release($record);
    }
}

sub _report {
    my ($self, $error) = @_;
    return unless ref $self->{on_error} eq 'CODE';
    eval { $self->{on_error}->($error) };
}

1;

__END__

=head1 NAME

Math::Fractal::Noisemaker::FrameExportQueue - bounded frame export callbacks

=head1 SYNOPSIS

    my $queue = $renderer->create_frame_export_queue(slots => 3);
    $queue->configure({width => 32, height => 32, format => 'rgba8unorm',
        colorSpace => 'srgb', alphaMode => 'straight', fps => 30});
    $queue->enqueue($surface, 0, sub {
        my ($frame, $timestamp, $context) = @_;
        my $owned_bytes = ${ $frame->data }; # copy before a slot is reused
    });
    $queue->poll;
    $queue->close;

=head1 METHODS

=head2 new($adapter, slots => 3, on_error => $callback)

Creates a queue with 2 through 8 slots. Normally use the renderer's factory
for the CPU adapter. Custom adapters must implement C<create_slot>, C<begin>,
C<poll>, C<read>, and C<destroy_slot>. The optional callback receives errors;
exceptions it throws are contained.

=head2 configure($descriptor)

Destroys old slots and allocates replacements. Pending callbacks are discarded.
Failure cleans up newly created slots and throws; the queue remains unconfigured.
The CPU descriptor is documented in L<Math::Fractal::Noisemaker::CpuFrameExportAdapter>.

=head2 available()

Returns whether the queue is configured, open, and has a free slot.

=head2 enqueue($surface, $timestamp_ms, $callback, $context)

Returns 1 when accepted or 0 when full, unconfigured, closed, or the adapter
fails. A callback coderef is required even if the queue cannot accept a frame.
C<$context> is optional and returned unchanged to the callback. CPU pixel bytes
are copied at enqueue time; callbacks are delivered only when C<poll> is called.

=head2 poll()

Checks pending slots and calls C<$callback-E<gt>($frame, $timestamp_ms, $context)>
for ready frames. The frame and its data scalar reference belong to a reusable
slot. Copy the bytes during the callback if they must survive another enqueue.
Adapter and callback failures are counted and sent to C<on_error>.

=head2 stats()

Returns the live counter hash: C<accepted> counts successful begins;
C<completed> counts successful callbacks; C<failed> counts begin, poll, read,
and callback errors; C<dropped> counts rejected enqueue attempts. Reconfiguration
and closure discard pending work without updating these counters, so these
counters are not a conservation equation for individual frame outcomes.

=head2 close(%options)

Discards pending work and closes the queue. Repeated calls are harmless.
C<backend_lost =E<gt> 1> (also C<backendLost>) abandons slots without asking
the adapter to destroy them. Otherwise destruction errors propagate after
cleanup. The queue cannot be reopened.

=cut
