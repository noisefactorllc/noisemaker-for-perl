use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'Math::Fractal::Noisemaker',
    AUTHOR           => 'Noise Factor LLC',
    VERSION_FROM     => 'lib/Math/Fractal/Noisemaker.pm',
    ABSTRACT_FROM    => 'lib/Math/Fractal/Noisemaker.pm',
    LICENSE          => 'mit',
    MIN_PERL_VERSION => '5.020',
    EXE_FILES        => ['bin/make-noise'],
    PREREQ_PM        => {
        # Core modules only: JSON::PP, Compress::Zlib, POSIX, HTTP::Tiny,
        # Getopt::Long, File::Spec, List::Util. No CPAN dependencies.
    },
    TEST_REQUIRES => { 'Test::More' => 0 },
    META_MERGE    => {
        'meta-spec' => { version => 2 },
        resources   => {
            repository => {
                type => 'git',
                url  => 'https://github.com/noisefactorllc/noisemaker-for-perl.git',
                web  => 'https://github.com/noisefactorllc/noisemaker-for-perl',
            },
        },
    },
    clean => { FILES => 'Math-Fractal-Noisemaker-*' },
);
