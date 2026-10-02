#!/usr/bin/env perl
# Full-catalog byte-parity harness: renders EVERY effect in the bundled
# catalog (iterated and typed domains included) on both this port and the
# pinned noisemaker-for-cpu oracle through each side's `run` DSL CLI, and
# compares the decoded RGBA8 output bytes. scripts/parity.pl covers the
# published 167-image-effect contract; this entrypoint extends the same
# methodology to the whole catalog plus explicit `filtering: 0` isosurface
# variants of the volume renderers.
#
# Requires a noisemaker-for-cpu checkout at the revision pinned in
# scripts/oracle-lock.json (NOISEMAKER_CPU_DIR or the first argument).
# Exits nonzero on any diff, runtime error, or oracle error. The current
# expected result against oracle bfbe54764eee is documented in
# docs/COMPATIBILITY.md ("Full-catalog sweep").

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin";
use File::Spec;
use File::Temp qw(tempdir);

use JSON::PP qw(decode_json);
use Math::Fractal::Noisemaker::PNG qw(encode_png decode_png);
use Math::Fractal::Noisemaker::Surface;
use ParityOracle qw(verify_oracle);

my $CPU_DIR = $ENV{NOISEMAKER_CPU_DIR} || shift
    or die "usage: $0 /path/to/noisemaker-for-cpu\n";
my $PERL_ROOT = File::Spec->catdir($FindBin::Bin, '..');
my $PERL_CLI  = File::Spec->catfile($PERL_ROOT, 'bin', 'make-noise');
my $CPU_CLI   = File::Spec->catfile($CPU_DIR, 'bin', 'noisemaker-cpu.js');
my $pin = verify_oracle($CPU_DIR);
print "Reference: $pin->{revision} (runtime SHA-256 verified)\n";
print "Port: $PERL_ROOT\n";

my $meta = decode_json(do {
    open my $fh, '<:raw', File::Spec->catfile($PERL_ROOT,
        'lib', 'Math', 'Fractal', 'Noisemaker', 'bundle', 'metadata.json') or die $!;
    local $/; <$fh>;
});
my $effects = $meta->{effects};
my @ids = sort keys %$effects;
print "Catalog: " . scalar(@ids) . " effects\n";

my $TMP = tempdir(CLEANUP => 1);
my $EXT_PNG = File::Spec->catfile($TMP, 'external.png');
{
    # 2x2 external surface, rgba16f [0.2, 0.4, 0.6, 1] — the same constant the
    # cpu catalog-smoke sweep binds as imageTex/textTex.
    my @d;
    for (1 .. 4) { push @d, 0.2, 0.4, 0.6, 1.0 }
    my $surf = Math::Fractal::Noisemaker::Surface->new(2, 2, \@d);
    open my $fh, '>:raw', $EXT_PNG or die $!;
    print {$fh} encode_png($surf);
    close $fh;
}

