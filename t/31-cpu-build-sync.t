use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Digest::SHA qw(sha256_hex);
use Encode qw(encode);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json decode_json);

use Math::Fractal::Noisemaker::KernelCache ();
use Math::Fractal::Noisemaker::PassRunner ();
use Math::Fractal::Noisemaker::Runtime;
use Math::Fractal::Noisemaker::Transpiler::Codegen qw(emit_perl);
use Math::Fractal::Noisemaker::Transpiler::Parser qw(parse);
use Math::Fractal::Noisemaker::Transpiler::Preprocess qw(normalize);
use Math::Fractal::Noisemaker::Transpiler::Build qw(build);
use Math::Fractal::Noisemaker::Transpiler::CDN ();

sub render_probe {
    my ($key, $source, $uniforms) = @_;
    my ($effect) = split /:/, $key;
    my $norm = normalize($source, {}, $key);
    my $kernel = Math::Fractal::Noisemaker::KernelCache::load_kernel(
        emit_perl(parse($norm->{source}), $norm->{outputs}, $norm->{varyings}, $effect), $key);
    my $ctx = Math::Fractal::Noisemaker::Ctx->new(
        rt => Math::Fractal::Noisemaker::Runtime->new, uniforms => $uniforms || {});
    return Math::Fractal::Noisemaker::PassRunner::run_pass($kernel->{kernel}, $ctx, 1, 1)->data;
}

my $scatter = <<'GLSL';
uniform int seed;
out vec4 fragColor;
vec2 hash22(vec2 p) { return p; }
void main() {
    vec2 hashCoord = vec2(512.5, 15.5);
    vec2 rnd = hash22(hashCoord + float(seed) * 101.7);
    fragColor = vec4(rnd, 0.0, 1.0);
}
GLSL
is_deeply(render_probe('filter/scatter:scatterJitter', $scatter, {seed => 7}),
    [1224.39990234375, 727.3999633789062, 0, 1], 'scatter rounds seed before the coordinate add');
is_deeply(render_probe('filter/scatter:scatterJitter', $scatter, {seed => 16777217}),
    [1706243456, 1706242944, 0, 1], 'scatter retains integer seed precision until the product is rounded');

my $scatter_hash = <<'GLSL';
uniform int seed;
out vec4 fragColor;
float hash21(vec2 p) {
    vec3 p3 = vec3(123.456, 17.789, 34.567);
    return fract((p3.x + p3.y) * p3.z);
}
vec2 hash22(vec2 p) {
    vec3 p3 = vec3(123.456, 17.789, 34.567);
    return fract((p3.xx + p3.yz) * p3.zy);
}
void main() {
    vec2 hashCoord = vec2(0.5);
    vec2 rnd = hash22(hashCoord + float(seed) * 101.7);
    fragColor = vec4(hash21(hashCoord), rnd, 1.0);
}
GLSL
is_deeply(render_probe('filter/scatter:scatterJitter', $scatter_hash, {seed => 7}),
    [0.416015625, 0.416015625, 0.0712890625, 1],
    'scatter uses the common scalar and vector hash float32 boundaries');

my $navier = <<'GLSL';
uniform float x;
out vec4 fragColor;
float hash11(float x) {
    return fract(sin(x * 12.9898) * 43758.5453);
}
void main() { fragColor = vec4(hash11(x)); }
GLSL
is_deeply(render_probe('synth/navierStokes:nsSplat', $navier, {x => 31.37}),
    [(0.484375) x 4], 'Navier-Stokes hash rounds before fract');

my $mirror = <<'GLSL';
uniform float x;
out vec4 fragColor;
void main() { fragColor = vec4(mod(x + 1.0, 2.0) - 1.0); }
GLSL
my $small = unpack('f', pack('f', 1.0e-8));
is_deeply(render_probe('filter/reverb:reverb', $mirror, {x => 1.0e-8}),
    [($small) x 4], 'mirror wrap retains small coordinates');

