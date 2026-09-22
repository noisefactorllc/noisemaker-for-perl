package Math::Fractal::Noisemaker::Transpiler::Build;

# Regenerate the vendored Perl kernel bundle from the CDN.
#
# Pipeline: CDN::fetch_effect -> Preprocess::normalize -> Parser::parse ->
# Codegen::emit_perl -> write lib/Math/Fractal/Noisemaker/bundle/. Pure Perl.
#
#   perl -Ilib -MMath::Fractal::Noisemaker::Transpiler::Build -e run -- --all
#   (or scripts/build-bundle.pl [--all | --only a,b] [--update-lock])

use strict;
use warnings;
use Digest::SHA    ();
use File::Basename ();
use File::Path     ();
use File::Spec     ();
use File::Copy     ();
use File::Find     ();
use File::Temp     ();
use JSON::PP       ();
use Exporter 'import';

use Math::Fractal::Noisemaker::Transpiler::CDN qw(fetch_effect eligible_ids);
use Math::Fractal::Noisemaker::Transpiler::Preprocess  qw(normalize);
use Math::Fractal::Noisemaker::Transpiler::Parser      qw(parse);
use Math::Fractal::Noisemaker::Transpiler::Codegen     qw(emit_perl);
use Math::Fractal::Noisemaker::Transpiler::SharedEnums qw(%SHARED_ENUMS);
use Math::Fractal::Noisemaker::KernelCache ();

our @EXPORT_OK = qw(build run bundle_dir);
our $STATEFUL_REVISION = 'a024dc3a960cc44af454abc7aebce50456c194e6';

my $_JSON        = JSON::PP->new->utf8->canonical;
my $_JSON_PRETTY = JSON::PP->new->utf8->canonical->indent->indent_length(2)->space_after;
my %_AUTHORED_STATEFUL = map { $_ => 1 } qw(
    filter/convolutionFeedback filter/feedback filter/motionBlur
    filter/temporalAberration points/attractor points/buddhabrot points/dla
    points/flock points/flow points/hydraulic points/lenia points/life
    points/physarum points/physical render/pointsBillboardRender
    render/pointsEmit render/pointsRender synth/cellularAutomata synth/mnca
    synth/navierStokes synth/reactionDiffusion
);

sub bundle_dir {
    my $here = File::Basename::dirname(__FILE__);    # .../Noisemaker/Transpiler
    return File::Spec->catdir($here, '..', 'bundle');
}

# Inline choices for member params that reference a shared enum by name only
# (the CDN bundle omits the name->index table). Mutates params in place.
sub _resolve_shared_enums {
    my ($params) = @_;
    for my $spec (values %$params) {
        next unless ref $spec eq 'HASH';
        next unless ($spec->{type} || '') eq 'member' && !$spec->{choices};
        my $choices = $SHARED_ENUMS{ $spec->{enum} || '' };
        $spec->{choices} = {%$choices} if $choices;
    }
}

sub runtime_defines {
    my ($params) = @_;
    my %out;
    for my $spec (values %$params) {
        next unless ref $spec eq 'HASH' && defined $spec->{define};
        $out{ $spec->{define} } = (($spec->{type} || '') eq 'float') ? 'float' : 'int';
    }
    return \%out;
}

sub infer_kind {
    my ($effect) = @_;
    my $namespace = $effect->{namespace} || '';
    return 'generator' if $namespace eq 'synth' || $namespace eq 'synth3d';
    return 'filter'    if $namespace eq 'filter3d';
    return 'mixer'     if $namespace eq 'mixer';
    return 'filter'    if $namespace eq 'points' || $namespace eq 'render';

    my $has_inputs = 0;
    my $external   = 0;
    for my $pass (@{ $effect->{passes} || [] }) {
        for my $value (values %{ $pass->{inputs} || {} }) {
            $has_inputs = 1;
            next if ref $value || !defined $value;
            next if $value eq 'inputTex' || $value eq 'outputTex';
            next if $value =~ /^_/ || $value =~ /^global_/;
            next if $value eq 'selfTex' || $value eq 'feedback';
            my $texture = $effect->{textures}{$value};
            next if $texture
                && defined $texture->{width} && ref($texture->{width}) eq ''
                && $texture->{width} =~ /^\d+(?:\.\d+)?$/
                && defined $texture->{height} && ref($texture->{height}) eq ''
                && $texture->{height} =~ /^\d+(?:\.\d+)?$/;
            $external = 1;
        }
    }
    return 'generator' unless $has_inputs;
    return $external ? 'mixer' : 'filter';
}

