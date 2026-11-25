# The 2.x branch's workflow contract.
#
# The test jobs admit 2.x: the push gate runs on every push to 2.x, and no
# test job's condition holds it to main. Every release, notice or dispatch
# job runs only for main. A job runs only for main when its condition names
# refs/heads/main or a workflow_run head branch of main, or when every
# trigger of its workflow is a schedule (which runs only from the default
# branch) or a push or workflow_run filtered to main alone. A workflow that
# holds both test jobs and release jobs admits 2.x in its triggers, so its
# release jobs must run only for main by their condition.
#
# This test reads the repository's workflows, which the distribution does not
# ship, so it lives in xt/ and not in t/.

use strict;
use warnings;
use Test::More;
use FindBin;
use File::Spec;

my $WORKFLOWS = File::Spec->catdir($FindBin::Bin, File::Spec->updir, '.github', 'workflows');

# Test jobs, by workflow, that must admit 2.x. The push gate (test) runs on
# every push; parity, windows and perl32 run on the schedule and on dispatch.
my %TEST_JOBS = ('export-kit.yml' => [qw(test parity windows perl32)]);
# Release, notice or dispatch jobs, by workflow, that must run only for main.
my %RELEASE_JOBS = ('export-kit.yml' => [qw(dispatch)]);

my @MAIN_ONLY_CONDITIONS = (
    qr/github\.ref\s*==\s*'refs\/heads\/main'/,
    qr/github\.event\.workflow_run\.head_branch\s*==\s*'main'/,
);

