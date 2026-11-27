use strict;
use warnings;
use Test::More;
use Math::Fractal::Noisemaker::Renderer qw(meta render_dsl render_effect);
use Math::Fractal::Noisemaker::Surface;
use Math::Fractal::Noisemaker::Transpiler::ComputedDefs qw(%COMPUTED_DEFS);

my $definition = $COMPUTED_DEFS{'synth/remap'};
is(scalar keys %{$definition->{params}}, 292, 'all eight zones expose their geometry');
is($definition->{paramOrder}[-1], 'zone7_v31', 'last packed vertex pair is positional');
is_deeply($definition->{params}{zone7_bounds}{default}, [0, 0, 1, 1], 'default bounds cover the canvas');
is_deeply(meta()->{effects}{'synth/remap'}{params}, $definition->{params}, 'bundle matches the computed remap definition');

my $data = Math::Fractal::Noisemaker::Renderer::_remap_uniform_data({
    zone7_bounds => [0.60000000001, 0.2, 0.8, 1], zone7_v31 => [1, 2, 3, 4],
}, 19, 11);
is(scalar @$data, 275, 'complete std140 block');
is_deeply($data->[265], [1, 2, 3, 4], 'last vertex pair stays at slot 265');
is_deeply($data->[266], [19, 11, 0, 0], 'resolution stays at slot 266');
is_deeply($data->[267], [0, 0, 1, 1], 'first zone has default bounds');
is_deeply($data->[274], [unpack('f*', pack('f*', 0.60000000001, 0.2, 0.8, 1))], 'last zone bounds are float32 in std140');

for my $field ('bounds', 'vertices') {
    subtest "double precision $field at a pixel center" => sub {
        my $edge = '0.3750000001';
        my ($bound, $vertex) = $field eq 'bounds' ? ($edge, 0) : (0, $edge);
        my $dsl = <<"DSL";
search synth
solid(color: #f00).write(o1)
remap(zoneCount: 8, smoothEdge: 0, zone7_count: 4, zone7_tex: read(o1),
    zone7_bounds: [$bound, 0, 1, 1], zone7_v0: [$vertex, 0, 1, 0],
    zone7_v1: [1, 1, $vertex, 1]).write(o0)
render(o0)
DSL
        my $bytes = render_dsl($dsl, width => 4, height => 4)->to_rgba8;
        is_deeply([map { ord(substr($bytes, $_ * 4, 1)) } 0 .. 3], [0, 0, 255, 255], 'edge just beyond the center excludes that pixel');
    };
}

my $layered = <<'DSL';
search synth
solid(color: #00f).write(o1)
solid(color: #f00, alpha: 0.5).write(o2)
remap(bgColor: #0f0, bgAlpha: 0.25, zoneCount: 8, smoothEdge: 1,
    zone0_tex: read(o1), zone0_alpha: 0.5, zone0_count: 4, zone0_v0: [0,0,1,0], zone0_v1: [1,1,0,1],
    zone7_tex: read(o2), zone7_alpha: 0.5, zone7_count: 4, zone7_bounds: [0.5,0,1,1],
    zone7_v0: [0.5,0,1,0], zone7_v1: [1,1,0.5,1]).write(o0)
render(o0)
DSL
my $bytes = render_dsl($layered, width => 12, height => 12)->to_rgba8;
# RGBA8 from CPU 170d7ba, immediately outside, inside the feather, and inside the polygon.
is_deeply([unpack('C*', substr($bytes, (6 * 12 + 4) * 4, 12))],
    [0, 32, 128, 159, 5, 31, 125, 161, 64, 24, 96, 183], 'zone 7 feathers and composites over zone 0 and the background');

my $source = Math::Fractal::Noisemaker::Surface->new(2, 2, [
    1, 0, 0, 1,  0, 1, 0, 1,
    0, 0, 1, 1,  1, 1, 1, 1,
]);
my $surface = render_effect('synth/remap', {
    zoneCount => 8, smoothEdge => 0, zone7_count => 4,
    zone7_v0 => '0,0,1,0', zone7_v1 => [1, 1, 0, 1],
}, { zone7_tex => $source }, width => 1, height => 1);
is_deeply([unpack('C*', $surface->to_rgba8)], [0, 255, 0, 255],
    'public API accepts comma-separated vertices and samples the zone surface at its center');

done_testing;
