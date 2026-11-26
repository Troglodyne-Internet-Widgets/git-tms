package Git::TMS::Recorder;

# ABSTRACT: Turn the outcome of each test file into a record, and write the records of a run to the notes of the tested tree

use 5.014;

use strict;
use warnings FATAL => 'all';

use re '/aa';

no autovivification;

use Readonly;

use Cwd             ();
use Crypt::PRNG     ();
use File::Spec      ();
use Git::TMS::Store ();
use IPC::Run3       ();
use POSIX           ();

Readonly my $MAX_OUTPUT => 16_384;
Readonly my %STATUS     => map { $_ => 1 } qw{pass fail skip bailout};

=head1 SYNOPSIS

    use Git::TMS::Recorder;

    my $recorder = Git::TMS::Recorder->new( config => 'linux-perl5.40' );
    $recorder->add( test => 't/a.t', status => 'pass', elapsed => 0.12 );
    $recorder->add(
        test    => 't/b.t',
        status  => 'fail',
        elapsed => 1.5,
        exit    => 1,
        failed  => 1,
        output  => "not ok 2 - adds\n#   Failed test 'adds'\n",
    );
    $recorder->finish();

=head1 DESCRIPTION

The harness plugins of git-tms, L<App::Prove::Plugin::GitTMS> and
L<App::Yath::Plugin::GitTMS>, share this class.  A plugin calls L</add> once
for each test file that ran, and L</finish> once at the end of the run.  Only
L</finish> writes to git, so a run that dies half way writes nothing, and a
test file never waits for git.

The recorder takes the tested tree from L<Git::TMS::Store/tested_tree> when it
is made, before the tests can change a file.  If no tree id describes the work
tree, it warns once, and then records nothing.

=head2 What a record holds

Every record has C<v> (the version of the format, 1), C<run>, C<test>,
C<status> and C<elapsed>.  A record whose status is not C<pass> adds what
describes the problem: C<exit>, C<failed>, C<errors>, C<reason> and C<output>,
each when it has a value.  The output of a passing test is not kept.  See
L<Git::TMS/"THE RECORD"> for each field.

=head2 Configuration that git holds

=over

=item tms.outputFilter

A command that the system shell runs on the output of each test that did not
pass, before it goes into a record.  The output is its standard input, and its
standard output replaces the output.  Use it to remove secrets.  If the command
fails, the record keeps no output, and the recorder warns.

=item tms.maxOutput

The most characters of output that a record keeps, after the filter.  The
default is 16384.  A record whose output was cut has C<cut> set to 1.

=back

=cut

