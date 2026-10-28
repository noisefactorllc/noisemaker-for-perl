use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../scripts";
# Exercises scripts/ParityOracle.pm: golden digest verification of the
# pinned reference and the bounded resolution contract used by the parity
# harness.
use ParityOracle qw(verify_oracle resolve_oracle);
use File::Spec;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use JSON::PP qw(encode_json);

my $root = tempdir(CLEANUP => 1);
sub write_file {
    my ($name, $bytes, $base) = @_;
    $base ||= $root;
    my $path = "$base/$name";
    make_path(dirname($path));
    open my $fh, '>:raw', $path or die $!;
    print {$fh} $bytes or die $!;
    close $fh or die $!;
}
write_file('bin/noisemaker-cpu.js', "// reference\n");
write_file('src/runtime.js', "// runtime\n");
write_file('package.json', "{}\n");
write_file('scripts/upstream/source-lock.js', "// upstream\n");
# Independent fixture digest calculated with Python hashlib over the four
# literal files above: sorted path, NUL, byte length, NUL, then file bytes.
write_file('pin.json', encode_json({
    revision => 'fixture',
    runtime_sha256 => 'f2f7d6a3196fae509079fcbaae882afabfe799032b1bc97cf3f902cb17e84cb3',
}));
is(verify_oracle($root, "$root/pin.json")->{revision}, 'fixture', 'unchanged reference is accepted');

write_file('src/runtime.js', "// modified runtime\n");
eval { verify_oracle($root, "$root/pin.json") };
like($@, qr/Reference runtime differs/, 'uncommitted runtime edits are rejected');
write_file('src/runtime.js', "// runtime\n");
write_file('src/extra.js', "// unexpected runtime\n");
eval { verify_oracle($root, "$root/pin.json") };
like($@, qr/Reference runtime differs/, 'additional runtime files are rejected');
unlink "$root/src/extra.js" or die $!;
unlink "$root/package.json" or die $!;
eval { verify_oracle($root, "$root/pin.json") };
like($@, qr/Cannot read reference file.*package.json/, 'incomplete reference is rejected');

# resolve_oracle must never fetch at test time. An explicitly configured
# NOISEMAKER_CPU_DIR is a hard requirement: it must verify against the
# recorded digest. Resolution falls through to a sibling checkout and then
# to the cache root, and dies there when the pinned revision is not
# provisioned.
{
    local $ENV{NOISEMAKER_CPU_DIR} = "$root/does-not-exist";
    eval { resolve_oracle() };
    like($@, qr/Reference directory is missing/,
        'an explicitly configured NOISEMAKER_CPU_DIR that does not verify is a hard error');
}

my $sibling = File::Spec->rel2abs(
    File::Spec->catdir($FindBin::Bin, '..', '..', 'noisemaker-for-cpu'));
my $sibling_ok = -e File::Spec->catfile($sibling, 'package.json')
    && eval { verify_oracle($sibling); 1 };

SKIP: {
    skip 'a verified sibling oracle already resolves the pin', 3 if $sibling_ok;
    {
        local $ENV{NOISEMAKER_CPU_DIR};
        local $ENV{NOISEMAKER_ORACLE_CACHE} = tempdir(CLEANUP => 1);
        eval { resolve_oracle() };
        like($@, qr/is not provisioned in the cache root/,
            'without a verified oracle an empty cache root is not provisioned');
    }
    {
        local $ENV{NOISEMAKER_CPU_DIR};
        local $ENV{HOME} = tempdir(CLEANUP => 1);
        delete local $ENV{NOISEMAKER_ORACLE_CACHE};
        eval { resolve_oracle() };
        like($@, qr/no writable cache root is configured/,
            'resolution dies when no writable cache root is configured');
    }
    {
        # A cache entry that is not the pinned revision is not a provisioned
        # oracle either; resolution must reject it instead of trusting it.
        local $ENV{NOISEMAKER_CPU_DIR};
        my $cache = tempdir(CLEANUP => 1);
        make_path("$cache/noisemaker-for-cpu-pin/not-the-pinned-revision");
        local $ENV{NOISEMAKER_ORACLE_CACHE} = $cache;
        eval { resolve_oracle() };
        like($@, qr/is not provisioned in the cache root/,
            'a cache entry that does not match the pin is not provisioned');
    }
}

# The resolution success paths: a verified NOISEMAKER_CPU_DIR wins, and a
# cache root that already holds the exact pinned revision resolves without
# any network access.
write_file('package.json', "{}\n");
{
    local $ENV{NOISEMAKER_CPU_DIR} = $root;
    is(resolve_oracle("$root/pin.json"), $root,
        'a verified NOISEMAKER_CPU_DIR resolves directly');
}
{
    my $cache = tempdir(CLEANUP => 1);
    # Build the expected directory the same way provision_oracle builds it,
    # with File::Spec->catdir: on Windows the resolved path is normalized to
    # backslashes, so a string-built expectation with forward slashes would
    # not compare equal even when resolution is correct.
    my $pin_dir = File::Spec->catdir($cache, 'noisemaker-for-cpu-pin', 'fixture');
    write_file('bin/noisemaker-cpu.js', "// reference\n", $pin_dir);
    write_file('src/runtime.js', "// runtime\n", $pin_dir);
    write_file('package.json', "{}\n", $pin_dir);
    write_file('scripts/upstream/source-lock.js', "// upstream\n", $pin_dir);
    write_file('pin.json', encode_json({
        revision => 'fixture',
        runtime_sha256 => 'f2f7d6a3196fae509079fcbaae882afabfe799032b1bc97cf3f902cb17e84cb3',
    }), $pin_dir);
    local $ENV{NOISEMAKER_CPU_DIR};
    local $ENV{NOISEMAKER_ORACLE_CACHE} = $cache;
    is(resolve_oracle("$pin_dir/pin.json"), $pin_dir,
        'a cache root holding the pinned revision resolves without network access');
}

done_testing();
