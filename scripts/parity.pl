#!/usr/bin/env perl

# Cross-language parity harness: render every bundled effect in Perl vs the JS
# oracle (noisemaker-cpu `effect` CLI) at parity settings, and categorize.
# Iterated effects run one iteration (stateSize 64 where declared); particle
# consumers run behind the same emitter on both sides; volume and loop effects
# run inside the same DSL program on both sides. The five reactive/mesh effects
# run their authority DSL program with the deterministic MIDI, audio and mesh
# fixtures bound (scripts/ReactiveFixtures.pm), which the oracle's `effect` CLI
# cannot bind, so the oracle side renders them through
# scripts/oracle-external-input.mjs.
#
# Usage: perl scripts/parity.pl [--only id,id] [--size N] [--volume-size N]

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib $FindBin::Bin;
use ParityOracle qw(verify_oracle particle_program);
use ReactiveFixtures qw(%EXTERNAL_INPUT_SOURCES external_inputs_for);
use Cwd ();
use File::Spec;
use File::Temp ();

use Math::Fractal::Noisemaker::PNG qw(encode_png decode_png);
use Math::Fractal::Noisemaker::Renderer qw(render_effect render_dsl meta);
use Math::Fractal::Noisemaker::Surface;

my $CPU_DIR = $ENV{NOISEMAKER_CPU_DIR}
    || File::Spec->rel2abs(File::Spec->catdir($FindBin::Bin, '..', '..', 'noisemaker-for-cpu'));
my $CLI = File::Spec->catfile($CPU_DIR, 'bin', 'noisemaker-cpu.js');
my $oracle_pin = verify_oracle($CPU_DIR);
print "Reference: $oracle_pin->{revision} (runtime SHA-256 verified)\n";

my $SIZE = 8;
my $SEED = 1;
my $TIME = 0.25;
my $VOLUME_SIZE = 16;
my $only;
for (my $i = 0; $i <= $#ARGV; $i++) {
    if    ($ARGV[$i] eq '--only')        { $only = { map { $_ => 1 } split /,/, $ARGV[++$i] } }
    elsif ($ARGV[$i] eq '--size')        { $SIZE = $ARGV[++$i] }
    elsif ($ARGV[$i] eq '--volume-size') { $VOLUME_SIZE = $ARGV[++$i] }
    else  { die "Unknown parity option $ARGV[$i]\n" }
}
die "sizes must be positive integers\n"
    unless $SIZE =~ /^\d+$/ && $SIZE > 0 && $VOLUME_SIZE =~ /^\d+$/ && $VOLUME_SIZE > 0;

my $TMP = File::Temp::tempdir(CLEANUP => 1);
my $EXT_PNG = File::Spec->catfile($TMP, 'ph_ext.png');
my $EXT_TEX;

# Deterministic non-uniform 8-bit texture for external-texture effects
# (text/media) — a solid would hide texture-orientation/sampling divergence.
sub ext_texture {
    return $EXT_TEX if $EXT_TEX;
    my @d;
    for my $y (0 .. $SIZE - 1) {
        for my $x (0 .. $SIZE - 1) {
            push @d, $x / ($SIZE - 1), $y / ($SIZE - 1), (($x + $y) % $SIZE) / ($SIZE - 1), 1.0;
        }
    }
    my $surf = Math::Fractal::Noisemaker::Surface->new($SIZE, $SIZE, \@d);
    open my $fh, '>:raw', $EXT_PNG or die $!;
    print {$fh} encode_png($surf);
    close $fh;
    open my $rf, '<:raw', $EXT_PNG or die $!;
    local $/;
    $EXT_TEX = decode_png(scalar <$rf>);
    return $EXT_TEX;
}

sub _param_args {
    my ($params) = @_;
    return join ', ', map { "$_: $params->{$_}" } sort keys %$params;
}

