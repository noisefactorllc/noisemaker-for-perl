use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Path qw(make_path);
use File::Spec;
use File::Temp ();
use JSON::PP ();

my $bundle = File::Temp::tempdir(CLEANUP => 1);
my $kernel_dir = File::Spec->catdir($bundle, 'kernels', 'perl');
make_path($kernel_dir);
$ENV{NOISEMAKER_BUNDLE} = $bundle;

sub write_raw {
    my ($path, $text) = @_;
    open my $fh, '>:raw', $path or die "cannot write $path: $!";
    print {$fh} $text;
    close $fh;
}

sub write_kernel {
    my ($key, $body, $outputs) = @_;
    (my $file = $key) =~ s{[/:]}{__}g;
    my $names = join(', ', map { "'$_'" } @{ $outputs || ['fragColor'] });
    write_raw(
        File::Spec->catfile($kernel_dir, "$file.pl"),
        "use strict; use warnings; no warnings qw(uninitialized);\n"
            . 'my $kernel = sub { my ($ctx, $out) = @_; ' . $body . " };\n"
            . '{ kernel => $kernel, uses_derivatives => 0, output_names => [' . $names . "] };\n",
    );
}

write_kernel('synth/fill:fill', q{
    my $u = $ctx->uniforms;
    @$out = ($u->{value}, 0, 0, 1);
});
write_kernel('synth/iterSchedule:schedule', q{
    my $u = $ctx->uniforms;
    my $surface = $ctx->texture_binding('selfTexInput');
    my $x = int($ctx->frag_coord->[0]);
    my $shader_y = int($ctx->frag_coord->[1]);
    my $row = $surface->height - 1 - $shader_y;
    my $offset = ($row * $surface->width + $x) * 4;
    @$out = (($surface->data->[$offset] || 0) + 1 / 16, $u->{frame}, $u->{time}, $u->{deltaTime});
});
write_kernel('filter/iterZero:add', q{
    my $surface = $ctx->texture_binding('inputTex');
    my $x = int($ctx->frag_coord->[0]);
    my $shader_y = int($ctx->frag_coord->[1]);
    my $row = $surface->height - 1 - $shader_y;
    my $offset = ($row * $surface->width + $x) * 4;
    @$out = ($surface->data->[$offset] + 0.1, 0, 0, 1);
});
write_kernel('render/pointsEmit:move', q{
    my $surface = $ctx->texture_binding('xyzTex');
    my $x = int($ctx->frag_coord->[0]);
    my $shader_y = int($ctx->frag_coord->[1]);
    my $row = $surface->height - 1 - $shader_y;
    my $offset = ($row * $surface->width + $x) * 4;
    @$out = (($surface->data->[$offset] || 0) + 1, 0, 0, 1);
});
write_kernel('render/pointsEmit:pass', q{ @$out = (0, 0, 0, 1); });
write_kernel('points/testDeposit:deposit', q{
    my $xyz = $ctx->texture_binding('xyzTex');
    my $trail = $ctx->texture_binding('trailTex');
    my $x = int($ctx->frag_coord->[0]);
    my $shader_y = int($ctx->frag_coord->[1]);
    my $row = $xyz->height - 1 - $shader_y;
    my $offset = ($row * $xyz->width + $x) * 4;
    @$out = (($trail->data->[$offset] || 0) + ($xyz->data->[$offset] || 0), 0, 0, 1);
});
write_kernel('points/testDeposit:pass', q{
    my $surface = $ctx->texture_binding('trailTex');
    my $x = int($ctx->frag_coord->[0]);
    my $shader_y = int($ctx->frag_coord->[1]);
    my $row = $surface->height - 1 - $shader_y;
    my $offset = ($row * $surface->width + $x) * 4;
    @$out = @{ $surface->data }[$offset .. $offset + 3];
});
write_kernel('points/testMrt:mrt', q{
    my $xyz = $ctx->texture_binding('xyzTex');
    my $vel = $ctx->texture_binding('velTex');
    my $x = int($ctx->frag_coord->[0]);
    my $shader_y = int($ctx->frag_coord->[1]);
    my $row = $xyz->height - 1 - $shader_y;
    my $offset = ($row * $xyz->width + $x) * 4;
    @$out = (
        ($xyz->data->[$offset] || 0) + 1, 0, 0, 1,
        ($vel->data->[$offset] || 0) + 10, 0, 0, 1,
    );
}, ['outXYZ', 'outVel']);
write_kernel('points/testMrt:combine', q{
    my $xyz = $ctx->texture_binding('xyzTex');
    my $vel = $ctx->texture_binding('velTex');
    my $x = int($ctx->frag_coord->[0]);
    my $shader_y = int($ctx->frag_coord->[1]);
    my $row = $xyz->height - 1 - $shader_y;
    my $offset = ($row * $xyz->width + $x) * 4;
    @$out = ($xyz->data->[$offset], $vel->data->[$offset], 0, 1);
});
write_kernel('synth/optionalSurface:first', q{ @$out = (0.75, 0.5, 0.25, 1); });
write_kernel('synth/optionalSurface:sample', q{
    my $surface = $ctx->texture_binding('tex');
    @$out = @{ $surface->data }[0 .. 3];
});
write_kernel('synth/missingResource:first', q{ @$out = (0.75, 0.5, 0.25, 1); });
write_kernel('synth/missingResource:sample', q{ @$out = (1, 1, 1, 1); });

