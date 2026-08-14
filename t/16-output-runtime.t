use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Scalar::Util qw(refaddr);

use Math::Fractal::Noisemaker::CpuFrameExportAdapter;
use Math::Fractal::Noisemaker::FrameExportQueue;
use Math::Fractal::Noisemaker::Renderer;
use Math::Fractal::Noisemaker::SinkManager;
use Math::Fractal::Noisemaker::Surface;

{
    package Local::Sink;

    sub new {
        my ($class, %args) = @_;
        return bless { events => [], result => 1, %args }, $class;
    }

    sub configure {
        my ($self, $descriptor) = @_;
        push @{ $self->{events} }, ['configure', { %$descriptor }];
    }

    sub submit {
        my ($self, $frame, $timestamp) = @_;
        push @{ $self->{events} }, ['submit', $frame, $timestamp];
        return $self->{on_submit}->($self, $frame, $timestamp) if $self->{on_submit};
        die $self->{error} if $self->{error};
        return $self->{result};
    }

    sub close {
        my ($self, $options) = @_;
        push @{ $self->{events} }, ['close', $options];
        die $self->{close_error} if $self->{close_error};
    }
}

{
    package Local::Adapter;

    sub new { bless { slots => [] }, shift }

    sub create_slot {
        my ($self, $index, $descriptor) = @_;
        die "slot creation failed\n" if defined $self->{create_error} && $self->{create_error} == $index;
        my $slot = { index => $index, descriptor => $descriptor, ready => 0, destroys => 0 };
        push @{ $self->{slots} }, $slot;
        return $slot;
    }

    sub begin {
        my ($self, $slot, $value, $timestamp) = @_;
        $slot->{ready} = 0;
        $slot->{value} = $value;
    }

    sub poll { $_[1]{ready} }
    sub read { $_[1]{value} }

    sub destroy_slot {
        my ($self, $slot) = @_;
        $slot->{destroys}++;
        die "destroy $slot->{index} failed\n"
            if defined $self->{destroy_error} && $self->{destroy_error} == $slot->{index};
    }
}

subtest 'SinkManager configures current and later sinks' => sub {
    my $first = Local::Sink->new;
    my $later = Local::Sink->new;
    my $manager = Math::Fractal::Noisemaker::SinkManager->new;
    my $descriptor = { width => 2, height => 3 };

    $manager->add($first);
    $manager->configure($descriptor);
    $manager->add($later);

    is_deeply($first->{events}, [['configure', $descriptor]], 'current sink configured');
    is_deeply($later->{events}, [['configure', $descriptor]], 'later sink configured immediately');
};

subtest 'SinkManager isolates failures and counts outcomes' => sub {
    my @reported;
    my $manager = Math::Fractal::Noisemaker::SinkManager->new(on_error => sub {
        my ($error, $sink) = @_;
        push @reported, [$error, $sink];
        die "reporter failed\n";
    });
    my $accepted = Local::Sink->new(result => 1);
    my $dropped = Local::Sink->new(result => 0);
    my $failed = Local::Sink->new(error => "sink failed\n");
    my $later = Local::Sink->new(result => 1);
    $manager->add($_) for ($accepted, $dropped, $failed, $later);

    eval { $manager->submit(Math::Fractal::Noisemaker::Surface->new(1, 1), 10) };
    is($@, '', 'sink and reporter failures are isolated');
    is_deeply($manager->stats_for($accepted), { accepted => 1, dropped => 0, failed => 0 }, 'accepted counted');
    is_deeply($manager->stats_for($dropped), { accepted => 0, dropped => 1, failed => 0 }, 'drop counted');
    is_deeply($manager->stats_for($failed), { accepted => 0, dropped => 0, failed => 1 }, 'failure counted');
    is_deeply($manager->stats_for($later), { accepted => 1, dropped => 0, failed => 0 }, 'later sink still called');
    is($reported[0][0], "sink failed\n", 'failure reported');
    is($reported[0][1], $failed, 'failing sink reported by identity');
};

subtest 'SinkManager supports reentrant removal and terminal close' => sub {
    my $manager = Math::Fractal::Noisemaker::SinkManager->new;
    my $self_removing = Local::Sink->new;
    $self_removing->{on_submit} = sub { $manager->remove($self_removing); return 1 };
    my $later = Local::Sink->new;
    $manager->add($self_removing);
    $manager->add($later);

    $manager->submit(Math::Fractal::Noisemaker::Surface->new(1, 1), 20);

    is_deeply([map { $_->[0] } @{ $self_removing->{events} }], ['submit', 'close'], 'self-removing sink closed');
    is_deeply([map { $_->[0] } @{ $later->{events} }], ['submit'], 'later sink was not skipped');
    ok(!defined $manager->stats_for($self_removing), 'removed stats deleted');

    my $first = Local::Sink->new(close_error => "first close failed\n");
    my $second = Local::Sink->new;
    my $closing = Math::Fractal::Noisemaker::SinkManager->new;
    $closing->add($first);
    $closing->add($second);
    my $stats = $closing->stats;
    eval { $closing->close({ backendLost => 1 }) };
    like($@, qr/first close failed/, 'first close error rethrown');
    is_deeply([map { $_->[0] } @{ $second->{events} }], ['close'], 'later sink still closed');
    is(refaddr($closing->stats), refaddr($stats), 'close preserves stats collection identity');
    is_deeply($stats, {}, 'close clears retained stats collection');
    eval { $closing->close };
    is($@, '', 'second close is inert');
    eval { $closing->add(Local::Sink->new) };
    like($@, qr/closed/, 'closed manager rejects later sinks');
};

