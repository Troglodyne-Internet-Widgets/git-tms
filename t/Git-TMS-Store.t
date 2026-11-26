#!perl

use 5.014;

use strict;
use warnings FATAL => 'all';

use re '/aa';

use Test2::V1 qw{subtest ok is isnt like dies done_testing};
use Test2::Plugin::NoWarnings;

use FindBin::libs;

use Git::TMS::TestRepo qw{scratch git new_repo bare_repo clone_repo commit_file write_file};

use Git::TMS::Store ();

# A record with the fields that the store needs to sort it.
sub record {
    my ( $test, $status, $run ) = @_;
    return { v => 1, test => $test, status => $status, run => $run // 'r1', elapsed => 0.1 };
}

subtest check_name => sub {
    foreach my $good (qw{a linux-perl5.40 freebsd_perl5.38+nodeps W1 a.b}) {
        is( Git::TMS::Store::check_name( configuration => $good ), $good, "'$good' is a usable name" );
    }
    foreach my $bad ( q{}, qw{-a .a a. a/b a..b a.lock a:b a~1 a^ a*}, 'a b', "a\nb", chr 233 ) {
        like( dies { Git::TMS::Store::check_name( configuration => $bad ) }, qr/the \s configuration \s name \s .* \s is \s not \s usable/sx, "'$bad' is refused" );
    }
    like( dies { Git::TMS::Store::check_name( remote => undef ) }, qr/the \s remote \s name \s '' \s is \s not \s usable/sx, 'no name is refused' );
};

subtest refs => sub {
    is( Git::TMS::Store::results_ref('c1'),              'refs/notes/tms/results/c1',               'the local ref of a configuration' );
    is( Git::TMS::Store::tracking_ref( 'origin', 'c1' ), 'refs/notes/tms-remote/origin/results/c1', 'the ref that a fetch writes' );
    ok( dies { Git::TMS::Store::tracking_ref( 'a/b', 'c1' ) }, 'a remote name with a slash is refused' );
};

subtest tested_tree => sub {
    my $root = scratch();

    my $none = new_repo( $root, 'none' );
    my ( $tree, $why ) = Git::TMS::Store->new( dir => $none )->tested_tree();
    is( $tree, undef, 'a repository with no commit has no tested tree' );
    like( $why, qr/with a commit/s, 'and says why' );

    my $repo = new_repo( $root, 'work' );
    commit_file( $repo, 'a.txt', "a\n" );
    my $store = Git::TMS::Store->new( dir => $repo );
    is( [ $store->tested_tree() ], [ git( $repo, qw{rev-parse HEAD^{tree}} ) ], 'a clean work tree is the tree of HEAD' );

    write_file( $repo, 'untracked.txt', "u\n" );
    is( [ $store->tested_tree() ], [ git( $repo, qw{rev-parse HEAD^{tree}} ) ], 'an untracked file does not count' );

    write_file( $repo, 'a.txt', "changed\n" );
    ( $tree, $why ) = $store->tested_tree();
    is( $tree, undef, 'a changed tracked file leaves no tested tree' );
    like( $why, qr/tracked files differ from HEAD/s, 'and says why' );

    git( $repo, qw{add a.txt} );
    is( ( $store->tested_tree() )[0], undef, 'a staged change counts too' );
};

subtest add_records_and_records => sub {
    my $root  = scratch();
    my $repo  = new_repo( $root, 'work' );
    my $first = commit_file( $repo, 'a.txt', "a\n" );
    my $tree  = git( $repo, qw{rev-parse HEAD^{tree}} );
    my $store = Git::TMS::Store->new( dir => $repo );

    is( $store->records( [$tree] ), {}, 'a tree with no notes has no records' );

    is( $store->add_records( 'c1', $tree, record( 't/b.t', 'fail' ), record( 't/a.t', 'pass' ) ), 2, 'two records make two lines' );
    is( $store->add_records( 'c1', $tree, record( 't/a.t', 'pass' ), record(qw{t/a.t pass r2}) ), 3, 'a record the note has already is not added twice' );

    my $note  = git( $repo, qw{notes --ref refs/notes/tms/results/c1 show}, $tree );
    my @lines = split m/\n/sx, $note;
    is( \@lines,   [ sort @lines ],                                                   'the lines of the note are sorted' );
    is( $lines[1], '{"elapsed":0.1,"run":"r1","status":"pass","test":"t/a.t","v":1}', 'a line is canonical JSON' );

    $store->add_records( 'c2', $tree, record( 't/a.t', 'fail' ) );
    my $records = $store->records( [$tree] )->{$tree};
    is(
        [ map { "$_->{config} $_->{test} $_->{status} $_->{run}" } @$records ],
        [ 'c1 t/a.t pass r1', 'c1 t/a.t pass r2', 'c2 t/a.t fail r1', 'c1 t/b.t fail r1' ],
        'the records of every configuration, ordered by test, configuration and run',
    );
    is( [ map { $_->{config} } @{ $store->records( [$tree], configs => ['c2'] )->{$tree} } ], ['c2'], 'configs limits the configurations' );

    # A commit with a different message and the same tree shares the results.
    git( $repo, qw{-c user.name=T -c user.email=t@test.test commit --quiet --amend -m other} );
    isnt( git( $repo, qw{rev-parse HEAD} ), $first, 'the amend made a new commit' );
    is( scalar @{ $store->records( [ git( $repo, qw{rev-parse HEAD^{tree}} ) ] )->{$tree} }, 4, 'and it finds the results of its tree' );

    # A line that is not a JSON object is skipped, not fatal.
    commit_file( $repo, 'b.txt', "b\n" );
    my $tree2 = git( $repo, qw{rev-parse HEAD^{tree}} );
    git( $repo, qw{-c user.name=T -c user.email=t@test.test notes --ref refs/notes/tms/results/c1 add -m}, "not json\n[1]", $tree2 );
    $store->add_records( 'c1', $tree2, record( 't/a.t', 'pass' ) );
    is( [ map { $_->{test} } @{ $store->records( [$tree2] )->{$tree2} } ], ['t/a.t'], 'lines that are not JSON objects are skipped' );
};

subtest blobs => sub {
    my $root  = scratch();
    my $repo  = new_repo( $root, 'work' );
    my $store = Git::TMS::Store->new( dir => $repo );
    my $id    = $store->git->run( \"one\ntwo\n", qw{hash-object -w --stdin} );
    chomp $id;
    my $empty = $store->git->run( \q{}, qw{hash-object -w --stdin} );
    chomp $empty;
    my $missing = '0' x 40;
    is( $store->blobs( [ $id, $missing, $empty ] ), { $id => "one\ntwo\n", $empty => q{} }, 'the content of each blob, and none for a missing one' );
};

subtest push_and_fetch => sub {
    my $root   = scratch();
    my $origin = bare_repo( $root, 'origin.git' );
    my $seed   = clone_repo( $root, $origin, 'seed' );
    commit_file( $seed, 'a.txt', "a\n" );
    git( $seed, qw{push --quiet origin main} );

    my %clone = map { $_ => clone_repo( $root, $origin, $_ ) } qw{one two three reader};
    my $tree  = git( $clone{one}, qw{rev-parse HEAD^{tree}} );

    is( Git::TMS::Store->new( dir => $clone{reader} )->push_to('origin'),    { pushed => [], merged => [] }, 'a clone with no results pushes nothing' );
    is( Git::TMS::Store->new( dir => $clone{reader} )->fetch_from('origin'), [],                             'a remote with no results fetches nothing, and does not fail' );

    # Three configurations push one after the other, with no fetch between.
    foreach my $name (qw{one two three}) {
        my $store = Git::TMS::Store->new( dir => $clone{$name} );
        $store->add_records( "c-$name", $tree, record( 't/a.t', $name eq 'two' ? 'fail' : 'pass' ) );
        is( $store->push_to('origin'), { pushed => ["refs/notes/tms/results/c-$name"], merged => [] }, "configuration c-$name pushes without a merge" );
    }

    my $reader = Git::TMS::Store->new( dir => $clone{reader} );
    is( $reader->fetch_from('origin'), [qw{c-one c-three c-two}], 'one fetch takes every configuration' );
    is(
        [ map { "$_->{config} $_->{status}" } @{ $reader->records( [$tree] )->{$tree} } ],
        [ 'c-one pass', 'c-three pass', 'c-two fail' ],
        'the reader sees the records of every configuration',
    );

    # Two jobs of one configuration race.  The second push is refused, and
    # push_to merges and pushes again, keeping both records.
    my $late = Git::TMS::Store->new( dir => $clone{three} );
    Git::TMS::Store->new( dir => $clone{one} )->add_records( 'shared', $tree, record(qw{t/a.t pass job1}) );
    Git::TMS::Store->new( dir => $clone{one} )->push_to('origin');
    $late->add_records( 'shared', $tree, record(qw{t/a.t fail job2}) );
    is( $late->push_to('origin')->{merged}, ['refs/notes/tms/results/shared'], 'the second job merged before its push went through' );

    $reader->fetch_from('origin');
    is(
        [ map { "$_->{status} $_->{run}" } grep { $_->{config} eq 'shared' } @{ $reader->records( [$tree] )->{$tree} } ],
        [ 'pass job1', 'fail job2' ],
        'the remote keeps the records of both jobs',
    );

    # A ref that the remote loses is pruned from the fetched refs.
    git( $origin, qw{update-ref -d refs/notes/tms/results/c-two} );
    is( $reader->fetch_from('origin'), [qw{c-one c-three shared}], 'a fetch removes the ref of a configuration that the remote no longer has' );

    like( dies { $late->push_to(q{nowhere}) }, qr/git push to nowhere failed/s, 'a push to a remote that does not exist dies with the reason' );
};

subtest separate_results_repository => sub {
    my $root    = scratch();
    my $origin  = bare_repo( $root, 'origin.git' );
    my $results = bare_repo( $root, 'results.git' );
    my $writer  = clone_repo( $root, $origin, 'writer' );
    commit_file( $writer, 'a.txt', "a\n" );
    git( $writer, qw{push --quiet origin main} );
    my $tree = git( $writer, qw{rev-parse HEAD^{tree}} );

    git( $writer, qw{remote add results}, $results );
    my $store = Git::TMS::Store->new( dir => $writer );
    $store->add_records( 'c1', $tree, record( 't/a.t', 'pass' ) );
    $store->push_to('results');

    ok( dies { git( $results, 'cat-file', '-e', $tree ) }, 'the results repository took the notes without the tree' );

    my $reader = clone_repo( $root, $origin, 'reader' );
    git( $reader, qw{remote add results}, $results );
    my $read = Git::TMS::Store->new( dir => $reader );
    is( $read->fetch_from('results'),                                   ['c1'],    'a clone of the code fetches the results from the results repository' );
    is( [ map { $_->{test} } @{ $read->records( [$tree] )->{$tree} } ], ['t/a.t'], 'and reads them against its own tree' );
};

done_testing;
