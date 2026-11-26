package Git::TMS;

# ABSTRACT: Keep the results of test runs in git notes, one notes ref for each configuration

use 5.014;

use strict;
use warnings FATAL => 'all';

1;

__END__

=head1 USAGE

A CI job runs the tests with a harness plugin, and pushes the results:

    prove -l -PGitTMS=config=linux-perl5.40 t
    # or
    yath test -pGitTMS=config=linux-perl5.40 t

    git tms push origin

Anybody with a clone then reads them:

    git tms fetch origin
    git tms results HEAD
    git tms results --raw --config linux-perl5.40 HEAD~5..HEAD
    git tms scan --where-fails t/a.t HEAD

=head1 DESCRIPTION

Developers do not use test management systems, so nobody can see how a test
behaved over time.  Git::TMS keeps the results of test runs inside the git
repository, as git notes.  A CI matrix fills them, and each configuration of
the matrix writes its own notes ref.  The results outlive any CI server.

There are three parts:

=over

=item The harness plugins

L<App::Prove::Plugin::GitTMS> for prove, and L<App::Yath::Plugin::GitTMS> for
yath.  Each one writes one record for each test file to the local clone.  They
share L<Git::TMS::Recorder>.

=item The program C<git tms>

It reads the records, and pushes and fetches them.  See L<git-tms>.

=item The store

L<Git::TMS::Store> reads and writes the notes, and does the push, the fetch and
the merge.

=back

The plugins write only to the local clone.  A separate step pushes.  So a
network failure never changes the result of a test run.

=head1 HOW THE RESULTS ARE KEPT

=head2 On the tree, not on the commit

Each note hangs on the id of the tree that was tested.  A commit finds its
results through its tree.  Two commits with the same tree share results,
because they hold the same code.  An amend or a rebase that keeps the tree
keeps the results.

The plugins record nothing when a tracked file differs from C<HEAD>, because
then no tree id describes the code that ran.  They warn once, and the tests run
as usual.  Untracked files, such as F<blib/>, do not count.

C<git log --notes> does not show notes on trees.  Use C<git tms results>.

=head2 One ref for each configuration

A configuration is one cell of a CI matrix, such as C<linux-perl5.40>.  The
CI job names it.  Its results go to F<refs/notes/tms/results/NAME>.  So two
configurations never race each other when they push.  A host name is not a
configuration: hosts come and go, and the results of a configuration do not
depend on which host ran it.

A name has letters, digits, C<.>, C<_>, C<+> and C<->, and starts with a
letter or a digit.  Without a name, the plugins read C<GIT_TMS_CONFIG>, and
then make one from the operating system and the version of perl, such as
C<linux-perl5.40.1>.

Two jobs of one configuration on one tree can still push at the same time.
C<git tms push> then fetches the ref that won, merges it, and pushes again.

=head2 THE RECORD

A note holds one JSON object for each line, sorted, with no duplicates.  The
C<cat_sort_uniq> strategy of C<git notes merge> keeps that format, so two
notes merge without a conflict.

Each record describes one run of one test file:

    {"elapsed":0.212,"run":"20261124T100000Z-1a2b3c4d","status":"pass","test":"t/a.t","v":1}

A record of a test that did not pass also says what went wrong:

    {"elapsed":1.92,"exit":1,"failed":1,"output":"not ok 2 - adds\n#   Failed test 'adds'\n...",
     "run":"20261124T100000Z-1a2b3c4d","status":"fail","test":"t/b.t","v":1}

=over

=item v

The version of the format, 1.

=item run

The run of the harness that wrote the record: the time in UTC, and a random
part.  The records of one run share it.

=item test

The path of the test file from the top of the work tree, with C</> between its
parts on every platform.

=item status

C<pass>, C<fail>, C<skip> (the whole file skipped), or C<bailout>.

=item elapsed

The seconds that the test file took.  A time far outside the usual times of a
test is often a real problem.

=item exit, failed, errors, reason

The exit status, how many assertions failed, the problems that the harness
found (such as a wrong plan), and why the file skipped.  Each one is there only
when it has a value, and only when the status is not C<pass>.

=item output

Only when the status is not C<pass>: each failed assertion with its
diagnostics, and the lines that are not TAP, such as the message of a C<die>.
The output of a test that passed is not kept.

=item cut

1 when the output was longer than C<tms.maxOutput> and was cut.

=item try

For yath, which retry of the test file this was.

=back

Records carry no host name and no versions of dependencies.  The name of the
configuration says what the configuration is.

=head1 CONFIGURATION

The plugins and C<git tms> read these values of the git configuration:

=over

=item tms.remote

The remote that C<git tms push> and C<git tms fetch> use when the command line
names none.  The default is C<origin>.

=item tms.outputFilter

A command that the system shell runs on the output of each test that did not
pass, before the output goes into a record.  The output is its standard input,
and its standard output replaces the output.  If it fails, the record keeps no
output.

=item tms.maxOutput

The most characters of output that one record keeps.  The default is 16384.

=back

=head1 SECRETS IN OUTPUT

A test can print a token, a password or a private path when it fails.  After a
push, that output is in every clone that fetches the results, and nobody can
take it out of those clones.  Set C<tms.outputFilter> to a command that removes
such values, for example:

    git config tms.outputFilter "perl -pe 's/(token=)\\S+/\$1[filtered]/g'"

=head1 WHERE THE NOTES LIVE

By default, the notes go to the remote of the code, C<origin>.  For a large
repository, or for CI that must not write to the code, keep them in a
separate results repository.  A push of notes sends the notes and not the
trees, so the results repository needs none of the code:

    git remote add results https://git.test.test/results.git
    git config tms.remote results

=head1 A CI MATRIX

This GitHub Actions workflow runs two configurations and pushes the results of
each.  C<actions/checkout> does not fetch notes, and its token needs C<contents:
write> to push them.

    name: test
    on: [push]
    permissions:
      contents: write
    jobs:
      test:
        strategy:
          matrix:
            include:
              - os: ubuntu-latest
                config: linux-perl5.40
              - os: windows-latest
                config: windows-perl5.40
        runs-on: ${{ matrix.os }}
        steps:
          - uses: actions/checkout@v4
          - uses: shogo82148/actions-setup-perl@v1
            with:
              perl-version: '5.40'
          - run: cpanm --notest --installdeps . Git::TMS
          - run: prove -l -PGitTMS=config=${{ matrix.config }} t
          - if: always()
            run: git tms push origin

The last step runs after a failure as well, because the failures are what the
results are for.

=head1 CAVEATS

=over

=item git notes prune

C<git notes prune> deletes each note whose tree is not in the local
repository.  In a shallow clone, that is most of them.  C<git tms> never runs
it.  Do not run it on a results ref.

=item Forges

A forge stores the notes refs as it stores any other ref, but none shows notes
on trees in its web interface.  Nobody has tested a push to each forge yet.

=back

=head1 SEE ALSO

L<git-tms>

L<App::Prove::Plugin::GitTMS>

L<App::Yath::Plugin::GitTMS>

L<Git::TMS::Store>

=cut
