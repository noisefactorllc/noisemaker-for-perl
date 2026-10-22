package ParityOracle;

use strict;
use warnings;
use Exporter 'import';
use File::Basename qw(dirname);
use File::Find qw(find);
use File::Spec;

use Digest::SHA;
use JSON::PP qw(decode_json);

our @EXPORT_OK = qw(verify_oracle resolve_oracle particle_program);

sub read_file {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "Cannot read reference file $path: $!\n";
    local $/;
    return scalar <$fh>;
}

# The revision tells maintainers what to check out. Hashing the actual runtime
# also detects a dirty checkout or an archive that does not match that revision.
sub verify_oracle {
    my ($root, $pin_path) = @_;
    $pin_path ||= File::Spec->catfile(dirname(__FILE__), 'oracle-lock.json');
    my $pin = decode_json(read_file($pin_path));
    my @files;
    for my $dir (qw(bin src)) {
        my $path = File::Spec->catdir($root, $dir);
        die "Reference directory is missing: $path\n" unless -d $path;
        find({no_chdir => 1, wanted => sub {
            die "Reference must not contain symlinks: $File::Find::name\n" if -l $File::Find::name;
            return unless -f $File::Find::name;
            my $relative = File::Spec->abs2rel($File::Find::name, $root);
            $relative =~ s{\\}{/}g;
            push @files, $relative;
        }}, $path);
    }
    push @files, 'package.json', 'scripts/upstream/source-lock.js';
    my $sha = Digest::SHA->new(256);
    for my $relative (sort @files) {
        my $bytes = read_file(File::Spec->catfile($root, split m{/}, $relative));
        $sha->add($relative, "\0", length($bytes), "\0", $bytes);
    }
    die "Reference runtime differs from oracle-lock.json; check out $pin->{revision} in $root\n"
        unless $sha->hexdigest eq $pin->{runtime_sha256};
    return $pin;
}

# Where the pinned noisemaker-for-cpu oracle lives. NOISEMAKER_CPU_DIR wins
# and must verify: an explicitly configured oracle that does not match the
# recorded digest is a hard error, matching the published harness contract.
# A sibling checkout comes next; otherwise the cache root must already hold
# the exact pin revision, verified against the recorded runtime digest.
# Tests never touch the network: the pinned runtime is installed by the
# environment's provisioning step, and a cache that does not hold it is
# reported. Dies when no source can be verified.
sub resolve_oracle {
    my ($pin_path) = @_;
    if (defined(my $dir = $ENV{NOISEMAKER_CPU_DIR})) {
        verify_oracle($dir, $pin_path);
        return $dir;
    }
    my $sibling = File::Spec->rel2abs(
        File::Spec->catdir(dirname(__FILE__), '..', '..', 'noisemaker-for-cpu'));
    if (-e File::Spec->catfile($sibling, 'package.json')) {
        return $sibling if eval { verify_oracle($sibling, $pin_path); 1 };
        warn "noisemaker-for-cpu sibling $sibling does not match oracle-lock.json: $@";
    }
    return provision_oracle($pin_path);
}

# Locate the pinned runtime in the cache root and verify it against the
# recorded runtime digest. The cache lives outside this repository; a pin bump
# expects a fresh revision installed by the environment's provisioning step.
sub provision_oracle {
    my ($pin_path) = @_;
    $pin_path ||= File::Spec->catfile(dirname(__FILE__), 'oracle-lock.json');
    my $pin = decode_json(read_file($pin_path));
    my $rev = $pin->{revision}
        or die "oracle-lock.json records no revision to provision\n";

    my ($cache_root) = grep {
        defined && -d && -w
    } ($ENV{NOISEMAKER_ORACLE_CACHE},
       File::Spec->rel2abs(File::Spec->catdir($ENV{HOME} || File::Spec->curdir, '.cache')));
    $cache_root or die "no writable cache root is configured; set NOISEMAKER_ORACLE_CACHE\n";
    my $base = File::Spec->catdir($cache_root, 'noisemaker-for-cpu-pin');
    my $target = File::Spec->catdir($base, $rev);
    # Tests never fetch from the network. The pinned runtime is installed by
    # the environment's provisioning step into the cache root before the
    # suite runs; a bare container without it has no oracle and the callers
    # gate on that instead of downloading at test time.
    return $target if eval { verify_oracle($target, $pin_path); 1 };
    die "pinned noisemaker-for-cpu $rev is not provisioned in the cache root; "
        . "install it before running the suite (runtime_sha256 "
        . "$pin->{runtime_sha256})\n";
}

# Both engines receive this exact scene. The reference `effect` CLI inserts an
# emitter for particle consumers; comparing it to a bare Perl effect would
# compare different inputs and different iteration counts. Returns undef when
# the effect reads no particle state before writing it.
sub particle_program {
    my ($effect, $params) = @_;
    my %written;
    my $needs_emitter = 0;
    for my $pass (@{ $effect->{passes} || [] }) {
        for my $name (values %{ $pass->{inputs} || {} }) {
            $needs_emitter = 1
                if $name =~ /\Aglobal_(?:xyz|vel|rgba|points_trail)\z/ && !$written{$name};
        }
        last if $needs_emitter;
        $written{$_} = 1 for values %{ $pass->{outputs} || {} };
    }
    return undef unless $needs_emitter;
    my $args = join ', ', map { "$_: $params->{$_}" } sort keys %$params;
    return "search points, render, synth\n"
        . "solid().pointsEmit(stateSize: x64, iterationCount: 1).$effect->{func}($args).write(o0)\nrender(o0)";
}

1;
