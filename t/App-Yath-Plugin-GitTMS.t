#!perl

use 5.014;

use strict;
use warnings FATAL => 'all';

use re '/aa';

no autovivification;

use Test2::V1 qw{subtest ok is isnt like unlike dies D done_testing diag skip_all};
use Test2::Plugin::NoWarnings;

use Cwd        ();
use File::Spec ();
use FindBin::libs;
use IPC::Run3 ();

use Git::TMS::TestRepo qw{scratch git new_repo commit_file in_dir};

use App::Yath::Plugin::GitTMS ();
use Git::TMS::Store           ();

# The directory that Git::TMS was loaded from, lib or blib/lib, for the perl that runs yath.
my $LIB = Cwd::abs_path( File::Spec->catdir( ( File::Spec->splitpath( Cwd::abs_path( $INC{'Git/TMS/Store.pm'} ) ) )[1], File::Spec->updir, File::Spec->updir ) );

# The yath program beside this perl, or the first one on the PATH.
my $YATH;
foreach my $dir ( ( File::Spec->splitpath($^X) )[1], File::Spec->path ) {
    my $candidate = File::Spec->catfile( $dir, 'yath' );
    next if !-e $candidate;
    $YATH = $candidate;
    last;
}

my %FIXTURES = (
    't/pass.t'    => "use Test2::V0; ok( 1, 'fine' ); diag('chatty on a pass'); done_testing;\n",
    't/fail.t'    => "use Test2::V0; ok( 1, 'good' ); is( 1, 2, 'adds' ); done_testing;\n",
    't/skip.t'    => "use Test2::V0; skip_all('no network');\n",
    't/die.t'     => "use Test2::V0; ok( 1, 'before' ); die qq{kaboom\\n};\n",
    't/subtest.t' => <<'TEST',
use Test2::V0;
subtest outer => sub { ok( 1, 'inner good' ); ok( 0, 'inner bad' ); };
todo later => sub { ok( 0, 'todo failure' ) };
done_testing;
TEST
);

subtest new => sub {
    my $plugin = App::Yath::Plugin::GitTMS->new('config=c1');
    is( $plugin->{config}, 'c1', 'new takes config=' );
    like( dies { App::Yath::Plugin::GitTMS->new('colour=red') }, qr/does[ ]not[ ]know[ ]the[ ]argument[ ]'colour=red'/sx, 'an unknown argument is refused' );
    is( $plugin->finish, 0, 'a run that saw no event writes nothing, and never looks at git' );
};

subtest a_run_of_yath => sub {
    skip_all('no yath program was found') if !$YATH;

    my $root = scratch();
    my $repo = new_repo( $root, 'work' );
    foreach my $path ( sort keys %FIXTURES ) {
        commit_file( $repo, $path, $FIXTURES{$path} );
    }

    my ( $out, $err ) = ( q{}, q{} );
    in_dir(
        $repo,
        sub {
            local $ENV{YATH_TEMP_DIR} = scratch();
            IPC::Run3::run3( [ $^X, "-I$LIB", $YATH, qw{test --no-color -pGitTMS=config=yath-test --retry 1 t} ], \undef, \$out, \$err );
        },
    );
    isnt( $? >> 8, 0, 'yath fails, because some tests fail' ) or diag( $out, $err );

    my $tree = git( $repo, qw{rev-parse HEAD^{tree}} );
    my %by;
    push @{ $by{ $_->{test} } }, $_ foreach @{ Git::TMS::Store->new( dir => $repo )->records( [$tree] )->{$tree} // [] };
    is( [ sort keys %by ], [ sort keys %FIXTURES ], 'every test file has a record' ) or diag( $out, $err );

    is( [ map { "$_->{status} " . ( $_->{try} // 0 ) } @{ $by{'t/fail.t'} } ], [ 'fail 0', 'fail 1' ], 'a failing file that yath retried has a record for each try' );
    my %r = map { $_ => $by{$_}[0] } keys %by;

    is( $r{'t/pass.t'}, { v => 1, run => D(), test => 't/pass.t', status => 'pass', elapsed => D(), config => 'yath-test' }, 'a passing test keeps no output' );
    ok( $r{'t/pass.t'}{elapsed} > 0, 'and has a time' );

    is( $r{'t/fail.t'}{failed}, 1, 'a failure counts its failed assertions' );
    like( $r{'t/fail.t'}{output}, qr/\Anot[ ]ok[ ]-[ ]adds\n/sx,                                 'its output starts with the failed assertion' );
    like( $r{'t/fail.t'}{output}, qr/^\# \s* [|] \s* 1 \s* [|] \s* eq \s* [|] \s* 2 \s* [|]/msx, 'and has its diagnostics' );
    unlike( $r{'t/fail.t'}{output}, qr/good/sx, 'and not the assertion that passed' );

    is( $r{'t/skip.t'}{status}, 'skip', 'a skipped file is a skip' );
    like( $r{'t/skip.t'}{reason}, qr/no[ ]network/sx, 'with its reason' );

    is( $r{'t/die.t'}{status}, 'fail', 'a test that dies is a failure' );
    is( $r{'t/die.t'}{exit},   255,    'with its exit status' );
    like( $r{'t/die.t'}{output}, qr/kaboom/sx, 'and the message of the die' );

    like( $r{'t/subtest.t'}{output}, qr/^not[ ]ok[ ]-[ ]outer\n/msx,                   'a failing subtest is kept' );
    like( $r{'t/subtest.t'}{output}, qr/^[ ][ ][ ][ ]not[ ]ok[ ]-[ ]inner[ ]bad\n/msx, 'with the failure inside it, indented' );
    is( scalar( () = $r{'t/subtest.t'}{output} =~ m/not \s ok \s - \s inner \s bad/gsx ), 1, 'once, though yath also sends it as an event of its own' );
    is( $r{'t/subtest.t'}{failed},                                                        1, 'and the failures count the subtest, not each failure inside it' );
    unlike( $r{'t/subtest.t'}{output}, qr/todo[ ]failure|inner[ ]good/sx, 'and not a TODO failure, nor an assertion that passed' );
};

done_testing;