sub _key  { my ($eid, $program) = @_; "$eid:$program" }
sub _file { my ($key) = @_; (my $f = $key) =~ s{[/:]}{__}g; "$f.pl" }

sub _read_json {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    return $_JSON->decode(scalar <$fh>);
}

sub _write_raw {
    my ($path, $text) = @_;
    File::Path::make_path(File::Basename::dirname($path));
    open my $fh, '>:raw', $path or die "cannot write $path: $!\n";
    print {$fh} $text or die "cannot write $path: $!\n";
    close $fh or die "cannot close $path: $!\n";
}

# Stage on the same filesystem. A rejected build never changes the installed
# bundle. If publication fails, restore the previous directory; retain its
# backup for recovery if the filesystem also refuses that restoration.
sub _publish_bundle {
    my ($out_dir, $files, $bundle) = @_;
    die "bundle directory must not be a symlink\n" if -l $out_dir;
    my $parent = File::Basename::dirname($out_dir);
    File::Path::make_path($parent);
    my $work = File::Temp::tempdir('.bundle-build-XXXXXX', DIR => $parent, CLEANUP => 0);
    my ($stage, $backup) = ("$work/new", "$work/previous");
    my $ok = eval {
        File::Path::make_path($stage);
        if (-d $out_dir) {
            File::Find::find({ no_chdir => 1, wanted => sub {
                my $src = $File::Find::name;
                die "bundle contains a symlink: $src\n" if -l $src;
                return if $src eq $out_dir;
                my $dst = File::Spec->catfile($stage, File::Spec->abs2rel($src, $out_dir));
                if (-d $src) { File::Path::make_path($dst) }
                elsif (-f $src) {
                    File::Path::make_path(File::Basename::dirname($dst));
                    File::Copy::copy($src, $dst) or die "cannot stage $src: $!\n";
                }
            }}, $out_dir);
        }
        _write_raw(File::Spec->catfile($stage, $_), $files->{$_}) for sort keys %$files;
        for my $effect (values %{ $bundle->{effects} }) {
            for my $pass (@{ $effect->{passes} }) {
                next unless defined $pass->{key};
                my $path = File::Spec->catfile($stage, 'kernels', 'perl', _file($pass->{key}));
                die "candidate bundle is missing kernel $pass->{key}\n" unless -f $path;
            }
        }
        my $had_old = -e $out_dir;
        rename($out_dir, $backup) or die "cannot preserve $out_dir: $!\n" if $had_old;
        unless (rename($stage, $out_dir)) {
            my $error = $!;
            if ($had_old) {
                rename($backup, $out_dir)
                    or die "cannot restore bundle; previous bundle retained at $backup: $!\n";
            }
            die "cannot publish $out_dir: $error\n";
        }
        1;
    };
    my $error = $@;
    File::Path::remove_tree($work) if $ok || !-e $backup;
    die $error unless $ok;
}

sub _preserve_stateful {
    my ($bundle, $old_bundle) = @_;
    my @ids = sort grep {
        $_AUTHORED_STATEFUL{$_} && $old_bundle->{effects}{$_}{iterated}
    } keys %{ $old_bundle->{effects} || {} };
    return undef unless @ids;

    my $revision = $old_bundle->{provenance}{statefulRevision};
    die "stateful bundle revision is missing or stale; expected $STATEFUL_REVISION\n"
        unless defined $revision && $revision eq $STATEFUL_REVISION;

    for my $id (@ids) {
        $bundle->{effects}{$id} = {
            %{ $old_bundle->{effects}{$id} },
            domain => $old_bundle->{effects}{$id}{domain} || 'image',
        };
    }
    $bundle->{provenance}{statefulRevision} = $STATEFUL_REVISION;
    return $STATEFUL_REVISION;
}

