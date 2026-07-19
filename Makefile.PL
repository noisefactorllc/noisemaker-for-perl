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
