use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use POSIX ();
use Math::Fractal::Noisemaker::Adapters ();
use Math::Fractal::Noisemaker::KernelCache ();
use Math::Fractal::Noisemaker::PassRunner qw(run_pass);

# Source CPU 4aeb3e1e028b2dc412401f7b7f17c014c603bf14: direct factories,
# GlslCpuRuntime and procedural float32 RGBA input, without render quantization.
my @cases = (
    {name=>'crt-default',effect=>'crt',width=>8,height=>8,alpha=>1,seed=>1,time=>0.25,speed=>1},
    {name=>'crt-tiled',effect=>'crt',width=>8,height=>6,alpha=>0.7,seed=>5,time=>0.4,speed=>2.5,
     renderScale=>2,fullResolution=>[32,18],tileOffset=>[4,2]},
    {name=>'crt-still',effect=>'crt',width=>8,height=>6,alpha=>1,seed=>-2,time=>0,speed=>0},
    {name=>'crt-zero',effect=>'crt',width=>8,height=>6,alpha=>0,seed=>1,time=>0.25,speed=>1},
    {name=>'snow-quarter',effect=>'snow',width=>8,height=>8,alpha=>1,density=>100,time=>0.25},
    {name=>'snow-animated',effect=>'snow',width=>8,height=>6,alpha=>0.6,density=>75,time=>0.4},
    {name=>'snow-paused',effect=>'snow',width=>8,height=>6,alpha=>1,density=>100,time=>0.6,pause=>1},
    {name=>'snow-zero',effect=>'snow',width=>8,height=>6,alpha=>0,density=>100,time=>0.25},
);
sub f32 { unpack('f<', pack('f<', $_[0])) }
sub fixture {
    open my $fh, '<:raw', "$FindBin::Bin/data/cpu-adapter-sync/$_[0].f32" or die $!;
    local $/; return <$fh>;
}
sub context {
    my ($case, $rt) = @_;
    my ($w,$h) = @{$case}{qw(width height)};
    my $surface = Math::Fractal::Noisemaker::Surface->new($w,$h);
    for my $i (0..$w*$h-1) {
        my ($x,$y)=($i%$w,int($i/$w));
        @{$surface->data}[$i*4..$i*4+3]=map { f32($_) }
          (($x*3+$y*5)%31/31,($x*11+$y*7)%37/37,($x*17+$y*23)%41/41,($i%7)/7);
    }
    my %u=(resolution=>[$w,$h],fullResolution=>[0,0],tileOffset=>[0,0],renderScale=>1,
           seed=>1,speed=>1,pause=>0,%$case);
    $u{$_}=f32($u{$_}) for grep {exists $u{$_}} qw(alpha seed time speed density renderScale);
    return Math::Fractal::Noisemaker::Ctx->new(rt=>$rt,uniforms=>\%u,textures=>{inputTex=>$surface},
       resolution=>[$w,$h],time=>$case->{time},seed=>$case->{seed}//1);
}
sub kernel {
    my ($effect,$rt)=@_;
    my $path="$FindBin::Bin/../lib/Math/Fractal/Noisemaker/bundle/kernels/perl/filter__${effect}__${effect}.pl";
    open my $fh,'<:raw',$path or die $!; local $/;
    my $compiled=Math::Fractal::Noisemaker::KernelCache::load_kernel(<$fh>,$path);
    return Math::Fractal::Noisemaker::Adapters::get_adapter("filter/$effect",$effect)->($rt,$compiled);
}
for my $case (@cases) {
    subtest "$case->{name} raw CPU capture" => sub {
        my $rt=Math::Fractal::Noisemaker::Runtime->new;
        my $actual=run_pass(kernel($case->{effect},$rt),context($case,$rt),$case->{width},$case->{height});
        is_deeply([unpack('L<*',pack('f<*',@{$actual->data}))],[unpack('L<*',fixture($case->{name}))],
                  'all float32 lanes match');
    };
}
subtest 'CRT context reuse' => sub {
    my $rt=Math::Fractal::Noisemaker::Runtime->new;
    my $kernel=kernel('crt',$rt);
    for my $index (0,1,0) {
        my $case=$cases[$index];
        my $actual=run_pass($kernel,context($case,$rt),$case->{width},$case->{height});
        is_deeply([unpack('L<*',pack('f<*',@{$actual->data}))],[unpack('L<*',fixture($case->{name}))],$case->{name});
    }
};
subtest 'CRT FMA midpoint correction and signed zero' => sub {
    my $fma=Math::Fractal::Noisemaker::Adapters->can('_cfma32');
    ok($fma,'exact FMA is available'); return unless $fma;
    for my $case (
      [[1.1836352348327637,1.7818914651870728,-1.931027560075904e-9],1074199463],
      [[1.715787649154663,1.694210410118103,-3.285236749306364e-9],1077545661],
      [[1.5398544073104858,1.8304558992385864,-9.061266736942741e-10],1077175431],
      [[1,1.0000001192092896,5.960464477539063e-8],1065353218],
      [[3,0.3333333432674408,-1],855638016],
      [[-0.0,1.0,-0.0],2147483648],
      [[134217744,201326592,1],1522532354],
      [[134217744,201326592,-1],1522532353],
    ) {
        is(unpack('L<',pack('f<',$fma->(@{$case->[0]}))),$case->[1],'source FMA bits');
    }
};
subtest 'CRT width one propagates NaN and preserves alpha' => sub {
    for my $h (1,4) {
        my $rt=Math::Fractal::Noisemaker::Runtime->new;
        my $ctx=context({width=>1,height=>$h,alpha=>1,time=>0.25},$rt);
        my $actual=eval {run_pass(kernel('crt',$rt),$ctx,1,$h)};
        ok(!$@,"${h}-row render does not throw") or next;
        my @data=@{$actual->data};
        ok(!grep({!POSIX::isnan($data[$_])} grep {$_%4!=3} 0..$#data),'RGB is NaN');
        is_deeply([map {$data[$_*4+3]} 0..$h-1],
                  [map {$ctx->texture_binding('inputTex')->data->[$_*4+3]} 0..$h-1],'alpha unchanged');
    }
};
subtest 'adapter fetch uses source Int32 coercion' => sub {
    for my $effect ('crt','snow') {
        my $case=$effect eq 'crt'?$cases[0]:$cases[7];
        my $rt=Math::Fractal::Noisemaker::Runtime->new;
        my $kernel=kernel($effect,$rt);
        my @expected=unpack('f<*',fixture($case->{name}));
        my $offset=($case->{height}-1)*$case->{width}*4;
        my @expected_pixel=@expected[$offset..$offset+3];
        for my $x (2**32+0.5,-(2**32)-0.5,POSIX::nan(0),POSIX::HUGE_VAL(),-POSIX::HUGE_VAL()) {
            my $ctx=context($case,$rt);$ctx->{frag_coord}=[$x,0.5];$ctx->{uv}=[0.5/8,0.5/8];
            my $out=[(0)x4];my $ok=eval {$kernel->($ctx,$out);1};
            ok($ok,"$effect coordinate $x does not throw") or next;
            is_deeply([unpack('L<*',pack('f<*',@$out))],[unpack('L<*',pack('f<*',@expected_pixel))],"$effect coercion $x");
        }
    }
};
subtest 'snow nonfinite time returns NaN RGB and original alpha' => sub {
    for my $time (POSIX::nan(0),POSIX::HUGE_VAL(),-POSIX::HUGE_VAL()) {
        my $rt=Math::Fractal::Noisemaker::Runtime->new;
        my $ctx=context({width=>1,height=>1,alpha=>1,density=>100,time=>$time},$rt);
        $ctx->texture_binding('inputTex')->data->[3]=0.75;
        my $actual=eval {run_pass(kernel('snow',$rt),$ctx,1,1)};
        ok(!$@,"time $time does not throw") or next;
        ok(!grep({!POSIX::isnan($_)} @{$actual->data}[0..2]),'RGB is NaN');
        is($actual->data->[3],0.75,'alpha unchanged');
    }
};
done_testing;
