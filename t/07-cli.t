use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Config;
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP;

use Math::Fractal::Noisemaker::PNG qw(decode_png);
use Math::Fractal::Noisemaker::Renderer;

# Exercises bin/make-noise as a subprocess (never in-process), the same way
# an end user invokes it. All subprocess IO is redirected to temp files --
# shell-free -- so args like "color=#f30" need no quoting/escaping.

my $DIST_ROOT  = File::Spec->rel2abs(File::Spec->catdir($FindBin::Bin, '..'));
my $MAKE_NOISE = File::Spec->catfile($DIST_ROOT, 'bin', 'make-noise');
my $PERL       = $Config{perlpath};

$| = 1;

# Windows has no executable bit; a script there runs through perl.
ok(-f $MAKE_NOISE && ($^O eq 'MSWin32' || -x _), 'bin/make-noise exists and is executable');

# Run perl on a probe script with arguments; returns its standard output. The
# probe goes through a file, and the output too: Windows has neither list-form
# piped opens nor reliable quoting of a multi-line -e program.
sub run_perl_probe {
    my ($code, @args) = @_;
    require File::Temp;
    my $dir = File::Temp::tempdir(CLEANUP => 1);
    my ($probe, $out) = map { File::Spec->catfile($dir, $_) } qw(probe.pl probe.out);
    open my $pfh, '>', $probe or die "cannot write $probe: $!";
    print {$pfh} $code;
    close $pfh;
    open my $saved, '>&', \*STDOUT or die "cannot save STDOUT: $!";
    open STDOUT, '>', $out or die "cannot redirect STDOUT: $!";
    system($^X, $probe, @args);
    open STDOUT, '>&', $saved or die "cannot restore STDOUT: $!";
    open my $ofh, '<', $out or die "cannot read $out: $!";
    return do { local $/; <$ofh> };
}

# Run bin/make-noise as a subprocess. Returns (exit_code, stdout, stderr).
# %opts: stdin => STRING, env => { VAR => VALUE_OR_UNDEF (undef deletes) }.
sub run_cli {
    my ($args, %opts) = @_;

    my (undef, $out_path) = File::Temp::tempfile(UNLINK => 1);
    my (undef, $err_path) = File::Temp::tempfile(UNLINK => 1);
    my $in_path = File::Spec->devnull;
    if (defined $opts{stdin}) {
        my ($sfh, $spath) = File::Temp::tempfile(UNLINK => 1);
        print {$sfh} $opts{stdin};
        close $sfh;
        $in_path = $spath;
    }

    local %ENV = %ENV;
    if ($opts{env}) {
        for my $k (keys %{ $opts{env} }) {
            my $v = $opts{env}{$k};
            if (defined $v) { $ENV{$k} = $v }
            else            { delete $ENV{$k} }
        }
    }

    open(my $saved_out, '>&', \*STDOUT) or die "cannot save STDOUT: $!\n";
    open(my $saved_err, '>&', \*STDERR) or die "cannot save STDERR: $!\n";
    open(my $saved_in,  '<&', \*STDIN)  or die "cannot save STDIN: $!\n";
    open(STDOUT, '>', $out_path) or die "cannot redirect STDOUT: $!\n";
    open(STDERR, '>', $err_path) or die "cannot redirect STDERR: $!\n";
    open(STDIN,  '<', $in_path)  or die "cannot redirect STDIN: $!\n";

    my $raw = system($PERL, $MAKE_NOISE, @$args);

    open(STDOUT, '>&', $saved_out) or die "cannot restore STDOUT: $!\n";
    open(STDERR, '>&', $saved_err) or die "cannot restore STDERR: $!\n";
    open(STDIN,  '<&', $saved_in)  or die "cannot restore STDIN: $!\n";
    close $saved_out;
    close $saved_err;
    close $saved_in;

    my $exit_code = $raw == -1 ? -1 : ($raw >> 8);
    return ($exit_code, _slurp_text($out_path), _slurp_text($err_path));
}

sub _slurp_text {
    my ($path) = @_;
    open my $fh, '<', $path or return '';
    local $/;
    my $data = <$fh>;
    close $fh;
    return defined $data ? $data : '';
}

sub _slurp_bytes {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read $path: $!\n";
    local $/;
    my $data = <$fh>;
    close $fh;
    return $data;
}

my $TMPDIR = tempdir(CLEANUP => 1);

