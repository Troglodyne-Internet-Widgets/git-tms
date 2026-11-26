package Git::TMS::CLI;

# ABSTRACT: The commands of git tms

use 5.014;

use strict;
use warnings FATAL => 'all';

use re '/aa';

no autovivification;

use Readonly;

use Getopt::Long    ();
use Git::TMS::Store ();
use Pod::Usage      ();

Readonly my %COMMANDS => (
    results => \&results,
    scan    => \&scan,
    push    => \&push_results,
    fetch   => \&fetch_results,
    help    => \&show_commands,
);

=head1 SYNOPSIS

    use Git::TMS::CLI;
    exit Git::TMS::CLI::main(@ARGV);

=head1 DESCRIPTION

This is the program F<git-tms>.  Each command prints to standard output.  A
message about a problem goes to standard error.

=head1 USAGE

    git tms results [--config NAME]... [--raw] [REVISION | RANGE]
    git tms scan --where-fails TEST [REVISION]
    git tms push [REMOTE]
    git tms fetch [REMOTE]
    git tms help

=head1 COMMANDS

=over

=item results [--config NAME]... [--raw] [REVISION | RANGE]

For each commit, print its id and the id of its tree, and then one line for
each record of the tree: the status, the configuration, the test, the seconds
it took, and what went wrong.  The default revision is C<HEAD>.  An argument
with C<..> in it is a range, as C<git log> takes it.

C<--config> shows only the named configuration.  Give it more than once for
more than one.  C<--raw> adds the output that each record kept, below its
line.

The command reads the local results refs and the refs that C<git tms fetch>
copied.  A record that both hold shows once.

=item scan --where-fails TEST [REVISION]

Print each configuration that has a record of TEST at the revision whose
status is C<fail> or C<bailout>, with how many of its runs failed.  TEST is the
path of the test file from the top of the work tree, such as F<t/a.t>.  The
default revision is C<HEAD>.

=item push [REMOTE]

Push every local results ref to the remote.  When the remote refuses a ref
because another job pushed to it first, the command fetches that ref, merges
it, and pushes again, up to three times.

=item fetch [REMOTE]

Fetch every results ref of the remote into
F<refs/notes/tms-remote/REMOTE/results/>.

=item help

Print the usage and this list of commands.

=back

For C<push> and C<fetch>, the default remote is the value of C<tms.remote> in
the git configuration, and then C<origin>.  Set C<tms.remote> to keep the
results in a repository other than the code.

=head1 EXIT STATUS

0 when the command did its work, 1 when it failed, and 2 when the command line
is wrong.

=cut

# Run one command of git tms.
# @param   @args  Str  the command line, the command first
# @returns Int  the exit status: 0 for success, 1 when the command failed, 2 when the command line is wrong
# @example exit Git::TMS::CLI::main( 'results', 'HEAD' );
sub main {
    my (@args) = @_;

    my $name = shift @args;
    if ( !defined $name || !$COMMANDS{$name} ) {
        warn "git-tms: '$name' is not a command.\n" if defined $name;
        print_pod( \*STDERR, 'USAGE' );
        return 2;
    }

    my $status;
    my $ok = eval { $status = $COMMANDS{$name}->( Git::TMS::Store->new(), @args ); 1 };
    if ( !$ok ) {
        my $error = $@;
        warn index( $error, 'git-tms: ' ) == 0 ? $error : "git-tms: $error";
        return 1;
    }
    return $status;
}

# Print sections of the POD of this module.
# @param   handle     Ref  the file handle to print them to, such as \*STDOUT
# @param   @sections  Str  the names of the sections
# @returns Undef
# @example Git::TMS::CLI::print_pod( \*STDOUT, 'USAGE' );
sub print_pod {
    my ( $handle, @sections ) = @_;
    Pod::Usage::pod2usage( -input => __FILE__, -verbose => 99, -sections => \@sections, -exitval => 'NOEXIT', -output => $handle );
    return;
}

