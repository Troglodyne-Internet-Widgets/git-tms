#!perl

use 5.014;

use strict;
use warnings FATAL => 'all';

use re '/aa';

use Test2::V1 qw{subtest is like dies done_testing};
use Test2::Plugin::NoWarnings;

use FindBin::libs;
use Test::MockModule qw{strict};

use Git::TMS::TestRepo qw{scratch new_repo commit_file};

use Git::TMS::Git ();

subtest run_and_call => sub {
    my $repo = new_repo( scratch(), 'work with space' );
    my $git  = Git::TMS::Git->new( dir => $repo );

    is( $git->run(qw{rev-parse --is-inside-work-tree}),   "true\n",                                     'run returns what git printed, in a directory with a space in its name' );
    is( $git->run( \"hello\n", qw{hash-object --stdin} ), "ce013625030ba8dba906f756967f9e9ca394464a\n", 'a reference to a scalar is the standard input' );

    my ( $exit, $out ) = $git->call(qw{rev-parse --verify --quiet HEAD});
    is( $exit, 1,   'call returns the exit status of a git that failed' );
    is( $out,  q{}, 'and what it printed' );

    my $status = qr/failed \s with \s status \s 128: \s fatal:/sx;
    like( dies { $git->run(qw{rev-parse --verify HEAD}) }, qr/\A git \s rev-parse \s --verify \s HEAD \s $status/sx, 'run dies with the command and the error of git' );
};

subtest config => sub {
    my $repo = new_repo( scratch(), 'work' );
    my $git  = Git::TMS::Git->new( dir => $repo );
    is( $git->config('tms.remote'), undef, 'a value that is not set is undef' );
    $git->run(qw{config tms.remote results});
    is( $git->config('tms.remote'), 'results', 'a value that is set comes back without its line end' );
};

subtest ensure_identity => sub {
    my $repo = new_repo( scratch(), q{work} );
    commit_file( $repo, q{a.txt}, "a\n" );

    {
        local @ENV{qw{GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL}} = qw{Someone someone@test.test};
        my $git = Git::TMS::Git->new( dir => $repo );
        is( $git->ensure_identity, 0, q{an identity that git finds is kept} );
    }

    my $mock = Test::MockModule->new(q{Git::TMS::Git});
    my $call = $mock->original(q{call});
    $mock->redefine( call => sub { my ( $self, @args ) = @_; return $args[0] eq q{var} ? (128) : $call->(@_) } );

    my $git = Git::TMS::Git->new( dir => $repo );
    is( $git->ensure_identity, 1, q{without an identity, it supplies one} );
    is( $git->ensure_identity, 0, q{and checks only once} );
    $git->run(qw{notes add -m checked HEAD});
    is( $git->run(qw{log -1 --format=%an%n%ae refs/notes/commits}), "git-tms\ngit-tms\@invalid\n", q{the commit of the note carries the supplied identity} );
};

done_testing;
