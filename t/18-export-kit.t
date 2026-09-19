use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use File::Spec;
use JSON::PP ();

my $config_path = File::Spec->catfile($FindBin::Bin, '..', 'export-kit', 'kit.config.json');
ok(-f $config_path, 'export-kit/kit.config.json exists');

open my $fh, '<', $config_path or die "Could not open $config_path: $!";
my $config_content = do { local $/; <$fh> };
close $fh;

my $config = JSON::PP::decode_json($config_content);
is($config->{id}, 'perl', 'export kit id is perl');
ok($config->{compat}, 'export kit configures compat');
is($config->{compat}{mode}, 'list', 'compat mode is list');

my $metadata_rel = $config->{compat}{fromBundleMetadata};
ok($metadata_rel, 'compat.fromBundleMetadata is configured');

my $metadata_path = File::Spec->catfile($FindBin::Bin, '..', $metadata_rel);
ok(-f $metadata_path, "$metadata_rel exists");

open my $mfh, '<', $metadata_path or die "Could not open $metadata_path: $!";
my $metadata_content = do { local $/; <$mfh> };
close $mfh;

my $metadata = JSON::PP::decode_json($metadata_content);
my $effects = $metadata->{effects};
ok($effects, 'metadata declares effects');
is(scalar(keys %$effects), 208, 'metadata exposes all 208 bundled effects');

my $bundle_lock_path = File::Spec->catfile($FindBin::Bin, '..', 'lib', 'Math', 'Fractal', 'Noisemaker', 'bundle', 'bundle-lock.json');
ok(-f $bundle_lock_path, 'bundle-lock.json exists');
open my $bfh, '<', $bundle_lock_path or die "Could not open $bundle_lock_path: $!";
my $bundle_lock_content = do { local $/; <$bfh> };
close $bfh;
my $bundle_lock = JSON::PP::decode_json($bundle_lock_content);
my $hashes = $bundle_lock->{hashes};
ok($hashes, 'bundle-lock declares hashes');
is(scalar(keys %$hashes), 292, 'bundle-lock.json locks all 292 program hashes');

done_testing();