# git tms help: print the usage and the commands.
# @returns Int  0
# @example Git::TMS::CLI::show_commands();
sub show_commands {
    print_pod( \*STDOUT, qw{USAGE COMMANDS} );
    return 0;
}

# Parse the options of a command.
# @param   args  ArrayRef[Str]  the arguments; the options are taken out of it
# @param   @spec  Str  the options, as Getopt::Long takes them
# @returns HashRef  the options that were given
# @throws  what Getopt::Long says about an option that is wrong
# @example my $opts = Git::TMS::CLI::options( \@args, 'raw', 'config=s@' );
sub options {
    my ( $args, @spec ) = @_;

    my %opts;
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $parser = Getopt::Long::Parser->new( config => [qw{no_ignore_case bundling}] );
    die "git-tms: @warnings" if !$parser->getoptionsfromarray( $args, \%opts, @spec );
    return \%opts;
}

# The remote that push and fetch use: the one named, then tms.remote, then
# origin.
# @param   store   Git::TMS::Store  the store
# @param   remote  Str  the remote on the command line
# @returns Str  the name of the remote
# @example my $remote = Git::TMS::CLI::remote( $store, undef );
sub remote {
    my ( $store, $remote ) = @_;
    return $remote // $store->git->config('tms.remote') // 'origin';
}

# The commit and the tree of each commit of a revision or a range.  A
# revision is one commit.  An argument with .. in it is a range, as git log
# takes it.
# @param   store  Git::TMS::Store  the store
# @param   what   Str  the revision or the range
# @returns ArrayRef[ArrayRef[Str]]  a pair of commit id and tree id for each commit, newest first
# @throws  when git does not know the revision
# @example my $pairs = Git::TMS::CLI::commits( $store, 'HEAD~3..HEAD' );
sub commits {
    my ( $store, $what ) = @_;

    my @log = index( $what, q{..} ) >= 0 ? ($what) : ( '--no-walk', "$what^{commit}" );
    my $out = $store->git->run( 'log', '--format=%H %T', @log, q{--} );
    return [ map { [ split q{ } ] } split m/\n/sx, $out ];
}

