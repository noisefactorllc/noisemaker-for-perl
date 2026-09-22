package ParityOracle;

use strict;
use warnings;
use Exporter 'import';
use File::Basename qw(dirname);
use File::Find qw(find);
use File::Spec;
use Digest::SHA;
use JSON::PP qw(decode_json);

our @EXPORT_OK = qw(verify_oracle);

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

1;