# --- --help / --version --------------------------------------------------

{
    my ($rc, $out, $err) = run_cli(['--help']);
    is($rc, 0, '--help exits 0');
    like($out, qr/\bgenerate\b/, '--help mentions generate');
    like($out, qr/\bapply\b/,    '--help mentions apply');
    like($out, qr/\banimate\b/,  '--help mentions animate');
    like($out, qr/\brun\b/,      '--help mentions run');
}

{
    my ($rc, $out, $err) = run_cli([]);
    is($rc, 0, 'no args exits 0');
    like($out, qr/\bgenerate\b/, 'no-args usage mentions generate');
}

{
    my ($rc, $out, $err) = run_cli(['--version']);
    is($rc, 0, '--version exits 0');
    like($out, qr/make-noise \(Math::Fractal::Noisemaker\) 1\.000/, '--version prints expected string');
}

# --- generate --------------------------------------------------------------

my $solid_png = File::Spec->catfile($TMPDIR, 'solid.png');
{
    my ($rc, $out, $err) = run_cli([
        'generate', 'synth/solid',
        '--width', 4, '--height', 4,
        '--param', 'color=#f30',
        '--filename', $solid_png,
    ]);
    is($rc, 0, 'generate synth/solid exits 0') or diag("stdout=[$out] stderr=[$err]");
    like($err, qr/Rendering 4x4 synth\/solid/, 'render progress goes to standard error');
    like($out, qr{^synth/solid$}m, 'generate echoes the resolved effect id first');
    like($out, qr{Rendered 4x4 -> \Q$solid_png\E}, 'generate echoes the Rendered message');
    ok(-f $solid_png, 'generate wrote the output file');

    my $surface = decode_png(_slurp_bytes($solid_png));
    is($surface->width,  4, 'decoded width matches --width');
    is($surface->height, 4, 'decoded height matches --height');
    my @px = unpack('C*', $surface->to_rgba8);
    is_deeply([ @px[ 0 .. 3 ] ], [ 255, 51, 0, 255 ], 'first pixel is #f30 opaque');
}

{
    my $nested = File::Spec->catfile($TMPDIR, 'a', 'b', 'out.png');
    ok(!-d File::Spec->catdir($TMPDIR, 'a'), 'parent dir does not exist yet');
    my ($rc, $out, $err) = run_cli([
        'generate', 'synth/solid',
        '--width', 4, '--height', 4,
        '--filename', $nested,
    ]);
    is($rc, 0, 'generate into missing parent dirs exits 0') or diag("stdout=[$out] stderr=[$err]");
    ok(-f $nested, 'generate created missing parent dirs and wrote the file');
}

# --- apply -------------------------------------------------------------

{
    my $inverted_png = File::Spec->catfile($TMPDIR, 'inverted.png');
    my ($rc, $out, $err) = run_cli([
        'apply', 'filter/invert', $solid_png,
        '--filename', $inverted_png,
    ]);
    is($rc, 0, 'apply filter/invert exits 0') or diag("stdout=[$out] stderr=[$err]");
    like($out, qr{^filter/invert$}m, 'apply echoes the resolved effect id first');
    like($out, qr{Rendered 4x4 -> \Q$inverted_png\E}, 'apply echoes the Rendered message');

    my $surface = decode_png(_slurp_bytes($inverted_png));
    is($surface->width,  4, 'apply preserves the input width');
    is($surface->height, 4, 'apply preserves the input height');
    my @px = unpack('C*', $surface->to_rgba8);
    is_deeply([ @px[ 0 .. 2 ] ], [ 0, 204, 255 ], 'first pixel rgb is inverted');
    is($px[3], 255, 'first pixel stays opaque');
}

# --- error paths -----------------------------------------------------------

{
    my $filename = File::Spec->catfile($TMPDIR, 'volume.png');
    my ($rc, $out, $err) = run_cli([
        'generate', 'synth3d/noise3d',
        '--width', 2, '--height', 2,
        '--param', 'volumeSize=2',
        '--filename', $filename,
    ]);
    is($rc, 0, 'generate auto-wires a volume generator into render3d')
        or diag("stdout=[$out] stderr=[$err]");
    my $surface = decode_png(_slurp_bytes($filename));
    is_deeply([$surface->width, $surface->height], [2, 2],
        'volume generator CLI output uses the requested image dimensions');
}

