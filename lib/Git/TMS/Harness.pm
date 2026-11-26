package Git::TMS::Harness;

# ABSTRACT: A TAP::Harness that records the outcome of each test file in git notes

use 5.014;

use strict;
use warnings FATAL => 'all';

use re '/aa';

no autovivification;

use parent qw{TAP::Harness};

use Encode             ();
use Git::TMS::Recorder ();
use Scalar::Util       ();
use Time::HiRes        ();

=head1 SYNOPSIS

    prove -l -PGitTMS=config=linux-perl5.40 t

    # Or by hand:
    use Git::TMS::Harness;
    Git::TMS::Harness->configure( config => 'linux-perl5.40' );
    my $harness = Git::TMS::Harness->new( { lib => ['lib'], merge => 1 } );
    $harness->runtests('t/a.t');

=head1 DESCRIPTION

L<App::Prove::Plugin::GitTMS> makes prove use this harness.  It watches the
TAP of each test file, and gives the outcome of each file to a
L<Git::TMS::Recorder> when the file ends.  When all the files ran, or one
bailed out, the recorder writes the records to the notes of the tested tree.

The harness keeps no TAP of a test that passed.  For a test that did not pass,
it keeps the output that L</abnormal_output> chooses.  Diagnostics go to
standard error, so the harness sees them only when C<merge> is on, as with
C<prove -m>.  The prove plugin turns it on.

=cut

my %settings;

# Set the arguments of the recorder that each new harness makes.  The prove
# plugin calls it, because App::Prove gives a harness class only the arguments
# that TAP::Harness knows.
# @param   config  Str  the name of the configuration
# @returns Undef
# @example Git::TMS::Harness->configure( config => 'linux-perl5.40' );
sub configure {
    my ( $class, %args ) = @_;
    %settings = %args;
    return;
}

# Make the harness, with the callbacks that record each test file.
# @param   args  HashRef  the arguments of TAP::Harness
# @returns Git::TMS::Harness  the harness
# @throws  as Git::TMS::Recorder->new does
# @example my $harness = Git::TMS::Harness->new( { merge => 1 } );
sub new {
    my ( $class, @args ) = @_;

    my $self = $class->SUPER::new(@args);
    $self->{git_tms} = { recorder => Git::TMS::Recorder->new(%settings), files => {} };

    # The callbacks live in the harness, so they hold it weakly.
    my $weak = $self;
    Scalar::Util::weaken($weak);
    $self->callback( made_parser => sub { $weak->watch(@_) } );
    $self->callback( after_test  => sub { $weak->record(@_) } );
    return $self;
}

# The recorder of this harness.
# @returns Git::TMS::Recorder  the recorder
# @example my $tree = $harness->recorder->tree;
sub recorder {
    my ($self) = @_;
    return $self->{git_tms}{recorder};
}

# Run the tests, and then write their records, also after a bail out.
# @param   tests  Str  the test files, as TAP::Harness takes them
# @returns TAP::Parser::Aggregator  the result of the run
# @throws  what TAP::Harness throws, such as the message of a bail out, after the records are written
# @example my $aggregate = $harness->runtests('t/a.t');
sub runtests {
    my ( $self, @tests ) = @_;

    my $aggregate;
    my $ok    = eval { $aggregate = $self->SUPER::runtests(@tests); 1 };
    my $error = $@;
    $self->recorder->finish();
    die $error if !$ok;
    return $aggregate;
}

# The made_parser callback: start the clock of a test file, and keep each
# line of its TAP.
# @param   parser  TAP::Parser  the parser of the file
# @returns Undef
# @example $harness->watch($parser);
sub watch {
    my ( $self, $parser ) = @_;

    my $file = { started => Time::HiRes::time(), lines => [], bailout => 0 };
    $self->{git_tms}{files}{ Scalar::Util::refaddr($parser) } = $file;
    $parser->callback(
        ALL => sub {
            my ($result) = @_;
            push @{ $file->{lines} }, $result->raw;
            $file->{bailout} = 1 if $result->is_bailout;
        },
    );
    return;
}

# The after_test callback: give the outcome of a test file to the recorder.
# @param   job     ArrayRef  the file and its description, as TAP::Harness passes them
# @param   parser  TAP::Parser  the parser of the file
# @returns Maybe[HashRef]  the record, or undef when this run records nothing
# @example $harness->record( [ 't/a.t', 't/a.t' ], $parser );
sub record {
    my ( $self, $job, $parser ) = @_;

    my $file = delete $self->{git_tms}{files}{ Scalar::Util::refaddr($parser) } // { started => Time::HiRes::time(), lines => [] };
    my $skip = $parser->skip_all;
    my $status =
        $file->{bailout}      ? 'bailout'
      : $skip                 ? 'skip'
      : $parser->has_problems ? 'fail'
      :                         'pass';

    return $self->recorder->add(
        test    => $job->[0],
        status  => $status,
        elapsed => Time::HiRes::time() - $file->{started},
        exit    => $parser->exit,
        failed  => scalar $parser->failed,
        errors  => [ $parser->parse_errors ],
        reason  => ( $skip && $skip ne '1' ? $skip : undef ),
        output  => ( $status eq 'pass'     ? undef : abnormal_output( @{ $file->{lines} } ) ),
    );
}

# The lines of TAP that describe what went wrong: each assertion that failed
# and was not a TODO, the comments after it up to the next assertion, each
# bail out, and each line that is not TAP at all, such as the message of a
# die.  The assertions of a subtest are indented, and count the same way.
# @param   lines  Str  the lines of TAP of one test file, as bytes
# @returns Str  the chosen lines, decoded from UTF-8, each with a line end
# @example my $output = Git::TMS::Harness::abnormal_output(@lines);
sub abnormal_output {
    my (@lines) = @_;

    my @kept;
    my $after_failure = 0;
    foreach my $line (@lines) {
        if ( $line =~ m/\A \s* not \s+ ok \b/sx ) {
            $after_failure = $line !~ m/\# \s* TODO \b/isx;
            push @kept, $line if $after_failure;
        }
        elsif ( $line =~ m/\A \s* (?: ok \b | 1 [.][.] \d | TAP \s+ version \b ) /sx ) {
            $after_failure = 0;
        }
        elsif ( $line =~ m/\A \s* \#/sx ) {
            push @kept, $line if $after_failure;
        }
        elsif ( $line ne q{} ) {
            push @kept, $line;
        }
    }
    return Encode::decode( 'UTF-8', join( q{}, map { "$_\n" } @kept ) );
}

1;
