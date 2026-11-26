#!perl

use 5.014;

use strict;
use warnings FATAL => 'all';

use re '/aa';

no autovivification;

use Test2::V1 qw{subtest ok is isnt like unlike dies mock D done_testing diag};
use Test2::Plugin::NoWarnings;

use Cwd        ();
use File::Spec ();
use FindBin::libs;
use IPC::Run3 ();

use Git::TMS::TestRepo qw{scratch git new_repo commit_file write_file in_dir};

use App::Prove::Plugin::GitTMS ();
use Git::TMS::Store            ();

# The directory that Git::TMS was loaded from, lib or blib/lib, for the perl that runs prove.
my $LIB = Cwd::abs_path( File::Spec->catdir( ( File::Spec->splitpath( Cwd::abs_path( $INC{q{Git/TMS/Store.pm}} ) ) )[1], File::Spec->updir, File::Spec->updir ) );

# The test files of the throwaway repository, one for each kind of outcome.
my %FIXTURES = (
    't/pass.t'    => "use Test::More; ok( 1, 'fine' ); diag('chatty on a pass'); done_testing;\n",
    't/fail.t'    => "use Test::More; ok( 1, 'good' ); is( 1, 2, 'adds' ); done_testing;\n",
    't/skip.t'    => "use Test::More skip_all => 'no network';\n",
    't/die.t'     => "use Test::More; ok( 1, 'before' ); die qq{kaboom\\n};\n",
    't/subtest.t' => <<'TEST',
use Test::More;
subtest outer => sub { ok( 1, 'inner good' ); ok( 0, 'inner bad' ); };
TODO: { local $TODO = 'later'; ok( 0, 'todo failure' ); }
done_testing;
TEST
    't/secret.t' => "use Test::More; ok( 0, 'login' ); diag('token=SECRET42'); done_testing;\n",
);

# Run prove in a directory, in a perl of its own, so that its output does not
# mix with the TAP of this test.
sub prove {
    my ( $dir, @args ) = @_;
    my ( $out, $err )  = ( q{}, q{} );
    in_dir(
        $dir,
        sub {
            IPC::Run3::run3( [ $^X, "-I$LIB", '-MApp::Prove', '-e', 'my $app = App::Prove->new; $app->process_args(@ARGV); exit( $app->run ? 0 : 1 )', q{--}, @args ], \undef, \$out, \$err );
        },
    );
    return ( $? >> 8, $out, $err );
}