{
    my $filename = File::Spec->catfile($TMPDIR, 'typed-apply.png');
    my ($rc, $out, $err) = run_cli([
        'apply', 'filter3d/palette3d', $solid_png,
        '--filename', $filename,
    ]);
    isnt($rc, 0, 'apply rejects volume-domain effects');
    like($err, qr/apply only supports image-domain effects/,
        'apply explains that typed effects need a typed chain');
    ok(!-f $filename, 'rejected typed apply writes no output');
}

{
    my $filename = File::Spec->catfile($TMPDIR, 'unknown-effect.png');
    my ($rc, $out, $err) = run_cli([
        'generate', 'bogus/nope',
        '--width', 4, '--height', 4,
        '--filename', $filename,
    ]);
    isnt($rc, 0, 'unknown effect exits nonzero');
    like($err, qr/Unknown effect/, 'unknown effect message mentions "Unknown effect"');
    ok(!-f $filename, 'unknown effect did not write an output file');
}

{
    my $filename = File::Spec->catfile($TMPDIR, 'badparam.png');
    my ($rc, $out, $err) = run_cli([
        'generate', 'synth/solid',
        '--width', 4, '--height', 4,
        '--param', 'badparam',
        '--filename', $filename,
    ]);
    isnt($rc, 0, '--param without = exits nonzero');
    ok(!-f $filename, '--param without = did not write an output file');
}

# --- random is partitioned by kind -----------------------------------------

{
    my $filename = File::Spec->catfile($TMPDIR, 'random.png');
    my ($rc, $out, $err) = run_cli([
        'generate', 'random',
        '--width', 4, '--height', 4,
        '--filename', $filename,
    ]);
    is($rc, 0, 'generate random exits 0') or diag("stdout=[$out] stderr=[$err]");

    my @lines = split /\n/, $out;
    my $echoed_id = $lines[0];
    ok(defined $echoed_id && length $echoed_id, 'random generate echoed an effect id')
        or diag("stdout=[$out]");

    my $metadata_path = File::Spec->catfile(
        $DIST_ROOT, qw(lib Math Fractal Noisemaker bundle metadata.json)
    );
    open my $mfh, '<:raw', $metadata_path or die "cannot read $metadata_path: $!\n";
    local $/;
    my $meta = JSON::PP->new->utf8->decode(scalar <$mfh>);
    close $mfh;

    ok(exists $meta->{effects}{$echoed_id}, "echoed id '$echoed_id' is a known catalog effect");
    is($meta->{effects}{$echoed_id}{kind}, 'generator',
        "random generate picked an effect of kind 'generator' ('$echoed_id')");
    ok(!$meta->{effects}{$echoed_id}{iterated},
        "random generate excluded stateful effects ('$echoed_id')");
    ok(!$meta->{effects}{$echoed_id}{externalTexture},
        "random generate excluded effects requiring an external texture ('$echoed_id')");
    is($meta->{effects}{$echoed_id}{domain} || 'image', 'image',
        "random generate excluded non-image effects ('$echoed_id')");
}

# --- animate: ffmpeg absent -------------------------------------------------

{
    my $frames_dir = File::Spec->catdir($TMPDIR, 'frames');
    my ($rc, $out, $err) = run_cli(
        [
            'animate', 'synth/solid',
            '--width', 4, '--height', 4,
            '--frame-count', 2,
            '--save-frames', $frames_dir,
        ],
        env => { PATH => '' },
    );
    is($rc, 0, 'animate with --save-frames exits 0 even without ffmpeg')
        or diag("stdout=[$out] stderr=[$err]");
    like($out, qr/ffmpeg not found/, 'animate message mentions ffmpeg not found');
    ok(-f File::Spec->catfile($frames_dir, 'frame_0000.png'), 'frame 0 was written');
    ok(-f File::Spec->catfile($frames_dir, 'frame_0001.png'), 'frame 1 was written');
}

{
    my $filename = File::Spec->catfile($TMPDIR, 'no-ffmpeg.mp4');
    my ($rc, $out, $err) = run_cli(
        [
            'animate', 'synth/solid',
            '--width', 4, '--height', 4,
            '--frame-count', 2,
            '--filename', $filename,
        ],
        env => { PATH => '' },
    );
    isnt($rc, 0, 'animate without --save-frames and no ffmpeg exits nonzero');
    like($err, qr/ffmpeg not found/, 'animate error message mentions ffmpeg not found');
}