# Make a recorder for one run of the tests.
# @param   config  Str  the name of the configuration.  Without it, GIT_TMS_CONFIG, and then the default that default_config gives.
# @param   dir     Str  a directory in the work tree.  Without it, the current directory.
# @param   store   Git::TMS::Store  the store to write to, in place of dir
# @returns Git::TMS::Recorder  the recorder
# @throws  as Git::TMS::Store::check_name does, when the name of the configuration is not usable
# @example my $recorder = Git::TMS::Recorder->new( config => 'linux-perl5.40' );
sub new {
    my ( $class, %args ) = @_;

    my $config = Git::TMS::Store::check_name( configuration => $args{config} // $ENV{GIT_TMS_CONFIG} // default_config() );
    my $store  = $args{store} // Git::TMS::Store->new( dir => $args{dir} );
    my $self   = bless { config => $config, store => $store, records => [] }, $class;

    my ( $tree, $why ) = $store->tested_tree();
    if ( !defined $tree ) {
        warn "git-tms: no results are recorded for this run: $why.\n";
        return $self;
    }

    my $git = $store->git;
    my $top = $git->run(qw{rev-parse --show-toplevel});
    chomp $top;
    my $max = $git->config('tms.maxOutput') // $MAX_OUTPUT;
    die "git-tms: tms.maxOutput is '$max', which is not a whole number.\n" if $max !~ m/\A \d+ \z/sx;

    my $filter = $git->config(q{tms.outputFilter});
    @{$self}{qw{tree top filter max run}} = ( $tree, Cwd::abs_path($top) // $top, $filter, $max, run_id() );
    return $self;
}

# The name of the configuration when nobody gives one: the operating system
# and the version of perl, such as linux-perl5.40.1.
# @returns Str  the name
# @example my $config = Git::TMS::Recorder::default_config();
sub default_config {
    return sprintf '%s-perl%vd', $^O, $^V;
}

# A name for one run of the tests: the time in UTC, then random hex, so that
# the records of two jobs on one tree stay apart, and sort by time.
# @returns Str  the name, such as 20261124T100000Z-1a2b3c4d
# @example my $run = Git::TMS::Recorder::run_id();
sub run_id {
    return POSIX::strftime( '%Y%m%dT%H%M%SZ', gmtime ) . q{-} . Crypt::PRNG::random_bytes_hex(4);
}

# The tested tree, or undef when this run records nothing.
# @returns Maybe[Str]  the tree id
# @example print $recorder->tree // 'nothing', "\n";
sub tree {
    my ($self) = @_;
    return $self->{tree};
}

# The name of the configuration of this run.
# @returns Str  the name
# @example print $recorder->config, "\n";
sub config {
    my ($self) = @_;
    return $self->{config};
}

# The path of a test file from the top of the work tree, with / between its
# parts on every platform, so that two configurations name one test alike.
# @param   file  Str  the path of the test file, relative to the current directory, or absolute
# @returns Str  the path from the top of the work tree; the path as given, with / between its parts, when the file is outside the work tree
# @example my $test = $recorder->test_path('t/a.t');
sub test_path {
    my ( $self, $file ) = @_;

    my $abs = Cwd::abs_path($file) // File::Spec->rel2abs($file);
    my $rel = defined $self->{top} ? File::Spec->abs2rel( $abs, $self->{top} ) : $file;
    return $file =~ tr{\\}{/}r if File::Spec->file_name_is_absolute($rel) || ( File::Spec->splitdir($rel) )[0] eq File::Spec->updir;

    my ( undef, $dirs, $name ) = File::Spec->splitpath($rel);
    return join q{/}, grep { $_ ne q{} } File::Spec->splitdir($dirs), $name;
}

# Make the record of one test file, and keep it for finish.
# @param   test     Str  the path of the test file
# @param   status   Str  pass, fail, skip or bailout
# @param   elapsed  Num  the seconds that the test file took
# @param   exit     Int  its exit status
# @param   failed   Int  how many assertions failed
# @param   errors   ArrayRef[Str]  the problems that the harness found, such as a wrong plan
# @param   reason   Str  why the file was skipped
# @param   output   Str  the output of the assertions that failed, as characters
# @param   try      Int  which retry of the file this was, from 1.  Absent for the first run.
# @returns Maybe[HashRef]  the record, or undef when this run records nothing
# @throws  when the status is not one of the four
# @example $recorder->add( test => 't/a.t', status => 'pass', elapsed => 0.12 );
sub add {
    my ( $self, %facts ) = @_;

    die "git-tms: '" . ( $facts{status} // q{} ) . "' is not a status\n" if !$STATUS{ $facts{status} // q{} };
    return                                                               if !defined $self->{tree};

    my %record = (
        v       => 1,
        run     => $self->{run},
        test    => $self->test_path( $facts{test} ),
        status  => $facts{status},
        elapsed => 0 + sprintf( '%.3f', $facts{elapsed} // 0 ),
    );
    $record{try} = 0 + $facts{try} if $facts{try};

    if ( $facts{status} ne 'pass' ) {
        $record{exit}   = 0 + $facts{exit}        if $facts{exit};
        $record{failed} = 0 + $facts{failed}      if $facts{failed};
        $record{errors} = [ @{ $facts{errors} } ] if $facts{errors} && @{ $facts{errors} };
        $record{reason} = $facts{reason}          if ( $facts{reason} // q{} ) ne q{};
        $self->set_output( \%record, $facts{output} ) if ( $facts{output} // q{} ) ne q{};
    }

    push @{ $self->{records} }, \%record;
    return \%record;
}

# Put output into a record: through tms.outputFilter when it is set, then cut
# to tms.maxOutput characters.
# @param   record  HashRef  the record
# @param   output  Str  the output, as characters
# @returns HashRef  the record
# @example $recorder->set_output( $record, $output );
sub set_output {
    my ( $self, $record, $output ) = @_;

    if ( defined $self->{filter} ) {
        my ( $filtered, $err ) = ( q{}, q{} );
        my $ok = eval {
            IPC::Run3::run3( $self->{filter}, \$output, \$filtered, \$err, { binmode_stdin => ':encoding(UTF-8)', binmode_stdout => ':encoding(UTF-8)' } );
            1;
        };
        if ( !$ok || $? ) {
            warn "git-tms: tms.outputFilter failed, so the record of $record->{test} keeps no output: " . ( $ok ? $err : $@ ) . "\n";
            return $record;
        }
        $output = $filtered;
    }

    if ( length $output > $self->{max} ) {
        $output        = substr $output, 0, $self->{max};
        $record->{cut} = 1;
    }
    $record->{output} = $output if $output ne q{};
    return $record;
}

# Write the records of the run to the note of the tested tree.  A failure of
# git warns and does not die, so that it never changes the result of the
# tests.
# @returns Int  how many records it wrote
# @example $recorder->finish();
sub finish {
    my ($self) = @_;

    my @records = @{ $self->{records} };
    return 0 if !defined $self->{tree} || !@records;

    my $ok = eval { $self->{store}->add_records( @{$self}{qw{config tree}}, @records ); 1 };
    if ( !$ok ) {
        warn "git-tms: the results of this run were not recorded: $@";
        return 0;
    }
    $self->{records} = [];
    return scalar @records;
}

1;
