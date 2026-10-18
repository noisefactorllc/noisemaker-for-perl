use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Math::Fractal::Noisemaker::Runtime;
use Math::Fractal::Noisemaker::Surface;
use Math::Fractal::Noisemaker::PassRunner ();
use Math::Fractal::Noisemaker::KernelCache;
use Math::Fractal::Noisemaker::Transpiler::Codegen qw(emit_perl);
use Math::Fractal::Noisemaker::Transpiler::Parser qw(parse);
use Math::Fractal::Noisemaker::Transpiler::Preprocess qw(normalize);

sub compile {
    my ($source, $options) = @_;
    my $norm = normalize($source, ($options || {})->{runtime_defines} || {});
    return emit_perl(parse($norm->{source}, $source), $norm->{outputs}, $norm->{varyings}, 'filter/spookyTicker', $options);
}
sub render {
    my ($source, $uniforms, $options) = @_;
    my $kernel = Math::Fractal::Noisemaker::KernelCache::load_kernel(compile($source, $options), 'cpu-codegen-sync');
    my $ctx = Math::Fractal::Noisemaker::Ctx->new(rt => Math::Fractal::Noisemaker::Runtime->new,
        uniforms => $uniforms || {}, textures => {}, resolution => [1,1], time => 0, seed => 1,
        blank => Math::Fractal::Noisemaker::Surface->new(1,1));
    my $out = [(0) x 4];
    $kernel->{kernel}->($ctx, $out);
    return [unpack('L<*', pack('f<*', @$out))];
}
# Keep exceptions local so all independent compiler defects are visible in the red run.
sub probe {
    my ($label, $source, $uniforms, $expected, $options) = @_;
    my $got = eval { render($source, $uniforms, $options) };
    my $error = $@;
    is_deeply($got, $expected, $label);
    diag($error) if $error;
}