# Run the oracle CLI in the oracle checkout with `$stdin` (a DSL program, or
# undef) on its standard input, discarding its output streams. The standard
# handles are redirected around system() rather than in a forked child, so
# this also runs on Windows.
sub _run_oracle {
    my ($stdin, @cmd) = @_;
    my $in_file = File::Spec->catfile($TMP, 'ph_stdin.dsl');
    open my $ifh, '>', $in_file or die "cannot write $in_file: $!\n";
    print {$ifh} defined $stdin ? $stdin : '';
    close $ifh;
    my $cwd = Cwd::getcwd();
    open my $saved_in,  '<&', \*STDIN  or die "cannot save STDIN: $!\n";
    open my $saved_out, '>&', \*STDOUT or die "cannot save STDOUT: $!\n";
    open my $saved_err, '>&', \*STDERR or die "cannot save STDERR: $!\n";
    open STDIN,  '<', $in_file              or die "cannot redirect STDIN: $!\n";
    open STDOUT, '>', File::Spec->devnull   or die "cannot redirect STDOUT: $!\n";
    open STDERR, '>', File::Spec->devnull   or die "cannot redirect STDERR: $!\n";
    chdir $CPU_DIR or die "cannot enter $CPU_DIR: $!\n";
    my $status = system(@cmd);
    chdir $cwd;
    open STDIN,  '<&', $saved_in  or die "cannot restore STDIN: $!\n";
    open STDOUT, '>&', $saved_out or die "cannot restore STDOUT: $!\n";
    open STDERR, '>&', $saved_err or die "cannot restore STDERR: $!\n";
    return $status == 0;
}

sub js_effect {
    my ($effect_id, $out, $input_png, $params) = @_;
    if (my $source = $EXTERNAL_INPUT_SOURCES{$effect_id}) {
        local $ENV{NOISEMAKER_CPU_DIR} = $CPU_DIR;
        unlink $out;
        die "oracle failed\n" unless _run_oracle($source,
            'node', File::Spec->catfile($FindBin::Bin, 'oracle-external-input.mjs'), $effect_id, $out,
            '--width', $SIZE, '--height', $SIZE, '--seed', $SEED, '--time', $TIME);
        open my $fh, '<:raw', $out or die "oracle wrote nothing\n";
        local $/;
        return decode_png(scalar <$fh>);
    }
    my $program = particle_program(meta()->{effects}{$effect_id}, $params);
    my @cmd = ('node', $CLI);
    if ($program) { push @cmd, 'render', '-' }
    else          { push @cmd, 'effect', $effect_id }
    push @cmd, '--width', $SIZE, '--height', $SIZE, '--seed', $SEED, '--time', $TIME,
        '--output', $out;
    push @cmd, '--input', $input_png if $input_png;
    if (!$program) {
        push @cmd, '--param', "$_=$params->{$_}" for sort keys %$params;
    }
    unlink $out;
    die "oracle failed\n" unless _run_oracle($program, @cmd);
    open my $fh, '<:raw', $out or die "oracle wrote nothing\n";
    local $/;
    return decode_png(scalar <$fh>);
}

sub solid {
    my ($color) = @_;
    return render_effect(
        'synth/solid', (defined $color ? { color => $color } : {}), undef,
        width => $SIZE, height => $SIZE, seed => $SEED, time => $TIME
    );
}

sub perl_render {
    my ($effect_id, $kind, $ext, $render_params) = @_;
    my $eff = meta()->{effects}{$effect_id};
    my %opts = (width => $SIZE, height => $SIZE, seed => $SEED, time => $TIME);
    if (my $source = $EXTERNAL_INPUT_SOURCES{$effect_id}) {
        return render_dsl($source, %opts, external_inputs => external_inputs_for($effect_id));
    }
    if (my $program = particle_program($eff, $render_params)) {
        return render_dsl($program, %opts);
    }
    my $domain = $eff->{domain} || 'image';
    if ($domain ne 'image') {
        my $call = "$eff->{func}(" . _param_args($render_params) . ')';
        my $source;
        if ($domain eq 'loop-begin' || $domain eq 'loop-end') {
            my $begin = $domain eq 'loop-begin' ? $call : 'loopBegin(iterationCount: 1)';
            my $end   = $domain eq 'loop-end'   ? $call : 'loopEnd()';
            $source = "search render, synth\nsolid().$begin.$end.write(o0)\nrender(o0)";
        }
        else {
            my $volume = $render_params->{volumeSize}
                // ($eff->{params}{volumeSize} || {})->{default} // 16;
            my $search = 'search synth3d, filter3d, render';
            $source = $domain eq 'volume-generator'
                ? "$search\n$call.render3d().write(o0)\nrender(o0)"
                : $domain eq 'volume-filter'
                ? "$search\nnoise3d(volumeSize: $volume).$call.render3d().write(o0)\nrender(o0)"
                : "$search\nnoise3d(volumeSize: $volume).$call.write(o0)\nrender(o0)";
        }
        return render_dsl($source, %opts);
    }
    if ($kind eq 'generator') {
        my $inputs = $ext ? { $ext => ext_texture() } : {};
        return render_effect($effect_id, $render_params, $inputs, %opts);
    }
    # Replicate the JS `effect` CLI: primary input is a default solid; each
    # surface param (mixers) gets solid(#f30 / #0cf), alternating by index.
    my %inputs = (inputTex => solid());
    $inputs{$ext} = ext_texture() if $ext;
    my $params = $eff->{params};
    my @order  = @{ $eff->{paramOrder} || [sort keys %$params] };
    my @surf = grep { ref $params->{$_} eq 'HASH' && ($params->{$_}{type} || '') eq 'surface' } @order;
    for my $i (0 .. $#surf) {
        my $pname = $surf[$i];
        my $src   = solid($i % 2 ? '#0cf' : '#f30');
        my $spec  = $params->{$pname};
        my %names = map { $_ => 1 } grep { defined } $spec->{uniform}, $spec->{texture}, $pname;
        $inputs{$_} = $src for keys %names;
    }
    return render_effect($effect_id, $render_params, \%inputs, %opts);
}

