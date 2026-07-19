#!/usr/bin/env perl

# Cross-language parity harness: render every bundled effect in Perl vs the
# JS oracle (noisemaker-cpu `effect` CLI) at parity settings, and categorize.
#
# Usage: perl scripts/parity.pl [--only id,id] [--size N]

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Spec;
use File::Temp ();

use Math::Fractal::Noisemaker::PNG qw(encode_png decode_png);
use Math::Fractal::Noisemaker::Renderer qw(render_effect meta);
use Math::Fractal::Noisemaker::Surface;

my $CPU_DIR = $ENV{NOISEMAKER_CPU_DIR}
    || File::Spec->rel2abs(File::Spec->catdir($FindBin::Bin, '..', '..', 'noisemaker-cpu'));
my $CLI = File::Spec->catfile($CPU_DIR, 'bin', 'noisemaker-cpu.js');

my $SIZE = 8;
my $SEED = 1;
my $TIME = 0.25;
my $only;
for my $i (0 .. $#ARGV) {
    $only = { map { $_ => 1 } split /,/, $ARGV[ $i + 1 ] } if $ARGV[$i] eq '--only';
    $SIZE = $ARGV[ $i + 1 ] if $ARGV[$i] eq '--size';
}

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

sub js_effect {
    my ($effect_id, $out, $input_png) = @_;
    my @cmd = (
        'node', $CLI, 'effect', $effect_id,
        '--width', $SIZE, '--height', $SIZE, '--seed', $SEED, '--time', $TIME,
        '--output', $out,
    );
    push @cmd, '--input', $input_png if $input_png;
    my $pid = fork();
    if (!$pid) {
        chdir $CPU_DIR;
        open STDOUT, '>', File::Spec->devnull;
        open STDERR, '>', File::Spec->devnull;
        exec @cmd or exit 127;
    }
    waitpid $pid, 0;
    die "oracle failed\n" if $? != 0;
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
    my ($effect_id, $kind, $ext) = @_;
    if ($kind eq 'generator') {
        my $inputs = $ext ? { $ext => ext_texture() } : {};
        return render_effect($effect_id, {}, $inputs,
            width => $SIZE, height => $SIZE, seed => $SEED, time => $TIME);
    }
    # Replicate the JS `effect` CLI: primary input is a default solid; each
    # surface param (mixers) gets solid(#f30 / #0cf), alternating by index.
    my %inputs = (inputTex => solid());
    $inputs{$ext} = ext_texture() if $ext;
    my $eff    = meta()->{effects}{$effect_id};
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
    return render_effect($effect_id, {}, \%inputs,
        width => $SIZE, height => $SIZE, seed => $SEED, time => $TIME);
}

my $effects = meta()->{effects};
my @ids = grep { !$only || $only->{$_} } sort keys %$effects;

my (@ok, @diffs, %errors, @oracle_err);
for my $eid (@ids) {
    my $kind = $effects->{$eid}{kind};
    my $ext  = $effects->{$eid}{externalTexture};
    my $input_png = $ext ? (ext_texture() && $EXT_PNG) : undef;
    my $js = eval { js_effect($eid, File::Spec->catfile($TMP, 'ph_js.png'), $input_png) };
    if (!$js) { push @oracle_err, $eid; next }
    my $pl = eval { perl_render($eid, $kind, $ext) };
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
    if ($d <= 2) { push @ok, $eid } else { push @diffs, [$eid, $d] }
}

my $err_count = 0;
$err_count += @$_ for values %errors;
printf "\n=== PARITY: %d/%d pass (<=2)  |  %d diff  |  %d runtime-error  |  %d oracle-error ===\n\n",
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
print "\nPASS: " . scalar(@ok) . "\n";
