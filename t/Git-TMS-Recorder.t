#!perl

use 5.014;

use strict;
use warnings FATAL => 'all';

use re '/aa';

use Test2::V1 qw{subtest ok is isnt like dies warning D done_testing};
use Test2::Plugin::NoWarnings;

use File::Spec ();
use FindBin::libs;

use Git::TMS::TestRepo qw{scratch git new_repo commit_file write_file in_dir};

use Git::TMS::Recorder ();
use Git::TMS::Store    ();

# A repository with one commit, and a recorder for it.
sub setup {
    my (%args) = @_;
    my $root   = scratch();
    my $repo   = new_repo( $root, 'work' );
    commit_file( $repo, 't/a.t', "1;\n" );
    foreach my $key ( sort keys %args ) {
        git( $repo, 'config', $key, $args{$key} );
    }
    return ( $repo, Git::TMS::Recorder->new( config => 'c1', dir => $repo ) );
}

subtest new => sub {
    my ( $repo, $recorder ) = setup();
    is( $recorder->tree,   git( $repo, qw{rev-parse HEAD^{tree}} ), 'the recorder takes the tree of HEAD' );
    is( $recorder->config, 'c1',                                    'and the configuration that it was given' );

    local $ENV{GIT_TMS_CONFIG} = 'from-env';
    is( Git::TMS::Recorder->new( dir => $repo )->config, 'from-env', 'GIT_TMS_CONFIG names the configuration when nothing else does' );
    delete local $ENV{GIT_TMS_CONFIG};
    is( Git::TMS::Recorder->new( dir => $repo )->config, Git::TMS::Recorder::default_config(), 'then the default' );

    like( dies { Git::TMS::Recorder->new( config => 'a/b', dir => $repo ) }, qr/not[ ]usable/sx, 'a configuration name that cannot be a ref is refused' );

    write_file( $repo, 't/a.t', "2;\n" );
    my $dirty;
    my $err = warning { $dirty = Git::TMS::Recorder->new( config => 'c1', dir => $repo ) };
    like( $err, qr/no \s results \s are \s recorded .* tracked \s files \s differ/sx, 'a changed tracked file warns once' );
    is( $dirty->tree,                                     undef, 'and leaves no tree' );
    is( $dirty->add( test => 't/a.t', status => 'pass' ), undef, 'so add keeps nothing' );
    is( $dirty->finish,                                   0,     'and finish writes nothing' );

    git( $repo, qw{checkout -- t/a.t} );
    git( $repo, qw{config tms.maxOutput lots} );
    like( dies { Git::TMS::Recorder->new( config => 'c1', dir => $repo ) }, qr/tms.maxOutput[ ]is[ ]'lots'/sx, 'a tms.maxOutput that is not a number is refused' );
};

subtest default_config_and_run_id => sub {
    my $os = quotemeta $^O;
    like( Git::TMS::Recorder::default_config(), qr/\A $os -perl5 [.] \d+ [.] \d+ \z/sx, 'the default names the operating system and the perl' );
    ok( Git::TMS::Store::check_name( configuration => Git::TMS::Recorder::default_config() ), 'and can be a ref' );
    my $run = Git::TMS::Recorder::run_id();
    like( $run, qr/\A\d{8}T\d{6}Z-[[:xdigit:]]{8}\z/sx, 'a run id is the time and random hex' );
    isnt( Git::TMS::Recorder::run_id(), $run, 'two run ids differ' );
};

subtest test_path => sub {
    my ( $repo, $recorder ) = setup();
    in_dir(
        $repo,
        sub {
            is( $recorder->test_path('t/a.t'),                                    't/a.t', 'a path from the top stays' );
            is( $recorder->test_path( File::Spec->catfile( $repo, 't', 'a.t' ) ), 't/a.t', 'an absolute path becomes a path from the top' );
            is( $recorder->test_path( File::Spec->catfile(qw{t .. t a.t}) ),      't/a.t', 'a path through .. is resolved' );
        },
    );
    in_dir( File::Spec->catdir( $repo, 't' ), sub { is( $recorder->test_path('a.t'), 't/a.t', 'a path from a subdirectory becomes a path from the top' ) } );
    my $outside = scratch();
    is( $recorder->test_path( File::Spec->catfile( $outside, 'x.t' ) ), File::Spec->catfile( $outside, 'x.t' ) =~ tr{\\}{/}r, 'a file outside the work tree keeps its path' );
};

