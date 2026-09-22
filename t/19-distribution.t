use strict;
use warnings;
use Test::More;
use FindBin;
use File::Find qw(find);
use ExtUtils::Manifest qw(maniread);

chdir "$FindBin::Bin/.." or die "Cannot enter distribution: $!";
my $manifest = maniread();
my @required;
find({ no_chdir => 1, wanted => sub {
    push @required, $File::Find::name if -f $File::Find::name;
}}, qw(lib t bin scripts export-kit));
push @required, qw(Makefile.PL README.md LICENSE docs/hero.jpg);

is_deeply([sort grep { !exists $manifest->{$_} } @required], [],
    'MANIFEST includes runtime, tests, tools, and their distributed resources');
is_deeply([sort grep { !-f $_ } keys %$manifest], [],
    'every MANIFEST entry exists');

done_testing();