# --- run: DSL renderer (guarded -- render_dsl may not exist yet) -----------

SKIP: {
    my $available = eval { Math::Fractal::Noisemaker::Renderer->can('render_dsl') };
    skip 'Math::Fractal::Noisemaker::Renderer::render_dsl not implemented yet', 2 unless $available;

    # Same program as noisemaker-python test_run_reads_dsl_from_stdin: the
    # run subcommand reads the DSL source from stdin (no default program).
    my $filename = File::Spec->catfile($TMPDIR, 'run.png');
    my ($rc, $out, $err) = run_cli(
        [ 'run', '--width', 4, '--height', 4, '--filename', $filename ],
        stdin => "search synth\nsolid(color: #336699).write(o0)\nrender(o0)\n",
    );
    is($rc, 0, 'run exits 0') or diag("stdout=[$out] stderr=[$err]");
    ok(-f $filename, 'run wrote an output file');
}

# --- run with --input / --texture, and DSL error surfacing ---
{
    my $dir = File::Temp->newdir;
    my $tex = File::Spec->catfile($dir, 'tex.png');
    my ($rc0) = run_cli(['generate', 'synth/solid', '--width', '4', '--height', '4',
                         '--param', 'color=#4080c0', '--filename', $tex]);
    is($rc0, 0, 'texture source renders');

    # media samples imageTex — bound via --input
    my $out = File::Spec->catfile($dir, 'media.png');
    my ($rc1, $so1, $se1) = run_cli(
        ['run', '--width', '4', '--height', '4', '--input', $tex, '--filename', $out],
        stdin => "search synth\nmedia(imageSize: [4, 4]).write(o0)\nrender(o0)\n");
    is($rc1, 0, "run --input binds imageTex: $se1");
    ok(-s $out, 'run --input wrote a png');

    # --texture NAME=FILE named binding
    my $out2 = File::Spec->catfile($dir, 'media2.png');
    my ($rc2, $so2, $se2) = run_cli(
        ['run', '--width', '4', '--height', '4', '--texture', "imageTex=$tex",
         '--texture', "textTex=$tex", '--filename', $out2],
        stdin => "search synth\nmedia(imageSize: [4, 4]).write(o0)\nrender(o0)\n");
    is($rc2, 0, "run --texture binds named samplers: $se2");

    # a DSL compile error surfaces cleanly with a nonzero exit
    my ($rc3, $so3, $se3) = run_cli(
        ['run', '--width', '4', '--height', '4'],
        stdin => "solid().write(o0)\nrender(o0)\n");
    isnt($rc3, 0, 'DSL error (missing search) exits nonzero');
    like($se3, qr/Missing required search directive/, 'DSL error message surfaces');
}

for my $param ('seeed=3', 'type=not_a_noise_type', 'scaleX=banana') {
    my $filename = File::Spec->catfile($TMPDIR, 'invalid-param.png');
    my ($rc, $out, $err) = run_cli([
        'generate', 'synth/noise', '--width', 2, '--height', 2,
        '--param', $param, '--filename', $filename,
    ]);
    is($rc, 2, "$param exits with a usage error");
    like($err, qr/(?:Unknown|Invalid) parameter.*synth\/noise/, 'diagnostic names the effect and parameter');
    ok(!-e $filename, 'invalid parameters do not write an image');
}

# An explicit --seed outside the effect's declared range is a usage error.
for my $seed (1001, 5000) {
    my $filename = File::Spec->catfile($TMPDIR, 'seed-range.png');
    my ($rc, $out, $err) = run_cli([
        'generate', 'synth/curl', '--width', 8, '--height', 8, '--seed', $seed, '--filename', $filename,
    ]);
    is($rc, 2, "--seed $seed exits with a usage error");
    like($err, qr/'seed' for synth\/curl: must be at most 1000 \(declared range 0 to 1000\)/,
        'the diagnostic names the declared seed range');
    ok(!-e $filename, 'an out-of-range seed writes no image');
}