subtest add => sub {
    my ( undef, $recorder ) = setup();

    like( dies { $recorder->add( test => 't/a.t', status => 'ok' ) }, qr/'ok'[ ]is[ ]not[ ]a[ ]status/sx, 'an unknown status is refused' );
    like( dies { $recorder->add( test => 't/a.t' ) },                 qr/''[ ]is[ ]not[ ]a[ ]status/sx,   'a missing status is refused' );

    my $pass = $recorder->add( test => 't/a.t', status => 'pass', elapsed => 0.12345, exit => 0, failed => 0, output => "noise\n", errors => ['x'] );
    is( $pass, { v => 1, run => D(), test => 't/a.t', status => 'pass', elapsed => 0.123 }, 'a passing test keeps only the time, and no output' );

    my $fail = $recorder->add( test => 't/a.t', status => 'fail', elapsed => 2, exit => 1, failed => 2, errors => ['Bad plan'], output => "not ok 1\n", try => 1 );
    is(
        $fail,
        { v => 1, run => $pass->{run}, test => 't/a.t', status => 'fail', elapsed => 2, exit => 1, failed => 2, errors => ['Bad plan'], output => "not ok 1\n", try => 1 },
        'a failing test keeps what went wrong',
    );

    my $skip = $recorder->add( test => 't/a.t', status => 'skip', elapsed => 0, reason => 'no network', errors => [], output => q{} );
    is( $skip, { v => 1, run => $pass->{run}, test => 't/a.t', status => 'skip', elapsed => 0, reason => 'no network' }, 'empty facts are left out' );
};

subtest output_filter_and_cut => sub {
    my $dir    = scratch();
    my $filter = write_file( $dir, q{filter.pl}, "while (<STDIN>) { s/SECRET\\S*/[filtered]/g; print }\n" );
    my ( undef, $recorder ) = setup( 'tms.outputFilter' => qq{"$^X" "$filter"}, 'tms.maxOutput' => 20 );

    my $record = $recorder->add( test => 't/a.t', status => 'fail', output => 'token SECRET123 ' . chr(233) . "\n" );
    is( $record->{output}, 'token [filtered] ' . chr(233) . "\n", 'the filter removes the secret, and characters survive it' );
    ok( !$record->{cut}, 'output within tms.maxOutput is not cut' );

    $record = $recorder->add( test => 't/a.t', status => 'fail', output => ( 'x' x 30 ) . "\n" );
    is( $record->{output}, 'x' x 20, 'longer output is cut to tms.maxOutput characters' );
    is( $record->{cut},    1,        'and says so' );

    my ( undef, $failing ) = setup( 'tms.outputFilter' => qq{"$^X" -e "exit 3"} );
    my $kept;
    my $err = warning { $kept = $failing->add( test => 't/a.t', status => 'fail', output => "SECRET\n" ) };
    ok( !exists $kept->{output}, 'when the filter fails, the record keeps no output' );
    like( $err, qr/tms.outputFilter \s failed .* t\/a.t \s keeps \s no \s output/sx, 'and the recorder warns' );
};

subtest finish => sub {
    my ( $repo, $recorder ) = setup();
    is( $recorder->finish, 0, 'a run with no records writes nothing' );

    $recorder->add( test => 't/a.t', status => 'pass', elapsed => 1 );
    $recorder->add( test => 't/b.t', status => 'fail', elapsed => 1, output => "not ok 1\n" );
    is( $recorder->finish, 2, 'finish writes the records' );

    my $tree    = $recorder->tree;
    my $records = Git::TMS::Store->new( dir => $repo )->records( [$tree] )->{$tree};
    is( [ map { "$_->{config} $_->{test} $_->{status}" } @$records ], [ 'c1 t/a.t pass', 'c1 t/b.t fail' ], 'and the store reads them back' );
    is( $recorder->finish,                                            0,                                    'a second finish writes nothing more' );

    $recorder->add( test => 't/a.t', status => 'pass' );
    git( $repo, qw{update-ref refs/notes/tms/results/c1 HEAD^{tree}} );
    my $written;
    my $err = warning { $written = $recorder->finish };
    is( $written, 0, 'when git cannot write the note, finish writes nothing' );
    like( $err, qr/the[ ]results[ ]of[ ]this[ ]run[ ]were[ ]not[ ]recorded/sx, 'and warns, rather than dies' );
};

done_testing;