probe('runtime, local, constant and helper divisors', <<'GLSL', {width=>41}, [1019727373,1019727373,1019727372,1019727372]);
uniform float width;
out vec4 fragColor;
float helper(float x,float d){return x/d;}
void main(){float localWidth=width+0.0;const float folded=41.0;fragColor=vec4(1.0/width,1.0/localWidth,1.0/folded,helper(1.0,41.0));}
GLSL
probe('define divisor remains folded', 'uniform float WIDTH; out vec4 fragColor;void main(){fragColor=vec4(1.0/WIDTH);}', {WIDTH=>41}, [(1019727372)x4], {constant_divisors=>{WIDTH=>41}});
probe('synthetic runtime define does not grant integer-name evidence', <<'GLSL', {CW=>41}, [(1019727372)x4], {runtime_defines=>{CW=>'int'},constant_divisors=>{CW=>41}});
#ifndef CW
#define CW 41
#endif
out vec4 fragColor;
void main(){int a=1;int x=a/CW;fragColor=vec4(float(x));}
GLSL
probe('scalar and indexed compound stay raw', 'uniform float width;out vec4 fragColor;void main(){vec2 p=vec2(1.0,3.0);p/=width;float x=1.0;x/=width;vec2 q=vec2(1.0);q[0]/=width;fragColor=vec4(p,x,q[0]);}', {width=>41}, [1019727373,1033230986,1019727372,1019727372]);
probe('scalar integer compound divisions stay raw', 'uniform int CW;out vec4 fragColor;void main(){int x=1;x/=CW;int a[1];a[0]=1;a[0]/=CW;fragColor=vec4(float(x),float(a[0]),0.0,0.0);}', {CW=>41}, [1019727372,1019727372,0,0]);
probe('integer vector cast and scalar splat evidence', 'uniform ivec2 dims;uniform ivec2 xy;uniform int x;out vec4 fragColor;void main(){vec2 a=vec2(xy)/vec2(dims);vec2 b=vec2(x)/vec2(dims);fragColor=vec4(a,b);}', {dims=>[41,41],xy=>[1,1],x=>1}, [1019727372,1019727372,1019727373,1019727373]);
for my $case (
    ['vec2 p[1];p[0]=vec2(1.0);p[0]/=width;fragColor=vec4(p[0],0.0,0.0);',[1019727373,1019727373,0,0]],
    ['vec2 p[1];p[0]=vec2(1.0);p[0]/=dims;fragColor=vec4(p[0],0.0,0.0);',[1019727372,1019727372,0,0]],
    ['vec4 p=vec4(1.0);p.xy/=vec2(width);fragColor=p;',[1019727373,1019727373,1065353216,1065353216]],
    ['vec2 p=vec2(1.0);p/=dims;fragColor=vec4(p,0.0,0.0);',[1019727372,1019727372,0,0]],
) { probe('compound shape '.$case->[0], 'uniform float width;uniform vec2 dims;out vec4 fragColor;void main(){'.$case->[0].'}', {width=>41,dims=>[41,41]},$case->[1]); }
for my $case (
    ['p=vec2(dot(p,vec2(2.0,0.0)),dot(p,vec2(3.0,0.0)));',[2,3]],
    ["p=vec2(p.y,\n-p.x);",[2,-1]],
    ['p=vec2(p.t,p.s);',[2,1]],
    ['p=vec2(p.y,p[0x0]);',[2,1]],
    ['p=vec2(p.y,p[0u]);',[2,1]],
    ['p=dot(p,vec2(2.0,3.0))*vec2(2.0,3.0);',[16,24]],
) {
    probe('stage self-read '.$case->[0], 'out vec4 fragColor;void main(){vec2 p=vec2(1.0,2.0);'.$case->[0].'fragColor=vec4(p,p);}', {}, [unpack('L<*',pack('f<*',(@{$case->[1]})x2))]);
}
probe('assignment expression returns target vector', 'out vec4 fragColor;void main(){vec2 p=vec2(1.0,2.0);vec2 q=(p=vec2(p.y,-p.x));fragColor=vec4(p,q);}', {}, [unpack('L<*',pack('f<*',2,-1,2,-1))]);
probe('assignment expression passes a vector to a builtin', 'out vec4 fragColor;void main(){vec2 p=vec2(1.0,2.0);fragColor=vec4(length(p=vec2(p.y,-p.x)));}', {}, [unpack('L<*',pack('f<*',(sqrt(5))x4))]);
for my $case (
    ['a/CW',0],['a>0?a/CW:(a-CW+1)/CW',0],['a>0?(-a)/CW:(-b)/CW',0x80000000],
    ['a>0?(a*(b+1))/CW:((a+b)*2)/CW',1059760811],
    ['a>0?(abs(a)+b)/CW:(abs(b)+a)/CW',1059760811],
    ['a>0?(a+int(b))/CW:(b+int(a))/CW',0],
) { probe('integer statement '.$case->[0], 'uniform int a;uniform int b;uniform int CW;out vec4 fragColor;void main(){int x='.$case->[0].';fragColor=vec4(float(x));}',{a=>1,b=>1,CW=>3},[($case->[1])x4]); }
for my $case (
    ['int x=(a)/CW',1019727373],['float x=1/(CW)',1019727373],['int x=((a))/CW',1019727372],
    ['float x=1/((CW))',1019727372],['int x=(float(a))/CW',1019727372],
    ['int x=a>0?(a)/CW:(b)/CW',1019727373],['int x=a>0?(a+float(b))/CW:(b+float(a))/CW',1028115980],
) { probe('grouping '.$case->[0], 'uniform int a;uniform int b;uniform int CW;out vec4 fragColor;void main(){'.$case->[0].';fragColor=vec4(float(x));}',{a=>1,b=>1,CW=>41},[($case->[1])x4]); }
probe('integer name evidence survives raw initializer', 'uniform int CW;out vec4 fragColor;void main(){int a=1/3;int x=a/CW;fragColor=vec4(float(x));}', {CW=>41}, [(0)x4]);
probe('second declarator dividend is absent from CPU int names', 'uniform int CW;out vec4 fragColor;void main(){int a=1,b=1;int x=b/CW;fragColor=vec4(float(x));}', {CW=>41}, [(1019727372)x4]);
probe('second declarator divisor is absent from CPU int names', 'out vec4 fragColor;void main(){int a=1;int unused=1,CW=41;int x=a/CW;fragColor=vec4(float(x));}', {}, [(1019727372)x4]);
probe('ternary second declarator divisor stays raw', 'out vec4 fragColor;void main(){int a=1;int unused=1,CW=41;int x=a>0?a/CW:(a+1)/CW;fragColor=vec4(float(x));}', {}, [(1019727372)x4]);
probe('ternary destination in second declarator stays raw', 'uniform int CW;out vec4 fragColor;void main(){int a=1;int unused=1,x=a>0?a/CW:(a+1)/CW;fragColor=vec4(float(x));}', {CW=>41}, [(1019727372)x4]);
probe('CPU global integer names override helper lexical float types', 'out vec4 fragColor;float helper(float a,float b){float x=a/b;return x;}void main(){int a=1;int b=41;fragColor=vec4(helper(1.0,41.0));}', {}, [(0)x4]);
probe('CPU global integer names include a shadowed ternary destination', 'out vec4 fragColor;float helper(float a,float b){float x=a>0?a/b:(a+1)/b;return x;}void main(){int a=1;int b=41;int x=0;fragColor=vec4(helper(1.0,41.0));}', {}, [(0)x4]);
probe('Metal division prevents global-name integer restoration', 'uniform float divisor;out vec4 fragColor;float helper(float a){float x=a/divisor;return x;}void main(){int a=1;int divisor=41;fragColor=vec4(helper(1.0));}', {divisor=>41}, [(1019727373)x4]);
my $body='v=v^(v>>16u);v=v*0x7feb352du;v=v^(v>>15u);v=v*0x846ca68bu;v=v^(v>>16u);return v;';
my $hash='uint hash_mix(uint v){'.$body.'}out vec4 fragColor;void main(){fragColor=vec4(float(hash_mix(0xfedcba98u)));}';
probe('exact murmur body independent of name',$hash,{},[unpack('L<*',pack('f<*',(3080438707)x4))]);
probe('spooky glyph modulo preserves unsigned hash result',
    'uint hash_mix(uint v){'.$body.'}out vec4 fragColor;void main(){uint h=hash_mix(0xfedcba98u);int digit=int(h%10u);fragColor=vec4(float(digit));}',
    {}, [unpack('L<*',pack('f<*',(7)x4))]);
my $parenthesized_hash = $hash;
$parenthesized_hash =~ s/v\*0x7feb352du/v*(0x7feb352du)/;
probe('parenthesized Murmur multiplier stays unrouted', $parenthesized_hash, {}, [(1305199957)x4]);
my $qualified_hash = $hash;
$qualified_hash =~ s/uint v/highp uint v/;
probe('qualified Murmur parameter stays unrouted', $qualified_hash, {}, [(1311550869)x4]);
$hash =~ s/hash_mix/hash_uint/g; $hash =~ s/>>15u/>>14u/;
unlike(compile($hash),qr/\$rt->hash_uint\(/,'mutated murmur body is not routed');
done_testing;
