#!perl

use 5.014;

use strict;
use warnings FATAL => 'all';

use re '/aa';

use Test2::V1 qw{subtest is like dies done_testing};
use Test2::Plugin::NoWarnings;

use FindBin::libs;

use Git::TMS::Harness ();

subtest abnormal_output => sub {
    is( Git::TMS::Harness::abnormal_output( 'TAP version 13', '1..2', 'ok 1 - a', '# a comment', 'ok 2 - b' ), q{}, 'a run with no failure keeps nothing' );

    is(
        Git::TMS::Harness::abnormal_output( 'ok 1 - a', '# noise after a pass', 'not ok 2 - b', '#   Failed test', '#   got 1', 'ok 3 - c', '# noise again', '1..3', '# Looks like you failed 1' ),
        "not ok 2 - b\n#   Failed test\n#   got 1\n",
        'a failed assertion keeps its diagnostics up to the next assertion',
    );

    is( Git::TMS::Harness::abnormal_output( 'not ok 1 - later # TODO not yet', '#   Failed (TODO) test', 'ok 2' ), q{}, 'a TODO failure and its diagnostics are not kept' );

    is(
        Git::TMS::Harness::abnormal_output( '# Subtest: s', '    ok 1 - in', '    not ok 2 - bad in', '    #   Failed test', '    1..2', 'not ok 1 - s' ),
        "    not ok 2 - bad in\n    #   Failed test\nnot ok 1 - s\n",
        'an indented failure inside a subtest is kept, with its diagnostics',
    );

    is( Git::TMS::Harness::abnormal_output( 'ok 1', 'Bail out! no database' ),           "Bail out! no database\n",          'a bail out is kept' );
    is( Git::TMS::Harness::abnormal_output( 'ok 1', 'Died at t/a.t line 3.', q{} ),      "Died at t/a.t line 3.\n",          'a line that is not TAP is kept, an empty line is not' );
    is( Git::TMS::Harness::abnormal_output( 'not ok 1 - caf' . pack( 'C*', 195, 169 ) ), 'not ok 1 - caf' . chr(233) . "\n", 'the bytes are decoded from UTF-8' );
    is( Git::TMS::Harness::abnormal_output( 'not ok 1 - ' . pack( 'C', 255 ) ),          'not ok 1 - ' . chr(65_533) . "\n", 'a byte that is not UTF-8 becomes the replacement character' );
};

subtest configure => sub {
    Git::TMS::Harness->configure( config => 'a/b' );
    like( dies { Git::TMS::Harness->new( {} ) }, qr/configuration \s name \s 'a\/b' \s is \s not \s usable/sx, 'a new harness makes its recorder with the configured arguments' );
    Git::TMS::Harness->configure();
};

done_testing;