subtest 'FrameExportQueue enforces bounds, backpressure, context, and reuse' => sub {
    eval { Math::Fractal::Noisemaker::FrameExportQueue->new(Local::Adapter->new, slots => 1) };
    like($@, qr/2 through 8/, 'slot lower bound enforced');
    my $adapter = Local::Adapter->new;
    my $queue = Math::Fractal::Noisemaker::FrameExportQueue->new($adapter, slots => 2);
    my @completed;
    my $context = { sequence => 7 };
    $queue->configure({ width => 1, height => 1 });

    ok($queue->enqueue('one', 10, sub { push @completed, [@_] }, $context), 'first frame accepted');
    ok($queue->enqueue('two', 20, sub { }), 'second frame accepted');
    ok(!$queue->enqueue('overflow', 30, sub { }), 'overflow dropped');
    $adapter->{slots}[0]{ready} = 1;
    $queue->poll;

    is_deeply($completed[0], ['one', 10, $context], 'callback receives frame, timestamp, and context');
    ok($queue->enqueue('replacement', 40, sub { }), 'released slot reused');
    is_deeply($queue->stats, { accepted => 3, dropped => 1, completed => 1, failed => 0 }, 'queue stats stable');
};

subtest 'FrameExportQueue isolates callback failures and rolls back configuration' => sub {
    my @errors;
    my $adapter = Local::Adapter->new;
    my $queue = Math::Fractal::Noisemaker::FrameExportQueue->new(
        $adapter, slots => 2, on_error => sub { push @errors, $_[0] },
    );
    $queue->configure({ width => 1, height => 1 });
    $queue->enqueue('one', 10, sub { die "callback failed\n" });
    $adapter->{slots}[0]{ready} = 1;
    $queue->poll;
    is_deeply(\@errors, ["callback failed\n"], 'callback error reported');
    ok($queue->available, 'slot reusable after callback failure');
    is_deeply($queue->stats, { accepted => 1, dropped => 0, completed => 0, failed => 1 }, 'callback failure counted');

    my $later_adapter = Local::Adapter->new;
    my $later_queue = Math::Fractal::Noisemaker::FrameExportQueue->new($later_adapter, slots => 2);
    my @later_frames;
    $later_queue->configure({ width => 1, height => 1 });
    $later_queue->enqueue('waiting', 1, sub { push @later_frames, $_[0] });
    $later_queue->enqueue('ready', 2, sub { push @later_frames, $_[0] });
    $later_adapter->{slots}[1]{ready} = 1;
    $later_queue->poll;
    is_deeply(\@later_frames, ['ready'], 'an unready slot does not prevent later completions');

    for my $invalid_ready (2, 'ready', {}) {
        my @poll_errors;
        my $invalid_adapter = Local::Adapter->new;
        my $invalid_queue = Math::Fractal::Noisemaker::FrameExportQueue->new(
            $invalid_adapter, slots => 2, on_error => sub { push @poll_errors, $_[0] },
        );
        $invalid_queue->configure({ width => 1, height => 1 });
        my $callback_called = 0;
        $invalid_queue->enqueue('invalid', 3, sub { $callback_called++ });
        $invalid_adapter->{slots}[0]{ready} = $invalid_ready;
        $invalid_queue->poll;
        like($poll_errors[0], qr/poll must return a boolean/, 'non-boolean poll result reported');
        is($callback_called, 0, 'non-boolean poll result does not invoke callback');
        is($invalid_queue->stats->{failed}, 1, 'non-boolean poll result counted as failure');
    }

    my @numeric_zero_errors;
    my $numeric_zero_adapter = Local::Adapter->new;
    my $numeric_zero_queue = Math::Fractal::Noisemaker::FrameExportQueue->new(
        $numeric_zero_adapter, slots => 2,
        on_error => sub { push @numeric_zero_errors, $_[0] },
    );
    $numeric_zero_queue->configure({ width => 1, height => 1 });
    my @numeric_zero_frames;
    $numeric_zero_queue->enqueue('numeric zero', 4, sub { push @numeric_zero_frames, $_[0] });
    $numeric_zero_adapter->{slots}[0]{ready} = '0.0';
    $numeric_zero_queue->poll;
    is_deeply(\@numeric_zero_errors, [], 'numeric zero poll result is valid');
    is_deeply(\@numeric_zero_frames, [], 'numeric zero poll result remains pending');
    $numeric_zero_adapter->{slots}[0]{ready} = 1;
    $numeric_zero_queue->poll;
    is_deeply(\@numeric_zero_frames, ['numeric zero'], 'pending frame completes after true poll');

    my $failing = Local::Adapter->new;
    $failing->{create_error} = 1;
    my $rollback = Math::Fractal::Noisemaker::FrameExportQueue->new($failing, slots => 2);
    eval { $rollback->configure({ width => 1, height => 1 }) };
    like($@, qr/slot creation failed/, 'creation error rethrown');
    is($failing->{slots}[0]{destroys}, 1, 'partially created slot destroyed');
    ok(!$rollback->available, 'failed configuration stays unavailable');
};