# An unseeded run draws inside the effect's declared seed range: with rand at
# both ends of its range, the draw lands on the declared bounds.
{
    my $probe = <<'PERL';
my $edge;
BEGIN {
    *CORE::GLOBAL::exit = sub { die "exit\n" };
    *CORE::GLOBAL::rand = sub { my $n = @_ ? $_[0] : 1; return $edge eq 'high' ? $n * (1 - 2**-40) : 0 };
}
my $script = shift;
{
    local @ARGV = ('--version');
    open my $null, '>', File::Spec->devnull;
    my $out = select $null;
    eval { do $script };
    select $out;
}
for my $effect (@ARGV) {
    for ('low', 'high') { $edge = $_; print "$effect $edge ", main::_draw_seed($effect), "\n" }
}
PERL
    my $lib = File::Spec->catdir($DIST_ROOT, 'lib');
    my %drawn = map { /^(\S+ \S+) (\d+)$/ ? ($1 => $2) : () }
        split /\n/, run_perl_probe("use lib '$lib';\nuse File::Spec;\n$probe", $MAKE_NOISE, 'synth/curl', 'synth/noise');
    is_deeply(\%drawn, {
        'synth/curl low' => 0, 'synth/curl high' => 1000,
        'synth/noise low' => 1, 'synth/noise high' => 100,
    }, 'unseeded draws stay inside each effect\'s declared seed range');
}

# --- installed (INSTALL_BASE) layout --------------------------------------
# An INSTALL_BASE install places modules under <prefix>/lib/perl5 while the
# script stays at <prefix>/bin/make-noise; the script must find them there
# with no PERL5LIB and no checkout around it.
{
    require File::Path;
    require File::Copy;
    require File::Find;
    my $prefix = File::Spec->catdir($TMPDIR, 'prefix');
    my $bin    = File::Spec->catdir($prefix, 'bin');
    my $lib5   = File::Spec->catdir($prefix, 'lib', 'perl5');
    File::Path::make_path($bin, $lib5);

    # Copy the checkout lib/ tree into <prefix>/lib/perl5/ with core modules
    # only (File::Find + File::Copy), mirroring an INSTALL_BASE install.
    require File::Basename;
    my $lib_src = File::Spec->catdir($DIST_ROOT, 'lib');
    File::Find::find(
        {
            wanted => sub {
                return unless -f $_;
                # abs2rel, not a prefix strip: File::Find reports `/`
                # separators on Windows while catdir builds `\` ones.
                my $rel = File::Spec->abs2rel($File::Find::name, $lib_src);
                my $dest = File::Spec->catfile($lib5, $rel);
                File::Path::make_path(File::Basename::dirname($dest));
                File::Copy::copy($File::Find::name, $dest)
                    or die "cannot stage $File::Find::name: $!";
            },
            no_chdir => 1,
        },
        $lib_src
    );
    my $installed = File::Spec->catfile($bin, 'make-noise');
    File::Copy::copy($MAKE_NOISE, $installed) or die "cannot stage bin: $!";

    my (undef, $out_path) = File::Temp::tempfile(UNLINK => 1);
    my (undef, $err_path) = File::Temp::tempfile(UNLINK => 1);
    open(my $saved_out, '>&', \*STDOUT) or die "cannot save STDOUT: $!\n";
    open(my $saved_err, '>&', \*STDERR) or die "cannot save STDERR: $!\n";
    open(STDOUT, '>', $out_path) or die "cannot redirect STDOUT: $!\n";
    open(STDERR, '>', $err_path) or die "cannot redirect STDERR: $!\n";
    my $rc = do {
        local %ENV = %ENV;
        delete $ENV{PERL5LIB};
        my $raw = system($PERL, $installed, '--version');
        $raw == -1 ? -1 : ($raw >> 8);
    };
    open(STDOUT, '>&', $saved_out) or die "cannot restore STDOUT: $!\n";
    open(STDERR, '>&', $saved_err) or die "cannot restore STDERR: $!\n";
    close $saved_out; close $saved_err;
    open my $ofh, '<', $out_path; my $out = do { local $/; <$ofh> } // '';
    open my $efh, '<', $err_path; my $err = do { local $/; <$efh> } // '';
    close $ofh; close $efh;
    is($rc, 0, 'installed-layout make-noise --version exits 0') or diag("stderr=[$err]");
    like($out, qr/make-noise \(Math::Fractal::Noisemaker\) 1\.000/,
        'installed-layout script locates modules under <prefix>/lib/perl5');
    unlike($err, qr/Can't locate Math\/Fractal\/Noisemaker\.pm/, 'no module-load failure');
}

done_testing();