sub int_param {
    my ($default, $uniform) = @_;
    return { type => 'int', default => $default, (defined $uniform ? (uniform => $uniform) : ()) };
}

my $state_texture = {
    width => { param => 'stateSize', default => 1 },
    height => { param => 'stateSize', default => 1 },
    format => 'rgba32f',
};
my $screen_texture = { width => 'screen', height => 'screen', format => 'rgba32f' };
my $metadata = {
    effects => {
        'synth/fill' => {
            namespace => 'synth', func => 'fill', kind => 'generator',
            params => { value => { type => 'float', default => 0, uniform => 'value' } },
            paramOrder => ['value'], textures => { outputTex => $screen_texture },
            passes => [{ name => 'fill', program => 'fill', key => 'synth/fill:fill', inputs => {}, outputs => { fragColor => 'outputTex' } }],
        },
        'synth/iterSchedule' => {
            namespace => 'synth', func => 'iterSchedule', kind => 'generator', iterated => 1,
            params => { iterationCount => int_param(60) }, paramOrder => ['iterationCount'],
            textures => { outputTex => $screen_texture },
            passes => [{ name => 'schedule', program => 'schedule', key => 'synth/iterSchedule:schedule', inputs => { selfTexInput => 'selfTex' }, outputs => { fragColor => 'outputTex' } }],
        },
        'filter/iterZero' => {
            namespace => 'filter', func => 'iterZero', kind => 'filter', iterated => 1,
            params => { iterationCount => int_param(60) }, paramOrder => ['iterationCount'],
            textures => { outputTex => $screen_texture },
            passes => [{ name => 'add', program => 'add', key => 'filter/iterZero:add', inputs => { inputTex => 'inputTex' }, outputs => { fragColor => 'outputTex' } }],
        },
        'render/pointsEmit' => {
            namespace => 'render', func => 'pointsEmit', kind => 'generator', iterated => 1,
            params => { stateSize => int_param(1, 'stateSize'), iterationCount => int_param(60) },
            paramOrder => ['stateSize', 'iterationCount'],
            textures => { global_xyz => $state_texture, outputTex => $screen_texture },
            passes => [
                { name => 'move', program => 'move', key => 'render/pointsEmit:move', inputs => { xyzTex => 'global_xyz' }, outputs => { fragColor => 'global_xyz' } },
                { name => 'pass', program => 'pass', key => 'render/pointsEmit:pass', inputs => {}, outputs => { fragColor => 'outputTex' } },
            ],
        },
        'points/testDeposit' => {
            namespace => 'points', func => 'testDeposit', kind => 'filter', iterated => 1,
            params => { stateSize => int_param(1, 'stateSize'), iterationCount => int_param(60) },
            paramOrder => ['stateSize', 'iterationCount'],
            textures => { global_test_trail => $state_texture, outputTex => $screen_texture },
            passes => [
                { name => 'deposit', program => 'deposit', key => 'points/testDeposit:deposit', inputs => { xyzTex => 'global_xyz', trailTex => 'global_test_trail' }, outputs => { fragColor => 'global_test_trail' } },
                { name => 'pass', program => 'pass', key => 'points/testDeposit:pass', inputs => { trailTex => 'global_test_trail' }, outputs => { fragColor => 'outputTex' } },
            ],
        },
        'points/testMrt' => {
            namespace => 'points', func => 'testMrt', kind => 'generator', iterated => 1,
            params => { stateSize => int_param(1, 'stateSize'), iterationCount => int_param(60) },
            paramOrder => ['stateSize', 'iterationCount'],
            textures => { global_xyz => $state_texture, global_vel => $state_texture, outputTex => $screen_texture },
            passes => [
                { name => 'mrt', program => 'mrt', key => 'points/testMrt:mrt', drawBuffers => 2,
                  inputs => { xyzTex => 'global_xyz', velTex => 'global_vel' }, outputs => { outXYZ => 'global_xyz', outVel => 'global_vel' } },
                { name => 'combine', program => 'combine', key => 'points/testMrt:combine',
                  inputs => { xyzTex => 'global_xyz', velTex => 'global_vel' }, outputs => { fragColor => 'outputTex' } },
            ],
        },
        'synth/optionalSurface' => {
            namespace => 'synth', func => 'optionalSurface', kind => 'generator',
            params => { tex => { type => 'surface', default => 'none' } },
            paramOrder => ['tex'], textures => { scratchTex => $screen_texture, outputTex => $screen_texture },
            passes => [
                { name => 'first', program => 'first', key => 'synth/optionalSurface:first',
                  inputs => {}, outputs => { fragColor => 'scratchTex' } },
                { name => 'sample', program => 'sample', key => 'synth/optionalSurface:sample',
                  inputs => { tex => 'tex' }, outputs => { fragColor => 'outputTex' } },
            ],
        },
        'synth/missingResource' => {
            namespace => 'synth', func => 'missingResource', kind => 'generator',
            params => {}, paramOrder => [], textures => { scratchTex => $screen_texture, outputTex => $screen_texture },
            passes => [
                { name => 'first', program => 'first', key => 'synth/missingResource:first',
                  inputs => {}, outputs => { fragColor => 'scratchTex' } },
                { name => 'sample', program => 'sample', key => 'synth/missingResource:sample',
                  inputs => { tex => 'missingTex' }, outputs => { fragColor => 'outputTex' } },
            ],
        },
    },
};
write_raw(File::Spec->catfile($bundle, 'metadata.json'), JSON::PP->new->canonical->encode($metadata));