sub build {
    my ($ids, %opt) = @_;
    die "build requires at least one effect id\n" unless ref $ids eq 'ARRAY' && @$ids;
    my $out_dir     = File::Spec->rel2abs(defined $opt{out_dir} ? $opt{out_dir} : bundle_dir());
    my $update_lock = $opt{update_lock} ? 1 : 0;
    my $lock_path   = File::Spec->catfile($out_dir, 'bundle-lock.json');
    my $metadata_path = File::Spec->catfile($out_dir, 'metadata.json');
    my $old         = _read_json($lock_path) || { hashes => {} };
    my $old_bundle  = _read_json($metadata_path) || { effects => {}, provenance => {} };
    my %hashes    = %{ $old->{hashes} || {} };
    my @drift;
    my $bundle = {
        provenance => {
            source  => 'shaders.noisedeck.app CDN',
            version => $Math::Fractal::Noisemaker::Transpiler::CDN::CDN_VERSION,
            base    => $Math::Fractal::Noisemaker::Transpiler::CDN::CDN_BASE,
        },
        effects => {},
    };
    my $n_ok = 0;
    my %files;
    for my $eid (@$ids) {
        my $eff = eval { fetch_effect($eid) };
        if (!$eff) {
            die "cannot fetch $eid: " . ($@ || "no effect returned\n");
        }
        _resolve_shared_enums($eff->{params});
        my $defines = runtime_defines($eff->{params});
        my @passes;
        for my $p (@{ $eff->{passes} }) {
            my $glsl = $eff->{programs}{ $p->{program} };
            if (!defined $glsl) {
                # A pass without GLSL is a CPU-only draw op (e.g. wormhole's
                # point-scatter deposit). Keep it so the renderer can run its
                # native adapter; it has no transpiled kernel key.
                if ($p->{drawMode}) {
                    my %pass = %$p;
                    $pass{key}      = undef;
                    $pass{inputs}   ||= {};
                    $pass{outputs}  ||= {};
                    $pass{uniforms} ||= {};
                    push @passes, \%pass;
                    next;
                }
                die "missing GLSL for $eid:$p->{program}\n";
            }
            my $key = _key($eid, $p->{program});
            (my $stripped = $glsl) =~ s/^\s+|\s+$//g;
            my $h = Digest::SHA::sha256_hex($stripped);
            my $perl = eval {
                my $norm = normalize($glsl, $defines, $key);
                my $ast  = parse($norm->{source});
                emit_perl($ast, $norm->{outputs}, $norm->{varyings});
            };
            if (!defined $perl) {
                die "cannot compile $key: $@";
            }
            Math::Fractal::Noisemaker::KernelCache::load_kernel($perl, $key);
            $files{File::Spec->catfile('kernels', 'perl', _file($key))} = $perl;
            push @drift, $key
                if $old->{hashes} && $old->{hashes}{$key} && $old->{hashes}{$key} ne $h;
            $hashes{$key} = $h;
            $n_ok++;
            my %pass = %$p;
            $pass{key}      = $key;
            $pass{inputs}   ||= {};
            $pass{outputs}  ||= {};
            $pass{uniforms} ||= {};
            push @passes, \%pass;
        }
        die "effect $eid has no renderable passes\n" unless @passes;
        $bundle->{effects}{$eid} = {
            namespace => $eff->{namespace},
            func      => $eff->{func},
            kind      => infer_kind($eff),
            params    => $eff->{params},
            # Definition order of params — the oracle binds positional DSL args
            # and mixer surface feeds by this order; JSON hashes don't keep it.
            paramOrder => ($eff->{paramOrder} || [sort keys %{ $eff->{params} }]),
            textures   => ($eff->{textures} || {}),
            passes     => \@passes,
        };
        $bundle->{effects}{$eid}{externalTexture} = $eff->{externalTexture}
            if $eff->{externalTexture};
        for my $field (qw(domain outputTex outputTex3d outputGeo loopRole)) {
            $bundle->{effects}{$eid}{$field} = $eff->{$field}
                if defined $eff->{$field};
        }
        $bundle->{effects}{$eid}{iterated} = $eff->{iterated} ? JSON::PP::true : JSON::PP::false
            if exists $eff->{iterated};
    }
    if (@drift && !$update_lock) {
        die "SHADER DRIFT vs bundle-lock.json (" . scalar(@drift) . "): "
            . join(', ', @drift[0 .. (@drift > 8 ? 7 : $#drift)])
            . "\nRe-run with --update-lock to accept.\n";
    }
    my $stateful_revision = _preserve_stateful($bundle, $old_bundle);
    my $new_lock = {
        source  => $Math::Fractal::Noisemaker::Transpiler::CDN::CDN_BASE,
        version => $Math::Fractal::Noisemaker::Transpiler::CDN::CDN_VERSION,
        hashes  => \%hashes,
    };
    $new_lock->{statefulRevision} = $stateful_revision if defined $stateful_revision;
    $files{'metadata.json'} = $_JSON_PRETTY->encode($bundle);
    $files{'bundle-lock.json'} = $_JSON_PRETTY->encode($new_lock);
    _publish_bundle($out_dir, \%files, $bundle);
    printf "wrote %d effect(s) (%d programs) from CDN %s\n",
        scalar(keys %{ $bundle->{effects} }), $n_ok,
        $Math::Fractal::Noisemaker::Transpiler::CDN::CDN_VERSION;
}

sub run {
    my @argv = @_ ? @_ : @ARGV;
    my $ids;
    if (grep { $_ eq '--all' } @argv) {
        $ids = eligible_ids();
    }
    elsif (my ($i) = grep { $argv[$_] eq '--only' } 0 .. $#argv) {
        die "--only requires a comma-separated effect-id list\n"
            if $i >= $#argv || $argv[ $i + 1 ] =~ /^--/;
        $ids = [split /,/, $argv[ $i + 1 ]];
    }
    else {
        $ids = ['synth/solid', 'filter/invert'];
    }
    build($ids, update_lock => scalar(grep { $_ eq '--update-lock' } @argv));
}

1;

__END__

=head1 NAME

Math::Fractal::Noisemaker::Transpiler::Build - regenerate a Perl shader bundle

=head1 SYNOPSIS

    perl scripts/build-bundle.pl --all

=head1 DEVELOPER INTERFACE

This is a maintainer tool; installed rendering uses the checked-in bundle and
does not fetch shaders. C<build>, C<run>, and C<bundle_dir> are optional exports.

C<build(\@effect_ids, out_dir =E<gt> $directory, update_lock =E<gt> 0)> fetches,
parses, and compiles every requested effect. Source or compilation failures,
missing kernels, and unaccepted source-hash changes throw exceptions and leave
the previous bundle unchanged. The complete candidate is staged on the same
filesystem before publication. Do not run concurrent builders or readers while
replacing a bundle. If filesystem recovery fails, the error identifies the
preserved previous directory for manual recovery.

C<update_lock =E<gt> 1> explicitly accepts source changes. Review the resulting
diff and rerun parity; hashes record inputs, not proof of rendering equivalence.
Authored stateful effects are preserved from their pinned existing bundle.
An explicit subset produces metadata for that subset plus preserved authored
stateful effects; use C<--all> for a complete release bundle.

C<run(@arguments)> implements the build script's C<--all>, C<--only id,id>, and
C<--update-lock> switches. C<bundle_dir()> returns the default output directory.
The CDN source can be selected with C<NM_SHADER_CDN> and C<NM_SHADER_VERSION>;
existing cached inputs may be used. Never rebuild the bundle during installation.

=cut
