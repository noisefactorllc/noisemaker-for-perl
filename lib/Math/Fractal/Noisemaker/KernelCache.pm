package Math::Fractal::Noisemaker::KernelCache;

# Kernel loader + size-bounded LRU cache for runtime-compiled kernel source.
#
# The Perl analogue of the reference engine's `new Function(...)` + Map cache:
# kernel source (a file whose last expression is `{ kernel => $coderef,
# uses_derivatives => 0|1 }`) is compiled with eval and memoized, keyed by an
# opaque caller-supplied string, bounded by total source byte size.

use strict;
use warnings;

sub load_kernel {
    my ($source, $name) = @_;
    my $result = eval $source;    ## no critic — this is the codegen contract
    die "kernel source failed to compile: $@" if $@;
    die "kernel source did not yield a { kernel => ... } hashref\n"
        unless ref $result eq 'HASH' && ref $result->{kernel} eq 'CODE';
    return $result;
}

sub new {
    my ($class, %opt) = @_;
    return bless {
        max_bytes => (defined $opt{max_bytes} ? $opt{max_bytes} : 64 * 1024 * 1024),
        entries   => {},    # key -> { kernel, size }
        order     => [],    # LRU order, oldest first
        bytes     => 0,
        hits      => 0,
        misses    => 0,
    }, $class;
}

sub _touch {
    my ($self, $key) = @_;
    @{ $self->{order} } = ((grep { $_ ne $key } @{ $self->{order} }), $key);
}

sub get {
    my ($self, $key, $source_factory) = @_;
    if (my $entry = $self->{entries}{$key}) {
        $self->{hits}++;
        $self->_touch($key);
        return $entry->{kernel};
    }
    $self->{misses}++;
    my $source = $source_factory->();
    my $kernel = load_kernel($source);
    $self->{entries}{$key} = { kernel => $kernel, size => length $source };
    $self->{bytes} += length $source;
    push @{ $self->{order} }, $key;
    $self->_evict;
    return $kernel;
}

sub _evict {
    my ($self) = @_;
    while ($self->{bytes} > $self->{max_bytes} && @{ $self->{order} } > 1) {
        my $key     = shift @{ $self->{order} };
        my $evicted = delete $self->{entries}{$key};
        $self->{bytes} -= $evicted->{size};
    }
}

sub stats {
    my ($self) = @_;
    return {
        entries => scalar keys %{ $self->{entries} },
        bytes   => $self->{bytes},
        hits    => $self->{hits},
        misses  => $self->{misses},
    };
}

sub clear {
    my ($self) = @_;
    $self->{entries} = {};
    $self->{order}   = [];
    $self->{bytes}   = 0;
}

1;