sub unquote {
    my ($text) = @_;
    $text =~ s/\A['"]+//;
    $text =~ s/['"]+\z//;
    return $text;
}

sub trim {
    my ($text) = @_;
    $text =~ s/\A\s+//;
    $text =~ s/\s+\z//;
    return $text;
}

sub partition {
    my ($text) = @_;
    my $at = index($text, ':');
    return $at < 0 ? ($text, '') : (substr($text, 0, $at), substr($text, $at + 1));
}

sub starts_with_item { return index($_[0], '- ') == 0 }

# Each line that is not blank and not a full-line comment, as [indent, text],
# with any trailing comment removed.
sub read_lines {
    my ($name) = @_;
    my $path = File::Spec->catfile($WORKFLOWS, $name);
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!\n";
    my $content = do { local $/; <$fh> };
    close $fh;
    my @found;
    for my $raw (split /\r\n|\r|\n/, $content) {
        $raw =~ s/\s+#[^'"]*\z//;
        next unless $raw =~ /\S/ && $raw !~ /\A\s*#/;
        my ($lead) = $raw =~ /\A( *)/;
        push @found, [length $lead, trim($raw)];
    }
    return \@found;
}

# Return [key, value, index] for each key one level below $all->[$start].
sub children {
    my ($all, $start, $indent) = @_;
    my @found;
    my $child;
    for my $index ($start + 1 .. $#$all) {
        my ($depth, $text) = @{ $all->[$index] };
        last if $depth <= $indent;
        $child = $depth unless defined $child;
        if ($depth == $child && !starts_with_item($text)) {
            my ($key, $value) = partition($text);
            push @found, [unquote(trim($key)), trim($value), $index];
        }
    }
    return @found;
}

# The scalar at $all->[$index]: inline, or a folded or literal block.
sub block {
    my ($all, $index) = @_;
    my ($depth, $text) = @{ $all->[$index] };
    my $value = trim((partition($text))[1]);
    my $first = substr($value, 0, 1);
    return $value unless $first eq '>' || $first eq '|';
    my @parts;
    for my $later ($index + 1 .. $#$all) {
        last if $all->[$later][0] <= $depth;
        push @parts, $all->[$later][1];
    }
    return join ' ', @parts;
}

sub top {
    my ($all, $key) = @_;
    for my $index (0 .. $#$all) {
        my ($depth, $text) = @{ $all->[$index] };
        return $index if $depth == 0 && unquote(trim((partition($text))[0])) eq $key;
    }
    die "no top-level '$key'\n";
}

# Map each trigger to its branch filter (undef when it has none).
sub triggers {
    my ($name) = @_;
    my $all = read_lines($name);
    my $start = top($all, 'on');
    my %result;
    for my $trigger (children($all, $start, 0)) {
        my ($event, undef, $index) = @$trigger;
        my $branches;
        for my $entry (children($all, $index, $all->[$index][0])) {
            my ($key, $inline, $child) = @$entry;
            next unless $key eq 'branches';
            if (index($inline, '[') == 0) {
                (my $list = $inline) =~ s/\A[\[\]]+//;
                $list =~ s/[\[\]]+\z//;
                $branches = [map { unquote(trim($_)) } grep { /\S/ } split /,/, $list];
            }
            else {
                $branches = [];
                for my $later ($child + 1 .. $#$all) {
                    my ($depth, $text) = @{ $all->[$later] };
                    last if $depth <= $all->[$child][0] && !starts_with_item($text);
                    push @$branches, unquote(trim(substr($text, 2))) if starts_with_item($text);
                }
            }
        }
        $result{$event} = $branches;
    }
    return \%result;
}

# Map each job to its condition ('' when it has none).
sub jobs {
    my ($name) = @_;
    my $all = read_lines($name);
    my $start = top($all, 'jobs');
    my %result;
    for my $entry (children($all, $start, 0)) {
        my ($job, undef, $index) = @$entry;
        my $condition = '';
        for my $child (children($all, $index, $all->[$index][0])) {
            $condition = block($all, $child->[2]) if $child->[0] eq 'if';
        }
        $result{$job} = $condition;
    }
    return \%result;
}

# A condition with an alternative can hold outside main, so it is never
# main-only by its text.
sub main_only_by_condition {
    my ($condition) = @_;
    return 0 if index($condition, '||') >= 0;
    my $matched = grep { $condition =~ $_ } @MAIN_ONLY_CONDITIONS;
    return $matched ? 1 : 0;
}

sub runs_only_for_main {
    my ($name, $condition) = @_;
    return 1 if main_only_by_condition($condition);
    my $found = triggers($name);
    for my $event (sort keys %$found) {
        next if $event eq 'schedule';
        my $branches = $found->{$event};
        next if ($event eq 'push' || $event eq 'workflow_run')
            && defined $branches && @$branches == 1 && $branches->[0] eq 'main';
        return 0;
    }
    return 1;
}

for my $name (sort keys %TEST_JOBS) {
    subtest "$name runs on every 2.x push, and its test jobs admit 2.x" => sub {
        my $found = triggers($name);
        # A push trigger with no branch filter runs on every branch.
        my $push = $found->{push};
        my $admits = exists $found->{push}
            && (!defined $push || scalar(grep { $_ eq '2.x' } @$push)) ? 1 : 0;
        ok($admits, "$name runs on a 2.x push");
        my $conditions = jobs($name);
        for my $job (@{ $TEST_JOBS{$name} }) {
            ok(exists $conditions->{$job}, "$name has a job $job") or next;
            my $condition = $conditions->{$job};
            ok(index($condition, 'refs/heads/main') < 0 || index($condition, 'refs/heads/2.x') >= 0,
                "$name job $job is not held to main: $condition");
        }
    };
}

for my $name (sort keys %RELEASE_JOBS) {
    subtest "every release, notice or dispatch job of $name runs only for main" => sub {
        my $conditions = jobs($name);
        # The test jobs of this workflow admit 2.x in its triggers, so only the
        # condition can hold its release jobs to main.
        my $mixed = exists $TEST_JOBS{$name};
        for my $job (@{ $RELEASE_JOBS{$name} }) {
            ok(exists $conditions->{$job}, "$name has a job $job") or next;
            my $condition = $conditions->{$job};
            ok($mixed ? main_only_by_condition($condition) : runs_only_for_main($name, $condition),
                "$name job $job runs only for main");
        }
    };
}

subtest 'the contract reader finds every workflow trigger and job' => sub {
    my %names = map { ($_ => 1) } keys %TEST_JOBS, keys %RELEASE_JOBS;
    for my $name (sort keys %names) {
        ok(scalar(keys %{ triggers($name) }), "triggers read from $name");
        my @found = sort keys %{ jobs($name) };
        ok(scalar(@found), "jobs read from $name");
        # Every job is named as a test job or a release job, so none escapes
        # the contract.
        my @listed = sort @{ $TEST_JOBS{$name} || [] }, @{ $RELEASE_JOBS{$name} || [] };
        is_deeply(\@found, \@listed, "every job of $name is named by the contract");
    }
    my $found = triggers('export-kit.yml');
    ok(exists $found->{push}, 'export-kit.yml has a push trigger');
    ok(exists $found->{schedule}, 'export-kit.yml has a schedule trigger');
};

done_testing();