my $effects = meta()->{effects};
my @unknown_ids = $only ? grep { !exists $effects->{$_} } sort keys %$only : ();
my @ids = grep { !$only || $only->{$_} } sort keys %$effects;

my (@ok, @diffs, %errors, @oracle_err);
my $exact = 0;
for my $eid (@ids) {
    my $kind = $effects->{$eid}{kind};
    my $ext  = $effects->{$eid}{externalTexture};
    my %render_params;
    if ($effects->{$eid}{iterated}) {
        $render_params{iterationCount} = 1;
        $render_params{stateSize} = 64 if exists $effects->{$eid}{params}{stateSize};
    }
    $render_params{volumeSize} = $VOLUME_SIZE if exists $effects->{$eid}{params}{volumeSize};
    my $input_png = $ext ? (ext_texture() && $EXT_PNG) : undef;
    my $js = eval { js_effect($eid, File::Spec->catfile($TMP, 'ph_js.png'), $input_png, \%render_params) };
    if (!$js) { push @oracle_err, $eid; next }
    my $pl = eval { perl_render($eid, $kind, $ext, \%render_params) };
    if (!$pl) {
        (my $key = $@) =~ s/\n.*//s;
        $key = substr($key, 0, 70);
        push @{ $errors{$key} ||= [] }, $eid;
        next;
    }
    my @ja = unpack 'C*', $js->to_rgba8;
    my @pa = unpack 'C*', $pl->to_rgba8;
    if (@ja != @pa) { push @{ $errors{'shape-mismatch'} ||= [] }, $eid; next }
    my $d = 0;
    for my $i (0 .. $#ja) {
        my $x = abs($ja[$i] - $pa[$i]);
        $d = $x if $x > $d;
    }
    if ($d == 0) { push @ok, $eid; $exact++ } else { push @diffs, [$eid, $d] }
}

my $err_count = 0;
$err_count += @$_ for values %errors;
printf "\n=== PARITY: %d/%d pass (byte-exact)  |  %d diff  |  %d runtime-error  |  %d oracle-error ===\n\n",
    scalar @ok, scalar @ids, scalar @diffs, $err_count, scalar @oracle_err;
if (%errors) {
    print "RUNTIME ERRORS (grouped):\n";
    for my $msg (sort { @{ $errors{$b} } <=> @{ $errors{$a} } } keys %errors) {
        printf "  %3d  %s   e.g. %s\n", scalar @{ $errors{$msg} }, $msg, $errors{$msg}[0];
    }
}
if (@diffs) {
    print "\nDIFFS (rendered but off):\n";
    for my $d ((sort { $b->[1] <=> $a->[1] } @diffs)[0 .. (@diffs > 20 ? 19 : $#diffs)]) {
        printf "  %4d  %s\n", $d->[1], $d->[0];
    }
}
if (@oracle_err) {
    print "\nORACLE ERRORS (JS effect CLI failed): " . scalar(@oracle_err)
        . "  e.g. @oracle_err[0 .. (@oracle_err > 5 ? 4 : $#oracle_err)]\n";
}
print "\nPASS: " . scalar(@ok) . "  (byte-exact: $exact)\n";
print "UNKNOWN EFFECTS: @unknown_ids\n" if @unknown_ids;

my $failed = !@ids || @ok != @ids || @diffs || $err_count || @oracle_err || @unknown_ids;
exit 1 if $failed;
