use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../scripts";
use File::Spec;
use Math::Fractal::Noisemaker::ExternalInput qw(
    parse_obj pack_mesh_data_for_textures flip_rgba_rows external_data_surface
);
use Math::Fractal::Noisemaker::MeshRender;
use Math::Fractal::Noisemaker::Renderer qw(render_effect render_dsl);
use ReactiveFixtures qw(%EXTERNAL_INPUT_SOURCES external_inputs_for);

sub f32 { unpack('f', pack('f', $_[0])) }

my $CUBE_OBJ = join "\n",
    'v -0.7 -0.7 -0.7', 'v 0.7 -0.7 -0.7', 'v 0.7 0.7 -0.7', 'v -0.7 0.7 -0.7',
    'v -0.7 -0.7 0.7', 'v 0.7 -0.7 0.7', 'v 0.7 0.7 0.7', 'v -0.7 0.7 0.7',
    'vn 0 0 -1', 'vn 0 0 1', 'vn 0 -1 0', 'vn 0 1 0', 'vn -1 0 0', 'vn 1 0 0',
    'f 1//1 2//1 3//1 4//1', 'f 5//2 8//2 7//2 6//2', 'f 1//3 5//3 6//3 2//3',
    'f 2//4 6//4 7//4 3//4', 'f 3//5 7//5 8//5 4//5', 'f 4//6 8//6 5//6 1//6',
    '';

subtest 'MIDI state routes notes, clock and the note grid' => sub {
    my $midi = Math::Fractal::Noisemaker::ExternalInput::MidiState->new;
    $midi->handle_message($_)
        for [0x90, 60, 100], [0x90, 64, 80], [0x90, 67, 90], [0x91, 48, 64], map { [0xf8] } 1 .. 24;
    $midi->update_note_grid;
    is($midi->clock_count, 24, 'clock pulses count');
    my $ch1 = $midi->get_channel(1);
    is($ch1->{gate}, 1, 'channel 1 gate is open');
    is_deeply([@{ $ch1->{keys} }[60, 64, 67]], [100, 80, 90], 'channel 1 triad velocities');
    is($midi->get_channel(2)->{keys}[48], 64, 'channel 2 low C');
    is($midi->get_channel(3)->{gate}, 0, 'an untouched channel stays closed');
    is($midi->note_grid->[60 * 4], f32(100 / 127), 'grid R holds the f32 velocity');
    is_deeply([@{ $midi->note_grid }[60 * 4 + 1 .. 60 * 4 + 3]], [1, 0, 0], 'grid G is the gate; B and A stay 0');
    is($midi->note_grid->[128 * 4 + 48 * 4 + 1], 1, 'row 1 of the grid is channel 2');
    is($midi->handle_message([0xf0, 1]), -1, 'system messages are not routed');
    $midi->handle_message([0x80, 60, 0]);
    is($ch1->{gate}, 0, 'note off closes the gate');
    is($ch1->{keys}[60], 0, 'note off clears the key');
};

subtest 'MIDI byte validation follows the reference' => sub {
    my $midi = Math::Fractal::Noisemaker::ExternalInput::MidiState->new;
    is($midi->handle_message([0xC0, 5, 0]), 0, 'a three-byte program change routes');
    is($midi->get_channel(1)->{program}, 5, 'the program rides the first data byte');
    is($midi->handle_message([0xC0, 7]), -1, 'a two-byte program change fails the shared validation');
    is($midi->get_channel(1)->{program}, 5, 'the rejected message changes nothing');
    is($midi->handle_message([0xD0, 64]), 0, 'channel pressure skips the second-byte check');
    is($midi->get_channel(1)->{pressure}, 64, 'channel pressure is stored');
    is($midi->handle_message([0x90, 128, 1]), -1, 'a key above 127 is rejected');
    $midi->handle_message([0xff]);
    is($midi->get_channel(1)->{program}, 0, 'system reset clears every channel');
};

subtest 'audio state stores f32 arrays of 128' => sub {
    my $audio = Math::Fractal::Noisemaker::ExternalInput::AudioState->new;
    is_deeply($audio->waveform, [(0) x 128], 'a fresh waveform is zeros');
    $audio->set_waveform([map { 0.1 * ($_ % 10) } 0 .. 127]);
    is($audio->waveform->[3], f32(0.3), 'waveform values are stored f32');
    eval { $audio->set_waveform([(0.5) x 127]) };
    like($@, qr/exactly 128 samples/, 'a short waveform is rejected');
    eval { $audio->set_spectrum([(0.5) x 129]) };
    like($@, qr/exactly 128 bins/, 'a long spectrum is rejected');
};

subtest 'OBJ parsing fan-triangulates with reversed winding' => sub {
    my $parsed = parse_obj($CUBE_OBJ);
    is($parsed->{vertexCount}, 36, 'six quads become twelve triangles');
    is_deeply([@{ $parsed->{positions} }[0 .. 2]], [map { f32($_) } -0.7, -0.7, -0.7], 'first corner');
    is_deeply([@{ $parsed->{positions} }[3 .. 5]], [map { f32($_) } 0.7, 0.7, -0.7], 'then the third vertex');
    is_deeply([@{ $parsed->{positions} }[6 .. 8]], [map { f32($_) } 0.7, -0.7, -0.7], 'then the second');
    is_deeply([@{ $parsed->{normals} }[0 .. 2]], [0, 0, -1], 'vn references set the normal');
    is_deeply([@{ $parsed->{normals} }[18 .. 20]], [0, 0, 1], 'the second face uses vn 2');
    my $flat = parse_obj("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n");
    is($flat->{vertexCount}, 3, 'one triangle');
    is($flat->{normals}[2], -1, 'without vn, the reversed winding gives a -z smooth normal');
};

