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
use JSON::PP       ();
use Exporter 'import';

use Math::Fractal::Noisemaker::Transpiler::CDN qw(fetch_effect eligible_ids);
use Math::Fractal::Noisemaker::Transpiler::Preprocess  qw(normalize);
use Math::Fractal::Noisemaker::Transpiler::Parser      qw(parse);
use Math::Fractal::Noisemaker::Transpiler::Codegen     qw(emit_perl);
use Math::Fractal::Noisemaker::Transpiler::SharedEnums qw(%SHARED_ENUMS);

our @EXPORT_OK = qw(build run bundle_dir);
our $STATEFUL_REVISION = 'a024dc3a960cc44af454abc7aebce50456c194e6';

my $_JSON        = JSON::PP->new->utf8->canonical;
my $_JSON_PRETTY = JSON::PP->new->utf8->canonical->indent->indent_length(2)->space_after;

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
    my ($passes) = @_;
    for my $p (@$passes) {
        return 'filter' if $p->{inputs} && %{ $p->{inputs} };
    }
    return 'generator';
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
    print {$fh} $text;
}

sub _preserve_stateful {
    my ($bundle, $old_bundle) = @_;
    my @ids = sort grep {
        $old_bundle->{effects}{$_}{iterated}
    } keys %{ $old_bundle->{effects} || {} };
    return undef unless @ids;

    my $revision = $old_bundle->{provenance}{statefulRevision};
    die "stateful bundle revision is missing or stale; expected $STATEFUL_REVISION\n"
        unless defined $revision && $revision eq $STATEFUL_REVISION;

    $bundle->{effects}{$_} = $old_bundle->{effects}{$_} for @ids;
    $bundle->{provenance}{statefulRevision} = $STATEFUL_REVISION;
    return $STATEFUL_REVISION;
}

sub build {
    my ($ids, %opt) = @_;
    my $out_dir     = defined $opt{out_dir} ? $opt{out_dir} : bundle_dir();
    my $update_lock = $opt{update_lock} ? 1 : 0;
    my $kdir        = File::Spec->catdir($out_dir, 'kernels', 'perl');
    File::Path::make_path($kdir);
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
    my ($n_ok, $n_skip) = (0, 0);
    for my $eid (@$ids) {
        my $eff = eval { fetch_effect($eid) };
        if (!$eff) {
            $n_skip++;
            (my $e = $@) =~ s/\n.*//s;
            print STDERR "skip $eid: cdn: " . substr($e, 0, 70) . "\n";
            next;
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
                }
                next;
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
                $n_skip++;
                (my $e = $@) =~ s/\n.*//s;
                print STDERR "skip $key: " . substr($e, 0, 80) . "\n";
                next;
            }
            _write_raw(File::Spec->catfile($kdir, _file($key)), $perl);
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
        next unless @passes;
        $bundle->{effects}{$eid} = {
            namespace => $eff->{namespace},
            func      => $eff->{func},
            kind      => infer_kind($eff->{passes}),
            params    => $eff->{params},
            # Definition order of params — the oracle binds positional DSL args
            # and mixer surface feeds by this order; JSON hashes don't keep it.
            paramOrder => ($eff->{paramOrder} || [sort keys %{ $eff->{params} }]),
            textures   => ($eff->{textures} || {}),
            passes     => \@passes,
        };
        $bundle->{effects}{$eid}{externalTexture} = $eff->{externalTexture}
            if $eff->{externalTexture};
        $bundle->{effects}{$eid}{iterated} = $eff->{iterated} ? JSON::PP::true : JSON::PP::false
            if exists $eff->{iterated};
    }
    if (@drift && !$update_lock) {
        print STDERR "\nSHADER DRIFT vs bundle-lock.json (" . scalar(@drift) . "): "
            . join(', ', @drift[0 .. (@drift > 8 ? 7 : $#drift)])
            . "\nRe-run with --update-lock to accept.\n";
        exit 1;
    }
    my $stateful_revision = _preserve_stateful($bundle, $old_bundle);
    my $new_lock = {
        source  => $Math::Fractal::Noisemaker::Transpiler::CDN::CDN_BASE,
        version => $Math::Fractal::Noisemaker::Transpiler::CDN::CDN_VERSION,
        hashes  => \%hashes,
    };
    $new_lock->{statefulRevision} = $stateful_revision if defined $stateful_revision;
    _write_raw($metadata_path, $_JSON_PRETTY->encode($bundle));
    _write_raw($lock_path, $_JSON_PRETTY->encode($new_lock));
    printf "wrote %d effect(s) (%d programs, %d skipped) from CDN %s\n",
        scalar(keys %{ $bundle->{effects} }), $n_ok, $n_skip,
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