use Math::Fractal::Noisemaker::Renderer qw(render_dsl);

sub close_to {
    my ($got, $want, $name) = @_;
    cmp_ok(abs($got - $want), '<=', 1e-6, $name) or diag("got=$got want=$want");
}

{
    my $surface = render_dsl(
        "search synth\niterSchedule(iterationCount: 4).write(o0)\nrender(o0)",
        width => 1, height => 1, time => 0.5,
    );
    close_to($surface->data->[0], 4 / 16, 'iterated selfTex accumulates once per iteration');
    is($surface->data->[1], 3, 'frame is final iteration index');
    close_to($surface->data->[2], 0.5, 'final iteration lands on render time');
    close_to($surface->data->[3], 1 / 600, 'deltaTime is fixed simulation step');
}

{
    my $surface = render_dsl(
        "search synth, filter\nfill(value: 0.4).iterZero(iterationCount: 0).write(o0)\nrender(o0)",
        width => 1, height => 1,
    );
    close_to($surface->data->[0], 0.4, 'zero-iteration filter returns its input unchanged');
}

{
    my $surface = render_dsl(
        "search render, points\npointsEmit(stateSize: 1, iterationCount: 4).testDeposit().write(o0)\nrender(o0)",
        width => 1, height => 1,
    );
    close_to($surface->data->[0], 10, 'particle group interleaves move and deposit each iteration');
}

{
    my $surface = render_dsl(
        "search points\ntestMrt(stateSize: 1, iterationCount: 3).write(o0)\nrender(o0)",
        width => 1, height => 1,
    );
    close_to($surface->data->[0], 3, 'MRT xyz output persists across iterations');
    close_to($surface->data->[1], 30, 'MRT velocity output persists independently');
}

{
    my $surface = render_dsl(
        "search synth\noptionalSurface().write(o0)\nrender(o0)",
        width => 1, height => 1,
    );
    is_deeply(
        $surface->data,
        [0, 0, 0, 0],
        'an omitted nullable surface samples the canonical zero surface instead of the previous pass',
    );
}

{
    my $ok = eval {
        render_dsl("search synth\nmissingResource().write(o0)\nrender(o0)", width => 1, height => 1);
        1;
    };
    ok(!$ok, 'an undeclared named pass resource is rejected');
    like($@, qr/requires texture "missingTex"/, 'missing-resource error names the required texture');
}

done_testing();
