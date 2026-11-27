use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../scripts";
use ParityOracle qw(resolve_oracle);
use File::Spec;
use File::Temp qw(tempdir);
use Math::Fractal::Noisemaker::PNG qw(decode_png);

my $oracle = eval { resolve_oracle() };
my $oracle_ok = defined $oracle && -f File::Spec->catfile($oracle, 'bin', 'noisemaker-cpu.js');
if ($ENV{RELEASE_TESTING} && !$oracle_ok) {
    BAIL_OUT('pinned JS oracle could not be resolved and verified: '
        . ($@ || 'no pinned noisemaker-for-cpu available'));
}
plan skip_all => 'pinned JS oracle required for grain parity regression'
    unless $oracle_ok;
# parity.pl resolves NOISEMAKER_CPU_DIR first; hand the verified checkout down.
$ENV{NOISEMAKER_CPU_DIR} = $oracle;
my $root = File::Spec->rel2abs("$FindBin::Bin/..");
my $script = "$root/scripts/parity.pl";
my $tmp = tempdir(CLEANUP => 1);
my @args = ('--only', 'filter/grain', '--size', '64', '--seed', '97', '--time', '0.75');
# Keep both engines' captures and compare their decoded RGBA bytes.
my $captures = File::Spec->catdir($tmp, 'captures');
mkdir $captures or die "cannot create $captures: $!\n";
$ENV{NM_PARITY_CAPTURE_DIR} = $captures;

sub run_capture {
    my ($name, @command) = @_;
    open my $saved_out, '>&', \*STDOUT or die $!;
    open my $saved_err, '>&', \*STDERR or die $!;
    open STDOUT, '>', "$tmp/$name.log" or die $!;
    open STDERR, '>&', \*STDOUT or die $!;
    my $result = system(@command);
    open STDOUT, '>&', $saved_out or die $!;
    open STDERR, '>&', $saved_err or die $!;
    open my $log, '<', "$tmp/$name.log" or die $!;
    local $/;
    return ($result, scalar <$log>);
}

my ($accepted, $receipt) = run_capture('accepted', $^X, $script, @args);
is($accepted, 0, 'grain renders exactly at the current oracle pin');
my ($pin) = $receipt =~ /^Reference: ([0-9a-f]{40}) /m;
ok(defined $pin, 'the receipt names its oracle pin');
like($receipt, qr/^PASS: 1\s+\(byte-exact: 1\)$/m, 'the grain receipt is byte-exact');
like($receipt, qr/^NEAR: 0$/m, 'the current pin requires no NEAR allowance');
my @pixels;
for my $engine (qw(js perl)) {
    my $path = File::Spec->catfile($captures, "filter_grain.$engine.png");
    ok(-f $path, "the $engine capture is retained");
    if (-f $path) {
        open my $png, '<:raw', $path or die "$path: $!";
        local $/;
        push @pixels, decode_png(scalar <$png>)->to_rgba8;
    }
}
ok(@pixels == 2 && length($pixels[0]) == 64 * 64 * 4 && $pixels[0] eq $pixels[1],
    'both retained captures match across all 16,384 RGBA bytes');

# Alter one pixel of a real render. A single pixel must fail exact comparison.
my $wrapper = "$tmp/extra-pixel.pl";
open my $fh, '>', $wrapper or die $!;
print {$fh} <<'WRAPPER';
use strict;
use warnings;
use Math::Fractal::Noisemaker::Renderer ();
my $render = \&Math::Fractal::Noisemaker::Renderer::render_effect;
{
    no warnings 'redefine';
    *Math::Fractal::Noisemaker::Renderer::render_effect = sub {
        my $surface = $render->(@_);
        if ($_[0] eq 'filter/grain') {
            my $data = $surface->data;
            $data->[0] = $data->[0] > 0.5 ? 0 : 1;
        }
        return $surface;
    };
}
my $script = shift @ARGV;
do $script;
die $@ || $!;
WRAPPER
close $fh;
my ($rejected, $difference) = run_capture('rejected', $^X, "-I$root/lib", "-I$root/scripts", $wrapper, $script, @args);
isnt($rejected, 0, 'a single changed pixel is rejected');
like($difference, qr/filter\/grain\s+\(1 changed pixels?\)/, 'rejection reports exactly one changed pixel');
done_testing();