subtest 'FrameExportQueue close destroys or abandons every slot once' => sub {
    my $adapter = Local::Adapter->new;
    my $queue = Math::Fractal::Noisemaker::FrameExportQueue->new($adapter, slots => 2);
    $queue->configure({ width => 1, height => 1 });
    $adapter->{destroy_error} = 0;
    eval { $queue->close };
    like($@, qr/destroy 0 failed/, 'first destroy error rethrown');
    is_deeply([map { $_->{destroys} } @{ $adapter->{slots} }], [1, 1], 'all slots destroyed once');
    eval { $queue->close };
    is($@, '', 'close remains idempotent');
    ok(!$queue->enqueue('late', 0, sub { }), 'closed queue drops late frame');

    my $lost_adapter = Local::Adapter->new;
    my $lost = Math::Fractal::Noisemaker::FrameExportQueue->new($lost_adapter, slots => 2);
    $lost->configure({ width => 1, height => 1 });
    $lost->close(backend_lost => 1);
    is_deeply([map { $_->{destroys} } @{ $lost_adapter->{slots} }], [0, 0], 'backend loss abandons slots');
};

sub export_bytes {
    my ($surface, $alpha_mode) = @_;
    my $queue = Math::Fractal::Noisemaker::FrameExportQueue->new(
        Math::Fractal::Noisemaker::CpuFrameExportAdapter->new, slots => 2,
    );
    my $received;
    $queue->configure({
        width => $surface->width, height => $surface->height,
        format => 'rgba8unorm', colorSpace => 'srgb', alphaMode => $alpha_mode, fps => 60,
    });
    $queue->enqueue($surface, 42, sub { $received = ${ $_[0]->data } });
    $queue->poll;
    $queue->close;
    return $received;
}

subtest 'CPU frame export preserves rows, storage identity, and alpha modes' => sub {
    my $surface = Math::Fractal::Noisemaker::Surface->new(
        1, 2, [1, 0, 0.5, 1, 0, 0.25, 1, 1],
    );
    my $queue = Math::Fractal::Noisemaker::FrameExportQueue->new(
        Math::Fractal::Noisemaker::CpuFrameExportAdapter->new, slots => 2,
    );
    my @frames;
    $queue->configure({
        width => 1, height => 2, format => 'rgba8unorm',
        colorSpace => 'srgb', alphaMode => 'straight', fps => 60,
    });
    $queue->enqueue($surface, 42, sub { push @frames, [$_[0], ${ $_[0]->data }] });
    $surface->clear([0, 1, 0, 1]);
    $queue->poll;
    my $first_frame = $frames[0][0];
    my $first_data_ref = $first_frame->data;
    $queue->enqueue($surface, 43, sub { push @frames, [$_[0], ${ $_[0]->data }] });
    $queue->poll;

    is($frames[0][1], pack('C*', 255, 0, 128, 255, 0, 64, 255, 255), 'top-down rows copied at enqueue');
    is($frames[1][1], pack('C*', (0, 255, 0, 255) x 2), 'slot bytes refreshed on reuse');
    is(refaddr($frames[1][0]), refaddr($first_frame), 'frame object is stable across slot reuse');
    is(refaddr($frames[1][0]->data), refaddr($first_data_ref), 'data storage is stable across slot reuse');

    my $alpha = Math::Fractal::Noisemaker::Surface->new(
        1, 2, [2, 0.002, 0.5, 0.25, -1, 0.5, 1.5, 0.5],
    );
    is(export_bytes($alpha, 'straight'), pack('C*', 255, 1, 128, 64, 0, 128, 255, 128), 'straight alpha');
    is(export_bytes($alpha, 'opaque'), pack('C*', 255, 1, 128, 255, 0, 128, 255, 255), 'opaque alpha');
    is(export_bytes($alpha, 'premultiplied'), pack('C*', 128, 0, 32, 64, 0, 64, 191, 128), 'premultiplied before quantization');
};

