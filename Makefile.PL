use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'Math::Fractal::Noisemaker',
    AUTHOR           => 'Noise Factor LLC',
    VERSION_FROM     => 'lib/Math/Fractal/Noisemaker.pm',
    ABSTRACT_FROM    => 'lib/Math/Fractal/Noisemaker.pm',
    LICENSE          => 'mit',
    # 5.22 floor: the runtime uses POSIX::log2/atan/trunc (C99 math batch,
    # added to POSIX in 5.22) for exact libm parity with the reference engine.
    MIN_PERL_VERSION => '5.022',
    EXE_FILES        => ['bin/make-noise'],
    PREREQ_PM        => {
        # Declare core dependencies too: some Perl installations split them
        # into OS packages, and CPAN clients need the complete dependency list.
        map { $_ => 0 } qw(
            Compress::Zlib Compress::Raw::Zlib Digest::SHA Exporter
            File::Basename File::Copy File::Find File::Path File::Spec File::Temp
            FindBin Getopt::Long HTTP::Tiny JSON::PP List::Util POSIX Scalar::Util Time::HiRes
        ),
    },
    CONFIGURE_REQUIRES => { 'ExtUtils::MakeMaker' => '6.64' },
    TEST_REQUIRES => { 'Test::More' => 0 },
    META_MERGE    => {
        'meta-spec' => { version => 2 },
        resources   => {
            bugtracker => { web => 'https://github.com/noisefactorllc/noisemaker-for-perl/issues' },
            repository => {
                type => 'git',
                url  => 'https://github.com/noisefactorllc/noisemaker-for-perl.git',
                web  => 'https://github.com/noisefactorllc/noisemaker-for-perl',
            },
        },
    },
    clean => { FILES => 'Math-Fractal-Noisemaker-*' },
);