# The records of the tree of HEAD in a repository, by test.
sub records_by_test {
    my ($dir) = @_;
    my $tree = git( $dir, qw{rev-parse HEAD^{tree}} );
    my %by_test;
    push @{ $by_test{ $_->{test} } }, $_ foreach @{ Git::TMS::Store->new( dir => $dir )->records( [$tree] )->{$tree} // [] };
    return \%by_test;
}

subtest load => sub {
    my $app = mock {} => ( add => [ harness => sub { $_[0]->{harness} = $_[1] }, merge => sub { $_[0]->{merge} = $_[1] } ] );
    ok( App::Prove::Plugin::GitTMS->load( { app_prove => $app, args => ['config=c1'] } ), 'load accepts config=' );
    is( $app->{harness}, 'Git::TMS::Harness', 'it sets the harness class' );
    is( $app->{merge},   1,                   'and turns on merge' );

    my $quiet = mock {} => ( add => [ harness => sub { }, merge => sub { $_[0]->{merge} = $_[1] } ] );
    App::Prove::Plugin::GitTMS->load( { app_prove => $quiet, args => [ 'config=c1', 'merge=0' ] } );
    ok( !exists $quiet->{merge}, 'merge=0 leaves merge off' );

    like( dies { App::Prove::Plugin::GitTMS->load( { app_prove => $app, args => ['colour=red'] } ) }, qr/does[ ]not[ ]know[ ]the[ ]argument[ ]'colour=red'/sx, 'an unknown argument is refused' );
    like( dies { App::Prove::Plugin::GitTMS->load( { app_prove => $app, args => ['config'] } ) },     qr/does[ ]not[ ]know[ ]the[ ]argument[ ]'config'/sx,     'an argument with no value is refused' );
};

subtest a_run_of_prove => sub {
    my $root   = scratch();
    my $repo   = new_repo( $root, 'work' );
    my $filter = write_file( $root, 'filter.pl', "while (<STDIN>) { s/token=\\S+/token=[filtered]/g; print }\n" );
    foreach my $path ( sort keys %FIXTURES ) {
        commit_file( $repo, $path, $FIXTURES{$path} );
    }
    git( $repo, 'config', 'tms.outputFilter', qq{"$^X" "$filter"} );

    my ( $exit, $out, $err ) = prove( $repo, '-PGitTMS=config=linux-test', 't' );
    is( $exit, 1, 'prove fails, because some tests fail' ) or diag( $out, $err );

    my $by = records_by_test($repo);
    is( [ sort keys %$by ],                               [ sort keys %FIXTURES ],  'every test file has a record' );
    is( [ map { scalar @{ $by->{$_} } } sort keys %$by ], [ (1) x keys %FIXTURES ], 'one record for each file' );
    my %r = map { $_ => $by->{$_}[0] } keys %$by;

    is( $r{'t/pass.t'}, { v => 1, run => D(), test => 't/pass.t', status => 'pass', elapsed => D(), config => 'linux-test' }, 'a passing test keeps no output, not even its diagnostics' );
    my %runs = map { $_->{run} => 1 } values %r;
    is( \%runs, { $r{'t/pass.t'}{run} => 1 }, 'all the records share the run' );
    ok( $r{'t/pass.t'}{elapsed} >= 0, 'and each has a time' );

    is( $r{'t/fail.t'}{status}, 'fail', 'a failing test is a failure' );
    is( $r{'t/fail.t'}{failed}, 1,      'with the count of failed assertions' );
    my $assertion = qr/not \s ok \s 2 \s - \s adds/sx;
    like( $r{'t/fail.t'}{output}, qr/\A $assertion \n \# \s+ Failed \s test \s 'adds' \n/sx, 'its output is the failed assertion' );
    like( $r{'t/fail.t'}{output}, qr/got: \s '1' \n \# \s+ expected: \s '2' \n/sx,           'with its diagnostics' );
    unlike( $r{'t/fail.t'}{output}, qr/ok[ ]1[ ]-[ ]good/sx, 'and not the assertion that passed' );

    is( $r{'t/skip.t'}{status}, 'skip', 'a skipped file is a skip' );
    like( $r{'t/skip.t'}{reason}, qr/no[ ]network/sx, 'with its reason' );

    is( $r{'t/die.t'}{status}, 'fail', 'a test that dies is a failure' );
    is( $r{'t/die.t'}{exit},   255,    'with its exit status' );
    like( $r{'t/die.t'}{output},                    qr/kaboom/sx,            'and the message of the die' );
    like( join( q{ }, @{ $r{'t/die.t'}{errors} } ), qr/No[ ]plan[ ]found/sx, 'and the problem that the harness found' );

    like( $r{'t/subtest.t'}{output}, qr/^[ ][ ][ ][ ]not[ ]ok[ ]2[ ]-[ ]inner[ ]bad\n/msx, 'the failure inside a subtest is kept' );
    like( $r{'t/subtest.t'}{output}, qr/^not[ ]ok[ ]1[ ]-[ ]outer\n/msx,                   'and the subtest that it failed' );
    unlike( $r{'t/subtest.t'}{output}, qr/todo[ ]failure/sx, 'a TODO failure is not' );
    unlike( $r{'t/subtest.t'}{output}, qr/inner[ ]good/sx,   'nor an assertion that passed' );

    like( $r{'t/secret.t'}{output}, qr/token=\[filtered\]/sx, 'tms.outputFilter removes the secret' );
    unlike( $r{'t/secret.t'}{output}, qr/SECRET42/sx, 'so it is not in the note' );
};

subtest a_bail_out => sub {
    my $root = scratch();
    my $repo = new_repo( $root, 'work' );
    commit_file( $repo, 't/a.t', "print qq{1..2\\nok 1\\nBail out! the database is gone\\n};\n" );
    commit_file( $repo, 't/b.t', "print qq{1..1\\nok 1\\n};\n" );

    my ( $exit, $out, $err ) = prove( $repo, qw{-PGitTMS=config=c1 t/a.t t/b.t} );
    isnt( $exit, 0, 'prove stops' );
    like( $out . $err, qr/FAILED--Further[ ]testing[ ]stopped/sx, 'because of the bail out' );

    my $by = records_by_test($repo);
    is( [ sort keys %$by ],        ['t/a.t'], 'the file that bailed out is recorded, and the file that never ran is not' );
    is( $by->{'t/a.t'}[0]{status}, 'bailout', 'its status is bailout' );
    like( $by->{'t/a.t'}[0]{output}, qr/Bail[ ]out![ ]the[ ]database[ ]is[ ]gone/sx, 'and its output says why' );
};

subtest a_changed_work_tree => sub {
    my $root = scratch();
    my $repo = new_repo( $root, 'work' );
    commit_file( $repo, 't/pass.t', $FIXTURES{'t/pass.t'} );
    write_file( $repo, 't/pass.t', $FIXTURES{'t/pass.t'} . "# changed\n" );

    my ( $exit, $out, $err ) = prove( $repo, '-PGitTMS=config=c1', 't' );
    is( $exit, 0, 'the tests still run and pass' ) or diag( $out, $err );
    like( $err, qr/no \s results \s are \s recorded .* differ \s from \s HEAD/sx, 'prove warns that it records nothing' );
    is( git( $repo, qw{for-each-ref refs/notes} ), q{}, 'and no notes ref exists' );
};

done_testing;