subtest 'CPU frame export rejects extent mismatch without consuming the slot' => sub {
    my @errors;
    my $queue = Math::Fractal::Noisemaker::FrameExportQueue->new(
        Math::Fractal::Noisemaker::CpuFrameExportAdapter->new,
        slots => 2, on_error => sub { push @errors, $_[0] },
    );
    $queue->configure({
        width => 2, height => 1, format => 'rgba8unorm',
        colorSpace => 'srgb', alphaMode => 'straight', fps => 60,
    });
    ok(!$queue->enqueue(Math::Fractal::Noisemaker::Surface->new(1, 1), 0, sub { }), 'mismatch rejected');
    like($errors[0], qr/source extent 1x1 does not match configured extent 2x1/, 'extent error reported');
    is_deeply($queue->stats, { accepted => 0, dropped => 0, completed => 0, failed => 1 }, 'failure counted');
    ok($queue->available, 'slot remains reusable');
};

subtest 'CPU frame export rejects dimensions that cannot back a Surface' => sub {
    my %descriptor = (
        width => 1, height => 1, format => 'rgba8unorm',
        colorSpace => 'srgb', alphaMode => 'straight', fps => 60,
    );
    eval {
        Math::Fractal::Noisemaker::CpuFrameExportAdapter::_validate_descriptor({
            %descriptor, width => 9_007_199_254_740_992,
        });
    };
    like($@, qr/positive integer|dimensions are too large/, 'unsafe integer dimension rejected');
    eval {
        Math::Fractal::Noisemaker::CpuFrameExportAdapter::_validate_descriptor({
            %descriptor, width => 16_777_217,
        });
    };
    like($@, qr/16,777,216 pixel limit/, 'Surface pixel limit enforced before allocation');
};

subtest 'Renderer object configures sinks, submits successes, and validates before configure' => sub {
    my $renderer = Math::Fractal::Noisemaker::Renderer->new;
    my $sink = Local::Sink->new;
    $renderer->add_sink($sink);
    my $source = "search synth\nsolid(color: [0.2, 0.4, 0.6]).write(o0)\nrender(o0)";

    my $first = $renderer->render($source, width => 2, height => 1, presentation_timestamp => 100);
    my $second = $renderer->render($source, width => 2, height => 1, presentation_timestamp => 200);
    my $third = $renderer->render($source, width => 3, height => 1, presentation_timestamp => 300);
    is_deeply(
        [map { $_->[0] } @{ $sink->{events} }],
        [qw(configure submit submit configure submit)],
        'configure only changes with extent and every success submits',
    );
    is($sink->{events}[1][1], $first, 'first frame identity preserved');
    is($sink->{events}[2][1], $second, 'second frame identity preserved');
    is($sink->{events}[4][1], $third, 'third frame identity preserved');
    is_deeply($renderer->sink_manager->stats_for($sink), { accepted => 3, dropped => 0, failed => 0 }, 'renderer stats');
    my $export_queue = $renderer->create_frame_export_queue(slots => 2);
    isa_ok($export_queue, 'Math::Fractal::Noisemaker::FrameExportQueue', 'renderer creates CPU export queue');
    $export_queue->close;

    my $invalid = Math::Fractal::Noisemaker::Renderer->new;
    my $untouched = Local::Sink->new;
    $invalid->add_sink($untouched);
    for my $case (
        [width => 0, qr/width must be a positive integer/],
        [height => 0, qr/height must be a positive integer/],
        [seed => 1.5, qr/seed must be an integer/],
        [time => 'NaN', qr/time must be finite/],
    ) {
        my ($name, $value, $error) = @$case;
        eval { $invalid->render($source, $name => $value) };
        like($@, $error, "$name rejected");
    }
    is_deeply($untouched->{events}, [], 'invalid options never reach sinks');
};

subtest 'Renderer object does not submit failures and disposal is idempotent' => sub {
    my $renderer = Math::Fractal::Noisemaker::Renderer->new;
    my $sink = Local::Sink->new;
    $renderer->add_sink($sink);
    eval { $renderer->render("search filter\nread(o4).invert().write(o0)\nrender(o0)", width => 1, height => 1) };
    like($@, qr/has not been written/, 'render failure propagated');
    is_deeply([map { $_->[0] } @{ $sink->{events} }], ['configure'], 'failed render not submitted');
    $renderer->dispose;
    $renderer->dispose;
    is_deeply([map { $_->[0] } @{ $sink->{events} }], ['configure', 'close'], 'sink closed once');
    eval { $renderer->add_sink(Local::Sink->new) };
    like($@, qr/closed/, 'disposed renderer rejects sinks');
};

done_testing();