# git tms results: show the records of each commit of a revision or a range.
# @param   store  Git::TMS::Store  the store
# @param   @args  Str  the options and the revision
# @returns Int  0
# @throws  when an option is wrong, or when there is more than one revision
# @example Git::TMS::CLI::results( $store, '--raw', 'HEAD' );
sub results {
    my ( $store, @args ) = @_;

    my $opts = options( \@args, 'config=s@', 'raw' );
    die "git-tms: results takes one revision or range.\n" if @args > 1;
    my $pairs   = commits( $store, $args[0] // 'HEAD' );
    my $by_tree = $store->records( [ map { $_->[1] } @$pairs ], configs => $opts->{config} );

    foreach my $pair (@$pairs) {
        my ( $commit, $tree ) = @$pair;
        my $records = $by_tree->{$tree} // [];
        my @lines   = ( "commit $commit tree $tree", ( @$records ? () : '    no results' ) );
        foreach my $record (@$records) {
            push @lines, q{    } . describe($record);
            push @lines, map { "        $_" } split m/\n/sx, $record->{output} if $opts->{raw} && defined $record->{output};
        }
        print map { "$_\n" } @lines;
    }
    return 0;
}

# One line about a record: the status, the configuration, the test, the time,
# and what went wrong.
# @param   record  HashRef  the record
# @returns Str  the line, without a line end
# @example print Git::TMS::CLI::describe($record), "\n";
sub describe {
    my ($record) = @_;

    my @problems;
    push @problems, "exit $record->{exit}"     if $record->{exit};
    push @problems, "$record->{failed} failed" if $record->{failed};
    push @problems, @{ $record->{errors} }     if ref $record->{errors} eq 'ARRAY';
    push @problems, $record->{reason}          if defined $record->{reason};
    push @problems, 'output cut'               if $record->{cut};
    push @problems, "try $record->{try}"       if $record->{try};

    my $line = sprintf '%-7s %-20s %-30s %8.3fs', $record->{status} // q{?}, $record->{config}, $record->{test} // q{?}, $record->{elapsed} // 0;
    return join q{  }, $line, ( @problems ? join( q{, }, @problems ) : () );
}

# git tms scan: answer a question about the records.  The one question of this
# version is --where-fails TEST: which configurations fail a test at a
# revision.
# @param   store  Git::TMS::Store  the store
# @param   @args  Str  the options and the revision
# @returns Int  0
# @throws  when no question is asked, or when there is more than one revision
# @example Git::TMS::CLI::scan( $store, '--where-fails', 't/a.t', 'HEAD' );
sub scan {
    my ( $store, @args ) = @_;

    my $opts = options( \@args, 'where-fails=s' );
    my $test = $opts->{'where-fails'};
    die "git-tms: scan needs --where-fails TEST.\n" if !defined $test;
    die "git-tms: scan takes one revision.\n"       if @args > 1;
    $test =~ tr{\\}{/};

    my $rev  = $args[0] // 'HEAD';
    my $tree = $store->git->run( 'rev-parse', '--verify', "$rev^{tree}" );
    chomp $tree;

    my %runs;
    foreach my $record ( grep { ( $_->{test} // q{} ) eq $test } @{ $store->records( [$tree] )->{$tree} // [] } ) {
        my $counts = $runs{ $record->{config} } //= { runs => 0, failures => 0, statuses => {} };
        $counts->{runs}++;
        next if $record->{status} eq 'pass' || $record->{status} eq 'skip';
        $counts->{failures}++;
        $counts->{statuses}{ $record->{status} } = 1;
    }

    my @failing = grep { $runs{$_}{failures} } sort keys %runs;
    if ( !@failing ) {
        printf "No configuration fails %s at %s.  %d configurations have results for it.\n", $test, $rev, scalar keys %runs;
        return 0;
    }
    foreach my $config (@failing) {
        my $counts = $runs{$config};
        printf "%-20s %-12s %d of %d runs\n", $config, join( q{,}, sort keys %{ $counts->{statuses} } ), $counts->{failures}, $counts->{runs};
    }
    return 0;
}

# git tms push: push every local results ref to a remote.
# @param   store  Git::TMS::Store  the store
# @param   @args  Str  the remote
# @returns Int  0
# @throws  what Git::TMS::Store->push_to throws, or when there is more than one remote
# @example Git::TMS::CLI::push_results( $store, 'origin' );
sub push_results {
    my ( $store, @args ) = @_;

    die "git-tms: push takes one remote.\n" if @args > 1;
    my $remote = remote( $store, $args[0] );
    my $result = $store->push_to($remote);
    if ( !@{ $result->{pushed} } ) {
        print "No results to push.\n";
        return 0;
    }
    my %merged = map { $_ => 1 } @{ $result->{merged} };
    print map { "pushed $_ to $remote" . ( $merged{$_} ? ', merged with the results that it had' : q{} ) . "\n" } @{ $result->{pushed} };
    return 0;
}

# git tms fetch: fetch every results ref of a remote.
# @param   store  Git::TMS::Store  the store
# @param   @args  Str  the remote
# @returns Int  0
# @throws  what Git::TMS::Store->fetch_from throws, or when there is more than one remote
# @example Git::TMS::CLI::fetch_results( $store, 'origin' );
sub fetch_results {
    my ( $store, @args ) = @_;

    die "git-tms: fetch takes one remote.\n" if @args > 1;
    my $remote  = remote( $store, $args[0] );
    my $configs = $store->fetch_from($remote);
    print @$configs ? map { "fetched $_ from $remote\n" } @$configs : "$remote has no results.\n";
    return 0;
}

1;
