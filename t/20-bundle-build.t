use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Find qw(find);
use JSON::PP qw(encode_json decode_json);
use Math::Fractal::Noisemaker::Transpiler::Build qw(build);
use Math::Fractal::Noisemaker::KernelCache;

sub write_file {
    my ($path, $value) = @_;
    open my $fh, '>:raw', $path or die "$path: $!";
    print {$fh} $value or die $!;
    close $fh or die $!;
}

sub snapshot {
    my ($dir) = @_;
    my %files;
    find({ no_chdir => 1, wanted => sub {
        return unless -f $File::Find::name;
        open my $fh, '<:raw', $File::Find::name or die $!;
        local $/;
        $files{substr($File::Find::name, length($dir) + 1)} = <$fh>;
    }}, $dir);
    return \%files;
}

sub effect {
    return {
        namespace => 'synth', func => 'example', params => {}, textures => {},
        passes => [{ program => 'main', inputs => {}, outputs => { fragColor => 'outputTex' } }],
        programs => { main => "#version 300 es\nprecision highp float;\nout vec4 fragColor;\nvoid main() { fragColor = vec4(1.0); }\n" },
    };
}

for my $case (qw(fetch compile late_compile drift)) {
    subtest "$case failure preserves the existing bundle" => sub {
        my $dir = tempdir(CLEANUP => 1);
        make_path("$dir/kernels/perl");
        write_file("$dir/kernels/perl/synth__example__main.pl", "original kernel\n");
        write_file("$dir/bundle-lock.json", encode_json({hashes => {
            'synth/example:main' => 'old-shader-hash',
        }}));
        write_file("$dir/metadata.json", encode_json({effects => {}, provenance => {}}));
        my $before = snapshot($dir);
        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if (!$pid) {
            # Replace only the network boundary; parsing, generation and writes are real.
            no warnings 'redefine';
            local *Math::Fractal::Noisemaker::Transpiler::Build::fetch_effect = sub {
                die "fixture fetch failed\n" if $case eq 'fetch';
                my $eff = effect();
                $eff->{programs}{main} = 'invalid GLSL {' if $case eq 'compile';
                if ($case eq 'late_compile') {
                    push @{ $eff->{passes} }, { program => 'broken' };
                    $eff->{programs}{broken} = 'invalid GLSL {';
                }
                return $eff;
            };
            my $ok = eval { build(['synth/example'], out_dir => $dir); 1 };
            exit($ok ? 0 : 23);
        }
        waitpid($pid, 0);
        is($? >> 8, 23, 'failure raises an exception the caller can catch');
        is_deeply(snapshot($dir), $before, 'all existing bundle bytes remain unchanged');
    };
}

subtest 'a complete validated bundle can be published' => sub {
    my $dir = tempdir(CLEANUP => 1);
    no warnings 'redefine';
    local *Math::Fractal::Noisemaker::Transpiler::Build::fetch_effect = sub { effect() };
    build(['synth/example'], out_dir => "$dir/bundle");
    my $files = snapshot("$dir/bundle");
    my $meta = decode_json($files->{'metadata.json'});
    ok($meta->{effects}{'synth/example'}, 'published metadata contains the generated effect');
    my $kernel = Math::Fractal::Noisemaker::KernelCache::load_kernel(
        $files->{'kernels/perl/synth__example__main.pl'}, 'fixture');
    my @pixel;
    # The generated shader needs a real context, even for a constant color.
    require Math::Fractal::Noisemaker::PassRunner;
    require Math::Fractal::Noisemaker::Runtime;
    my $ctx = Math::Fractal::Noisemaker::Ctx->new(
        rt => Math::Fractal::Noisemaker::Runtime->new,
    );
    $kernel->{kernel}->($ctx, \@pixel);
    is_deeply(\@pixel, [1, 1, 1, 1], 'published kernel executes the supplied shader');

    write_file("$dir/bundle/retained.dat", 'existing caller data');
    local *Math::Fractal::Noisemaker::Transpiler::Build::fetch_effect = sub {
        my $eff = effect();
        $eff->{programs}{main} =~ s/vec4\(1\.0\)/vec4(0.5)/;
        return $eff;
    };
    build(['synth/example'], out_dir => "$dir/bundle", update_lock => 1);
    $files = snapshot("$dir/bundle");
    $kernel = Math::Fractal::Noisemaker::KernelCache::load_kernel(
        $files->{'kernels/perl/synth__example__main.pl'}, 'updated fixture');
    $kernel->{kernel}->($ctx, \@pixel);
    is_deeply(\@pixel, [0.5, 0.5, 0.5, 0.5], 'explicitly accepted drift publishes the new shader');
    is($files->{'retained.dat'}, 'existing caller data', 'publication preserves existing extra files');
};

done_testing();
