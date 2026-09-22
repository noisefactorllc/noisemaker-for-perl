use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../scripts";
use ParityOracle qw(verify_oracle);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use JSON::PP qw(encode_json);

my $root = tempdir(CLEANUP => 1);
sub write_file {
    my ($name, $bytes) = @_;
    my $path = "$root/$name";
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

done_testing();
