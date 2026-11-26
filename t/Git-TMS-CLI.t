#!perl

use 5.014;

use strict;
use warnings FATAL => 'all';

use re '/aa';

use Test2::V1 qw{subtest is like unlike diag done_testing};
use Test2::Plugin::NoWarnings;

use Capture::Tiny ();
use Cwd           ();
use File::Spec    ();
use FindBin::libs;
use IPC::Run3 ();

use Git::TMS::TestRepo qw{scratch git new_repo bare_repo clone_repo commit_file in_dir};

use Git::TMS::CLI   ();
use Git::TMS::Store ();

# Run a command of git tms in a directory, and return its exit status, its
# standard output, and its warnings followed by the rest of its standard
# error.
sub tms {
    my ( $dir,    @args ) = @_;
    my ( $status, @warnings );
    my ( $out,    $err ) = Capture::Tiny::capture(
        sub {
            local $SIG{__WARN__} = sub { push @warnings, @_ };
            $status = in_dir( $dir, sub { Git::TMS::CLI::main(@args) } );
        },
    );
    return ( $status, $out, join q{}, @warnings, $err );
}

# The lines of some output, each with its runs of spaces squashed to one, and
# none at its ends.
sub lines {
    my ($out) = @_;
    return [ map { join q{ }, split q{ } } split m/\n/sx, $out ];
}

# A record of one test.
sub record {
    my ( $test, $status, %more ) = @_;
    return { v => 1, run => 'r1', test => $test, status => $status, elapsed => 0.5, %more };
}

my $root   = scratch();
my $origin = bare_repo( $root, 'origin.git' );
my $repo   = clone_repo( $root, $origin, 'work' );
my $first  = commit_file( $repo, 'a.txt', "a\n" );
my $second = commit_file( $repo, 'b.txt', "b\n" );
git( $repo, qw{push --quiet origin main} );
my $tree1 = git( $repo, 'rev-parse', "$first^{tree}" );
my $tree2 = git( $repo, 'rev-parse', "$second^{tree}" );

my $store = Git::TMS::Store->new( dir => $repo );
$store->add_records( 'linux', $tree2, record( 't/a.t', 'pass' ), record( 't/b.t', 'fail', exit => 1, failed => 2, output => "not ok 1 - b\n#   got 1\n" ) );
$store->add_records( 'linux', $tree2, record( 't/b.t', 'pass',    run    => 'r2' ) );
$store->add_records( 'win',   $tree2, record( 't/b.t', 'bailout', output => "Bail out!\n" ) );
$store->add_records( 'mac',   $tree2, record( 't/b.t', 'skip',    reason => 'no network' ) );
$store->add_records( 'linux', $tree1, record( 't/a.t', 'fail', cut => 1, try => 1, errors => ['Bad plan'] ) );

subtest usage => sub {
    my ( $status, $out, $err ) = tms($repo);
    is( $status, 2, 'no command is a wrong command line' );
    like( $err, qr/\A Usage: \n \s+ git \s tms \s results/sx, 'and prints the usage, with the commands' );

    ( $status, $out, $err ) = tms( $repo, 'record' );
    is( $status, 2, 'a command that does not exist is a wrong command line' );
    like( $err, qr/\A git-tms: \s 'record' \s is \s not \s a \s command [.] \n Usage:/sx, 'and says which' );

    ( $status, $out ) = tms( $repo, 'help' );
    is( $status, 0, 'help succeeds' );
    like( $out, qr/\A Usage: \n \s+ git \s tms \s results .* \n Commands: \n \s+ results \s/sx, 'and prints the usage and the commands' );

    ( $status, $out, $err ) = tms( $repo, qw{results --colour} );
    is( $status, 1, 'an unknown option fails' );
    like( $err, qr/\A git-tms: \s Unknown \s option: \s colour \n/sx, 'and says which' );
};

subtest results => sub {
    my ( $status, $out, $err ) = tms( $repo, 'results' );
    is( $status, 0, 'results succeeds' ) or diag($err);
    is(
        lines($out),
        [
            "commit $second tree $tree2",
            'pass linux t/a.t 0.500s',
            'fail linux t/b.t 0.500s exit 1, 2 failed',
            'pass linux t/b.t 0.500s',
            'skip mac t/b.t 0.500s no network',
            'bailout win t/b.t 0.500s',
        ],
        'the default is HEAD, one line for each record',
    );
    like( $out, qr/^ \s{4} pass \s{4} linux \s+ t\/a[.]t \s+ 0[.]500s $/msx, 'each line is indented, and its columns are aligned' );

    ( $status, $out ) = tms( $repo, qw{results --config win --config mac --raw HEAD} );
    is(
        lines($out),
        [ "commit $second tree $tree2", 'skip mac t/b.t 0.500s no network', 'bailout win t/b.t 0.500s', 'Bail out!' ],
        '--config takes a value, more than once, and --raw adds the output',
    );
    like( $out, qr/^ \s{8} Bail \s out!$/msx, 'indented below the record' );

    ( $status, $out ) = tms( $repo, 'results', "$first~0..HEAD" );
    like( $out, qr/\A commit \s $second \s tree \s $tree2 \n/sx, 'a range shows each commit, newest first' );
    unlike( $out, qr/commit \s $first/sx, 'and not the commit at its start' );

    ( $status, $out ) = tms( $repo, 'results', $first );
    is( lines($out), [ "commit $first tree $tree1", 'fail linux t/a.t 0.500s Bad plan, output cut, try 1' ], 'a revision shows its own commit' );

    ( $status, $out ) = tms( $repo, qw{results --config nobody} );
    is( lines($out), [ "commit $second tree $tree2", 'no results' ], 'a commit with no records says so' );

    ( $status, $out, $err ) = tms( $repo, 'results', 'no-such-rev' );
    is( $status, 1, 'an unknown revision fails' );
    like( $err, qr/\A git-tms: \s git \s log \s .* \s failed/sx, 'with the error of git' );

    ( $status, $out, $err ) = tms( $repo, qw{results HEAD HEAD} );
    like( [ $status, $err ], [ 1, qr/results[ ]takes[ ]one[ ]revision[ ]or[ ]range/sx ], 'two revisions are refused' );
};