# Mirror cpu test/catalog-smoke.test.js smokeProgram().
sub smoke_program {
    my ($id, $extra_args) = @_;
    my $effect  = $effects->{$id};
    my $domain  = $effect->{domain} || 'image';
    my $params = $effect->{params} || {};
    my @covered = map { my $c = $_; $c =~ s/\s*:.*//; $c } @$extra_args;
    my %skip = map { $_ => 1 } @covered, qw(iterationCount volumeSize seed type filtering);
    my %resource_type = map { $_ => 1 } qw(surface geometry volume);
    my @args;
    # Bind every scalar parameter to its canonical metadata default on both
    # sides, so neither side relies on unbound-uniform (NaN) semantics and the
    # comparison reflects real rendering only.
    for my $name (@{ $effect->{paramOrder} || [sort keys %$params] }) {
        my $p = $params->{$name} or next;
        next if $skip{$name} || $resource_type{ $p->{type} || '' };
        my $d = $p->{default};
        next unless defined $d;
        my $v;
        if (ref $d eq 'ARRAY') { $v = '[' . join(', ', @$d) . ']' }
        elsif (JSON::PP::is_bool($d)) { $v = $d ? 'true' : 'false' }
        elsif (!ref $d && $d =~ /\A-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?\z/) { $v = "$d" }
        elsif (!ref $d) { ($v = $d) =~ s/\\/\\\\/g; $v =~ s/"/\\"/g; $v = "\"$v\"" }
        else { $v = "$d" }
        push @args, "$name: $v";
    }
    push @args, 'iterationCount: ' . ($domain eq 'image' ? 4 : 1)
        if $effect->{iterated};
    push @args, 'volumeSize: 2' if $params->{volumeSize};
    push @args, 'type: 1' if $id eq 'synth3d/flythrough3d';
    push @args, 'seed: 3' if $params->{seed};
    push @args, @$extra_args;
    my $call = $effect->{func} . '(' . join(', ', @args) . ')';

    # needsParticlePipeline: an effect reading a particle-state global that no
    # earlier pass of its own wrote must run after render/pointsEmit.
    my $written = 0;
    my $needs_pipeline = 0;
    for my $pass (@{ $effect->{passes} || [] }) {
        for my $input (values %{ $pass->{inputs} || {} }) {
            $needs_pipeline = 1
                if $input =~ /\Aglobal_(?:xyz|vel|rgba|points_trail)\z/ && !$written;
        }
        $written = 1 if %{ $pass->{outputs} || {} };
    }
    # pointsEmit owns the particle-state size; the effect's own stateSize
    # param must stay unbound or it would contradict the pipeline's atlas.
    if ($needs_pipeline) {
        @args = grep { !/^stateSize:/ } @args;
        $call = $effect->{func} . '(' . join(', ', @args) . ')';
    }

    if ($needs_pipeline) {
        return "search points, render, synth\n"
            . "solid(color: #58c).pointsEmit(stateSize: x64).$call.write(o0)\nrender(o0)";
    }
    if ($domain eq 'loop-begin' || $domain eq 'loop-end') {
        my $begin_call = $domain eq 'loop-begin' ? $call : 'loopBegin(iterationCount: 4)';
        my $end_call   = $domain eq 'loop-end' ? $call : 'loopEnd()';
        return "search render, synth\n"
            . "solid(color: #58c).$begin_call.$end_call.write(o0)\nrender(o0)";
    }
    if ($domain =~ /\Avolume-/) {
        my $search = 'search synth3d, filter3d, render';
        return "$search\n$call.render3d(volumeSize: 2).write(o0)\nrender(o0)"
            if $domain eq 'volume-generator';
        return "$search\nnoise3d(volumeSize: 2).$call.render3d(volumeSize: 2).write(o0)\nrender(o0)"
            if $domain eq 'volume-filter';
        return "$search\nnoise3d(volumeSize: 2).$call.write(o0)\nrender(o0)";
    }
    my $search = $effect->{namespace} eq 'synth' ? 'search synth'
        : "search $effect->{namespace}, synth";
    return "$search\n$call.write(o0)\nrender(o0)" if $effect->{kind} eq 'generator';
    return "$search\nsolid(color: #58c).write(o0)\nread(o0).$call.write(o1)\nrender(o1)";
}

sub run_side {
    my ($side, $program, $w, $h, $out) = @_;
    my $err = File::Spec->catfile($TMP, "$side-err.txt");
    my @cmd = $side eq 'perl'
        ? ($^X, '-I' . File::Spec->catdir($PERL_ROOT, 'lib'), $PERL_CLI, 'run')
        : ('node', $CPU_CLI, 'run');
    # The perl interpreter is far slower than the JS runtime on heavy agent
    # kernels (points/flock); a bounded timeout records the port render as an
    # error instead of blocking the sweep for hours.
    unshift @cmd, 'timeout', ($side eq 'perl' ? 600 : 300);
    push @cmd, '--width', $w, '--height', $h, '--seed', 3, '--time', 0.25,
        '--input', $EXT_PNG, '--filename', $out;
    my $dsl = File::Spec->catfile($TMP, "$side-program.dsl");
    open my $fh, '>', $dsl or die $!;
    print {$fh} $program;
    close $fh;
    my $status = system(
        join(' ', map { quotemeta } @cmd)
            . ' < ' . quotemeta($dsl)
            . ' > /dev/null 2> ' . quotemeta($err),
    );
    return $status == 0;
}

sub rgba8 {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "no output: $path\n";
    local $/;
    return decode_png(scalar <$fh>)->to_rgba8;
}

my (@ok, @diff, %errors);
sub compare_case {
    my ($label, $id, $program, $w, $h) = @_;
    my $effect = $effects->{$id};
    my $cpu_png = File::Spec->catfile($TMP, 'cpu.png');
    my $pl_png  = File::Spec->catfile($TMP, 'pl.png');
    unlink $cpu_png, $pl_png;
    unless (run_side('cpu', $program, $w, $h, $cpu_png)) {
        push @{ $errors{'oracle-render-error'} }, $label;
        print "ERROR   $label (cpu side failed)\n";
        return;
    }
    unless (run_side('perl', $program, $w, $h, $pl_png)) {
        push @{ $errors{'port-render-error'} }, $label;
        print "ERROR   $label (perl side failed)\n";
        return;
    }
    my $jc = rgba8($cpu_png);
    my $pc = rgba8($pl_png);
    if (length($jc) != length($pc)) {
        push @diff, [$label, -1];
        print "DIFF    $label (shape " . length($jc) . " vs " . length($pc) . ")\n";
        return;
    }
    my $max = 0;
    for my $i (0 .. length($jc) - 1) {
        my $d = abs(ord(substr($jc, $i, 1)) - ord(substr($pc, $i, 1)));
        $max = $d if $d > $max;
    }
    if ($max == 0) { push @ok, $label; print "EXACT   $label\n" }
    else { push @diff, [$label, $max]; print "DIFF    $label (max channel delta $max)\n" }
}

for my $id (@ids) {
    my $effect = $effects->{$id};
    my $w = $effect->{iterated} ? 16 : 2;
    my $h = $w;
    compare_case($id, $id, smoke_program($id, []), $w, $h);
}

# Extra cases for the compile-time filtering choice on the volume renderers
# (FILTERING is a define, baked per render): the isosurface path alongside
# each renderer's voxel default, including the non-solid-ray march
# (threshold 0.9) that cpu's own volume-effects test exercises.
for my $id (qw(render/render3d render/renderCubemap3d render/renderLandscape3d)) {
    my $w = 4; my $h = $w;
    my @extra = ('filtering: 0');
    push @extra, 'threshold: 0.9' if $id eq 'render/renderLandscape3d';
    compare_case("$id [filtering: 0]", $id, smoke_program($id, \@extra), $w, $h);
}

my $err_total = 0;
$err_total += scalar @{ $errors{$_} } for keys %errors;
my $total_cases = @ok + @diff + $err_total;
print "\n=== FULL-CATALOG PARITY: " . scalar(@ok) . "/$total_cases exact"
    . "  |  " . scalar(@diff) . " diff  |  $err_total errors ===\n";
for my $group (sort keys %errors) {
    print "  $group: @{$errors{$group}}\n";
}
print "DIFFS: " . join(', ', map { "$_->[0]($_->[1])" } @diff) . "\n" if @diff;
exit(@diff || %errors ? 1 : 0);