subtest 'mesh packing marks valid vertices' => sub {
    my $parsed = parse_obj($CUBE_OBJ);
    my $packed = pack_mesh_data_for_textures(@$parsed{qw(positions normals uvs)}, 256, 256);
    is(scalar @{ $packed->{positionData} }, 256 * 256 * 4, 'one RGBA texel per possible vertex');
    is($packed->{vertexCount}, 36, 'all vertices fit');
    is($packed->{positionData}[3], 1, 'position w = 1 marks a valid vertex');
    is($packed->{positionData}[36 * 4 + 3], 0, 'the remaining texels keep w = 0');
};

subtest 'data textures store the uploaded rows reversed' => sub {
    my @data = map { 0 + $_ } 0 .. 15;    # 2 x 2 texels
    my $flipped = flip_rgba_rows(\@data, 2, 2);
    is_deeply([@$flipped[0 .. 7]], [@data[8 .. 15]], 'surface row 0 is the uploaded bottom row');
    is_deeply([@$flipped[8 .. 15]], [@data[0 .. 7]], 'and the last row the uploaded first');
    my $surface = external_data_surface([0 .. 7], 1, 2);
    is($surface->filter, 'nearest', 'data textures sample nearest');
    is_deeply([$surface->width, $surface->height], [1, 2], 'with the uploaded dimensions');
};

subtest 'the renderer binds external inputs' => sub {
    my %size = (width => 4, height => 4, seed => 1, time => 0.25);
    my $quiet = render_effect('synth/scope', {}, undef, %size)->to_rgba8;
    is(length $quiet, 64, 'reactive effects render with zeroed inputs');
    my $loud = render_dsl($EXTERNAL_INPUT_SOURCES{'synth/scope'}, %size,
        external_inputs => external_inputs_for('synth/scope'))->to_rgba8;
    isnt($loud, $quiet, 'the audio fixture reaches the scope kernel');
    my $roll = render_dsl($EXTERNAL_INPUT_SOURCES{'synth/roll'}, %size,
        external_inputs => external_inputs_for('synth/roll'));
    is(length $roll->to_rgba8, 64, 'synth/roll renders with the MIDI fixture');
    eval { render_effect('render/meshRender', {}, undef, %size) };
    like($@, qr/requires external mesh data/, 'mesh effects require mesh data');
    my $mesh = render_dsl($EXTERNAL_INPUT_SOURCES{'render/meshRender'}, %size, width => 16, height => 16,
        external_inputs => external_inputs_for('render/meshRender'))->to_rgba8;
    my %colors = map { substr($mesh, $_ * 4, 4) => 1 } 0 .. 255;
    cmp_ok(scalar keys %colors, '>', 1, 'meshRender rasterizes the cube over its background');
    ok(Math::Fractal::Noisemaker::MeshRender::get_adapter('render/meshRender', 'render'),
        'the triangles pass dispatches to the mesh adapter');
    ok(!Math::Fractal::Noisemaker::MeshRender::get_adapter('render/meshRender', 'clear'),
        'the clear pass is an ordinary kernel');
};

subtest 'random effects never need external inputs' => sub {
    # Load bin/make-noise in a child perl with exit and rand overridden, so rand
    # walks every index of the generator pool once.
    my $script = File::Spec->catfile($FindBin::Bin, '..', 'bin', 'make-noise');
    my $probe = <<'PERL';
my $i = 0;
my $n;
BEGIN {
    *CORE::GLOBAL::exit = sub { die "exit\n" };
    *CORE::GLOBAL::rand = sub { $n = $_[0]; return $i++ % $_[0] };
}
my $script = shift;
{
    local @ARGV = ('--version');
    open my $null, '>', File::Spec->devnull;
    my $out = select $null;
    eval { do $script };
    select $out;
}
# The first pick learns the pool size; the rest walk its remaining indices.
my @picked = (main::_resolve_effect('random', 'generator'));
push @picked, main::_resolve_effect('random', 'generator') for 2 .. $n;
print join("\n", $n, @picked), "\n";
PERL
    my $lib = File::Spec->catdir($FindBin::Bin, '..', 'lib');
    my ($n, @picked) = split /\n/, run_perl_probe("use lib '$lib';\nuse File::Spec;\n$probe", $script);
    my %picked = map { $_ => 1 } @picked;
    ok($n && keys %picked == $n, "rand walked the whole $n-effect pool");
    ok($picked{'synth/solid'}, 'the pool holds ordinary generators');
    my @external = qw(synth/roll synth/scope synth/spectrum render/meshLoader render/meshRender);
    is_deeply([grep { $picked{$_} } @external], [], 'reactive and mesh effects stay out of the pool');
    # Without the exclusion the three reactive generators would qualify.
    my $effects = Math::Fractal::Noisemaker::Renderer::meta()->{effects};
    is_deeply([sort grep {
        ($effects->{$_}{kind} || '') eq 'generator' && ($effects->{$_}{domain} || 'image') eq 'image'
            && !$effects->{$_}{iterated} && !$effects->{$_}{externalTexture}
    } @external], [qw(synth/roll synth/scope synth/spectrum)], 'only the exclusion keeps them out');
};

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

done_testing();