subtest scan => sub {
    my ( $status, $out ) = tms( $repo, qw{scan --where-fails t/b.t} );
    is( $status,     0,                                                       'scan succeeds' );
    is( lines($out), [ 'linux fail 1 of 2 runs', 'win bailout 1 of 1 runs' ], 'each configuration that fails the test at HEAD, and not one that skips it' );

    ( $status, $out ) = tms( $repo, qw{scan --where-fails t\b.t HEAD} );
    is( lines($out)->[0], 'linux fail 1 of 2 runs', 'a test named with backslashes is the same test' );

    ( $status, $out ) = tms( $repo, qw{scan --where-fails t/a.t HEAD} );
    is( $out, "No configuration fails t/a.t at HEAD.  1 configurations have results for it.\n", 'a test that nothing fails says so' );

    ( $status, $out ) = tms( $repo, qw{scan --where-fails t/a.t}, $first );
    is( lines($out), ['linux fail 1 of 1 runs'], 'another revision has its own results' );

    my $err;
    ( $status, $out, $err ) = tms( $repo, 'scan' );
    is( $status, 1, 'scan with no question fails' );
    like( $err, qr/scan \s needs \s --where-fails \s TEST/sx, 'and says what it needs' );
    ( $status, $out, $err ) = tms( $repo, qw{scan --where-fails t/a.t HEAD HEAD} );
    is( $status, 1, 'scan with two revisions fails' );
    like( $err, qr/scan \s takes \s one \s revision/sx, 'and says why' );
};

subtest push_and_fetch => sub {
    my ( $status, $out, $err ) = tms( $repo, 'push' );
    is( $status, 0,                                                                                     'push succeeds' ) or diag($err);
    is( $out,    join( q{}, map { "pushed refs/notes/tms/results/$_ to origin\n" } qw{linux mac win} ), 'it pushes every configuration to origin' );

    my $reader = clone_repo( $root, $origin, 'reader' );
    ( $status, $out ) = tms( $reader, 'fetch' );
    is( $out, "fetched linux from origin\nfetched mac from origin\nfetched win from origin\n", 'fetch takes them all' );
    ( $status, $out ) = tms( $reader, 'results' );
    like( $out, qr/bailout \s+ win/sx, 'and results reads what it fetched' );

    ( $status, $out ) = tms( $reader, 'push' );
    is( $out, "No results to push.\n", 'a clone with only fetched results has nothing to push' );

    my $results = bare_repo( $root, 'results.git' );
    git( $repo, qw{remote add results}, $results );
    git( $repo, qw{config tms.remote results} );
    ( $status, $out ) = tms( $repo, 'push' );
    is( lines($out)->[0], 'pushed refs/notes/tms/results/linux to results', 'tms.remote names the remote when the command line does not' );

    git( $reader, qw{remote add empty}, bare_repo( $root, 'empty.git' ) );
    ( $status, $out ) = tms( $reader, qw{fetch empty} );
    is( $out, "empty has no results.\n", 'a remote with no results says so' );

    foreach my $command (qw{fetch push}) {
        ( $status, $out, $err ) = tms( $reader, $command, qw{a b} );
        is( $status, 1, "$command with two remotes fails" );
        like( $err, qr/$command \s takes \s one \s remote/sx, 'and says why' );
    }
    ( $status, $out, $err ) = tms( $reader, qw{fetch nowhere} );
    is( $status, 1, 'a fetch that git refuses fails' );
    like( $err, qr/\A git-tms: \s git \s fetch \s .* \s failed/sx, 'with the error of git' );
};

subtest the_program => sub {
    my $lib = Cwd::abs_path( File::Spec->catdir( ( File::Spec->splitpath( Cwd::abs_path( $INC{'Git/TMS/CLI.pm'} ) ) )[1], File::Spec->updir, File::Spec->updir ) );

    # lib holds the modules in the checkout, and blib/lib in a build.
    my $bin = File::Spec->catfile( $lib, File::Spec->updir, qw{bin git-tms} );
    $bin = File::Spec->catfile( $lib, File::Spec->updir, File::Spec->updir, qw{bin git-tms} ) if !-e $bin;
    my ( $out, $err ) = ( q{}, q{} );
    in_dir( $repo, sub { IPC::Run3::run3( [ $^X, "-I$lib", $bin, qw{scan --where-fails t/b.t} ], \undef, \$out, \$err ) } );
    is( $? >> 8,          0,                        'bin/git-tms runs' ) or diag($err);
    is( lines($out)->[0], 'linux fail 1 of 2 runs', 'and prints what the command prints' );
};

done_testing;