my $extrude = <<'GLSL';
uniform float h;
uniform float depth;
out vec4 fragColor;
void main() {
    vec2 P = vec2(20.5);
    vec2 imgCenter = vec2(20.5);
    vec2 cellC = vec2(20.0);
    vec2 faceHalf = vec2(0.5000001);
    float s = 1.0 + h * (depth / 100.0) * 0.4;
    vec2 faceCenter = imgCenter + (cellC - imgCenter) * s;
    bool topHit = all(lessThanEqual(abs(P - faceCenter), faceHalf));
    fragColor = vec4(topHit ? 1.0 : 0.0);
}
GLSL
is_deeply(render_probe('filter/extrude:extrude', $extrude, {h => 1.0e-6, depth => 100}),
    [(0) x 4], 'extrude tests faces relative to the odd image center');

sub lattice_source {
    my ($width) = @_;
    my $type = "vec$width";
    my $hash = "hash$width";
    my $grad = "grad$width";
    my @axes = (split //, 'xyzw')[0 .. $width - 1];
    my $coordinate = $width == 4 ? 'vec4 ps = p + float(seed) * 0.1;'
        : "// Add seed to input to vary the noise pattern\n    p = p + float(seed) * 0.1;";
    my $point = $width == 4 ? 'ps' : 'p';
    my $mixes = join "\n", map {
        "q.$axes[$_] += q.$axes[($_ + 1) % $width] * q.$axes[($_ + 2) % $width];"
    } 0 .. $width - 1;
    my @hashes = ("float h1 = $hash(p);", "float h2 = $hash(p + 127.1);", "float h3 = $hash(p + 269.5);");
    push @hashes, "float h4 = $hash(p + 419.2);" if $width == 4;
    my $gradient_comment = $width == 3 ? "    // Generate 3 independent random values\n" : '';
    my $hashes = join "\n    ", @hashes;
    my $xor = join ' ^ ', map { "q.$_" } @axes;
    my $gradient = join ', ', map { "h$_ * 2.0 - 1.0" } 1 .. $width;
    my @corners;
    for my $i (0 .. (1 << $width) - 1) {
        my @offset = ((map { ($i >> $_) & 1 } 0 .. $width - 2), 0);
        my $z = $width == 4 ? 'iw' . ($i >> 3) : 'iz' . ($i >> 2);
        my $base = $width == 4 ? "vec4(i.xyz, $z)" : "vec3(i.xy, $z)";
        push @corners, "$type c$i = $grad($base + $type(" . join(',', @offset) . '));';
    }
    my $corners = join "\n    ", @corners;
    my $initial = join ',', 1 .. $width;
    my $output = $width == 4 ? 'c5' : 'vec4(c1, 1.0)';
    return <<GLSL;
uniform int seed;
out vec4 fragColor;
float $hash($type p) {
    $coordinate
    uvec$width q = uvec$width(ivec$width($point * 1000.0) + 65536);
    q = q * 1664525u + 1013904223u;
    $mixes
    q ^= q >> 16u;
    $mixes
    return float($xor) / 4294967295.0;
}
$type $grad($type p) {
$gradient_comment    $hashes
    return normalize($type($gradient));
}
void main() {
    $type i = $type($initial);
    float iw0 = 4.0; float iw1 = 5.0;
    float iz0 = 3.0; float iz1 = 4.0;
    $corners
    fragColor = $output;
}
GLSL
}

is_deeply(render_probe('synth3d/noise3d:precompute', lattice_source(4), {seed => 7}),
    [-0.5453212261199951, -0.45528578758239746, 0.10396884381771088, -0.6960818767547607],
    'noise3d adds lattice constants before seed and coordinate');
is_deeply(render_probe('synth/perlin:perlin', lattice_source(3), {seed => 7}),
    [0.5799109935760498, -0.43625524640083313, 0.6880294680595398, 1],
    'Perlin 3D adds seed before the uniform z constant');

my $cell = <<'GLSL';
uniform int seed;
out vec4 fragColor;
vec3 hash3(vec3 p) {
    p = p + float(seed) * 0.1;
    uvec3 q = uvec3(ivec3(p * 1000.0) + 65536);
    q = pcg3d(q);
    return vec3(q) / 4294967295.0;
}
void main() {
    vec3 i = vec3(1,2,3);
    vec3 neighbor = vec3(-1,0,1);
    vec3 cellPos = i + neighbor;
    vec3 randomOffset = hash3(cellPos);
    vec3 f = vec3(0.0);
    float jitter = 1.0;
    vec3 cellPoint = neighbor + mix(vec3(0.5), randomOffset, jitter);
    vec3 diff = cellPoint - f;
    fragColor = vec4(randomOffset, 1.0);
}
GLSL
is_deeply(render_probe('synth3d/cell3d:precompute', $cell, {seed => 2}),
    [0.8656628727912903, 0.4862741231918335, 0.6762023568153381, 1],
    'cell3d preserves different x and yz seed addition orders');

my $simulation = <<'GLSL';
uniform int seed;
out vec4 fragColor;
float hash3(vec3 p) {
    p = p + float(seed) * 0.1;
    p = fract(p * vec3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return fract((p.x + p.y) * p.z);
}
void main() { fragColor = vec4(hash3(vec3(31,17,5))); }
GLSL
for my $effect (qw(synth3d/reactionDiffusion3d synth3d/cellularAutomata3d)) {
    is_deeply(render_probe("$effect:simulate", $simulation, {seed => 7}), [(0.8681640625) x 4],
        "$effect groups the dot terms before fract");
}

sub write_fixture {
    my ($path, $text) = @_;
    open my $fh, '>:raw', $path or die "$path: $!";
    print {$fh} $text or die "$path: $!";
    close $fh or die "$path: $!";
}

sub read_fixture {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "$path: $!";
    local $/;
    return scalar <$fh>;
}

subtest 'authored stateful metadata retains its newly compiled kernel' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/kernels/perl");
    my $shader = "// canonical GLSL \x{2014} C\x{B9} 3\x{D7}3 `source` " . '\\\\u2014'
        . "\nout vec4 fragColor;\nvoid main() { fragColor = vec4(0.25); }";
    my $stateless_shader = '// transport literal \u2014 remains locked as extracted'
        . "\n#ifndef CW\n#define CW 41\n#endif\nout vec4 fragColor;\n"
        . "void main() { int a=1; int x=a/CW; fragColor=vec4(float(x)); }";
    my $stateful = {
        namespace => 'synth', func => 'reactionDiffusion', kind => 'generator',
        domain => 'image', iterated => JSON::PP::true,
        params => { iterationCount => {type => 'int', default => 4} },
        paramOrder => ['iterationCount'], textures => { state => { width => 16 } },
        passes => [{ program => 'authoredLabel', key => 'synth/reactionDiffusion:stateStep',
            repeat => 'iterationCount', inputs => {inputTex => 'state'}, outputs => {fragColor => 'state'},
            conditions => {runIf => [{uniform => 'enabled', equals => 1}]} },
            {program => 'native', drawMode => 'points', key => undef}],
    };
    my $hashes = {'synth/reactionDiffusion:stateStep' => sha256_hex(encode('UTF-8', $shader))};
    write_fixture("$dir/metadata.json", encode_json({
        provenance => {statefulRevision => $Math::Fractal::Noisemaker::Transpiler::Build::STATEFUL_REVISION},
        effects => {'synth/reactionDiffusion' => $stateful},
    }));
    write_fixture("$dir/bundle-lock.json", encode_json({hashes => $hashes}));
    write_fixture("$dir/kernels/perl/synth__reactionDiffusion__stateStep.pl",
        '+{kernel => sub { my ($ctx, $out) = @_; @$out = (0.75) x 4 }, uses_derivatives => 0}');
    my @fetched;
    no warnings 'redefine';
    local *Math::Fractal::Noisemaker::Transpiler::Build::fetch_effect = sub {
        my ($id) = @_;
        push @fetched, $id;
        (my $escaped = $shader) =~ s/\x{2014}/\\u2014/g;
        $escaped =~ s/\x{B9}/\\xB9/g;
        $escaped =~ s/\x{D7}/\\xD7/g;
        $escaped =~ s/`/\\`/g;
        my $cdn = 'stateStep:{glsl:`' . $escaped . '`},unused:{glsl:`invalid GLSL {`}';
        my $programs = Math::Fractal::Noisemaker::Transpiler::CDN::_extract_programs(\$cdn);
        return {namespace => 'synth', func => 'fixture',
            params => $id eq 'synth/reactionDiffusion' ? {}
                : {cellWidth => {type => 'int', define => 'CW', default => 41}}, textures => {},
            passes => [{program => $id eq 'synth/reactionDiffusion' ? 'unused' : 'main'}],
            programs => $id eq 'synth/reactionDiffusion'
                ? $programs : {main => $stateless_shader}};
    };
    build(['synth/fixture'], out_dir => $dir);
    is_deeply(\@fetched, ['synth/fixture', 'synth/reactionDiffusion'],
        'a subset build also fetches the preserved authored stateful kernel');
    my $meta = decode_json(read_fixture("$dir/metadata.json"));
    is_deeply($meta->{effects}{'synth/reactionDiffusion'}, $stateful,
        'authored pass scheduling, bindings, params, and textures stay intact');
    my $kernel = Math::Fractal::Noisemaker::KernelCache::load_kernel(
        read_fixture("$dir/kernels/perl/synth__reactionDiffusion__stateStep.pl"), 'rebuilt authored fixture');
    my @pixel;
    $kernel->{kernel}->(Math::Fractal::Noisemaker::Ctx->new(
        rt => Math::Fractal::Noisemaker::Runtime->new), \@pixel);
    is_deeply(\@pixel, [(0.25) x 4], 'the preserved pass executes the recompiled shader');
    my $defined_kernel = Math::Fractal::Noisemaker::KernelCache::load_kernel(
        read_fixture("$dir/kernels/perl/synth__fixture__main.pl"), 'runtime define fixture');
    $defined_kernel->{kernel}->(Math::Fractal::Noisemaker::Ctx->new(
        rt => Math::Fractal::Noisemaker::Runtime->new, uniforms => {CW => 41}), \@pixel);
    is_deeply([unpack('L<*', pack('f<*', @pixel))], [(1019727372) x 4],
        'a synthetic runtime define does not gain raw integer-name evidence during the build');
    my $lock = decode_json(read_fixture("$dir/bundle-lock.json"));
    is($lock->{hashes}{'synth/reactionDiffusion:stateStep'}, $hashes->{'synth/reactionDiffusion:stateStep'},
        'fresh CDN template extraction reproduces the existing authored raw GLSL hash');
    is($lock->{hashes}{'synth/fixture:main'}, sha256_hex(encode('UTF-8', $stateless_shader)),
        'stateless template escapes retain their existing hash convention');
    ok(!-e "$dir/kernels/perl/synth__reactionDiffusion__unused.pl",
        'unreferenced CDN programs are not compiled');

    my $before = read_fixture("$dir/kernels/perl/synth__reactionDiffusion__stateStep.pl");
    $shader =~ s/0\.25/0.5/;
    my $accepted = eval { build(['synth/fixture'], out_dir => $dir, update_lock => 1); 1 };
    ok(!$accepted, 'authored source drift is rejected even when ordinary lock updates are requested');
    like($@, qr/authored.*(?:hash|drift)/i, 'the rejection identifies the authored source hash');
    is(read_fixture("$dir/kernels/perl/synth__reactionDiffusion__stateStep.pl"), $before,
        'rejected authored drift leaves the installed kernel intact');
};

done_testing();
