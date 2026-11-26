package App::Yath::Plugin::GitTMS;

# ABSTRACT: Record the outcome of each test file that yath runs in git notes

use 5.014;

use strict;
use warnings FATAL => 'all';

use re '/aa';

no autovivification;

use Readonly;

use parent qw{App::Yath::Plugin};

use Git::TMS::Recorder ();

Readonly my %KNOWN => map { $_ => 1 } qw{config};

=head1 SYNOPSIS

    yath test -pGitTMS t
    yath test -pGitTMS=config=linux-perl5.40 t

=head1 DESCRIPTION

The plugin reads the events of a yath run.  When a test file ends, it gives
the outcome of the file to a L<Git::TMS::Recorder>.  When the run ends, the
recorder writes the records to the note of the tested tree, in the notes ref
of the configuration.  C<git tms push> sends them to a remote.

A test file that yath retries gets one record for each try, so a test that
failed and then passed shows as both.

The plugin takes one argument, C<config=NAME>, the name of the configuration.
Without it, the plugin reads C<GIT_TMS_CONFIG>, and then makes a name from the
operating system and the version of perl.

For a test file that did not pass, the record keeps each assertion that
failed, its diagnostics, each error, the reason of a halt, and what the file
printed on standard error.  For a test file that passed, it keeps none of
them.

=cut

# Called by yath for -pGitTMS, with the arguments after the =.
# @param   args  Str  the arguments, each as name=value
# @returns App::Yath::Plugin::GitTMS  the plugin
# @throws  a message that names an argument that the plugin does not know
# @example my $plugin = App::Yath::Plugin::GitTMS->new('config=linux-perl5.40');
sub new {
    my ( $class, @args ) = @_;

    my %args;
    foreach my $arg (@args) {
        my ( $name, $value ) = split m/=/sx, $arg, 2;
        die "git-tms: the yath plugin does not know the argument '$arg'.  It takes config=.\n" if !$KNOWN{$name} || !defined $value;
        $args{$name} = $value;
    }
    return bless { config => $args{config}, jobs => {} }, $class;
}

# The recorder of the run.  It is made at the first event, so that a yath
# command that runs no tests never looks at git.
# @returns Git::TMS::Recorder  the recorder
# @example my $tree = $plugin->recorder->tree;
sub recorder {
    my ($self) = @_;
    return $self->{recorder} //= Git::TMS::Recorder->new( config => $self->{config} );
}

# Called by yath for each event.  It keeps what a record needs, and adds the
# record when the job ends.
# @param   event     Test2::Harness::Event  the event
# @param   settings  Test2::Harness::Settings  the settings of yath, which it does not read
# @returns Maybe[HashRef]  the record when the event ends a job, else undef
# @example $plugin->handle_event( $event, $settings );
sub handle_event {
    my ( $self, $event, $settings ) = @_;

    my $f       = $event->facet_data // return;
    my $harness = $f->{harness}      // return;
    my $job_id  = $harness->{job_id} // return;
    $self->recorder;

    # A retry starts after the try before it has ended, so the job id is enough.
    my $job = $self->{jobs}{$job_id} //= { lines => [], problems => {}, failed => 0 };

    $job->{started} = $f->{harness_job_start}{stamp} if $f->{harness_job_start};
    $job->{exit}    = $f->{harness_job_exit}{exit}   if $f->{harness_job_exit};
    $self->note_problems( $job, $f );

    my $end = $f->{harness_job_end} // return;
    delete $self->{jobs}{$job_id};
    return $self->add_job( $job, $end, $harness->{job_try} );
}

# Keep the parts of one event that say what went wrong in a job.
# @param   job  HashRef  what the plugin keeps about the job
# @param   f    HashRef  the facet data of the event
# @returns Undef
# @example $plugin->note_problems( $job, $event->facet_data );
sub note_problems {
    my ( $self, $job, $f ) = @_;

    return if $f->{trace} && $f->{trace}{nested};
    my $lines = $job->{lines};
    my $cid   = $f->{trace} ? $f->{trace}{cid} : undef;

    if ( is_failure($f) ) {
        $job->{failed}++;
        $job->{problems}{$cid} = 1 if defined $cid;
        push @$lines, failure_lines($f);
        return;
    }
    foreach my $error ( grep { $_->{fail} } @{ $f->{errors} // [] } ) {
        push @$lines, $error->{details} // q{};
    }
    if ( $f->{control} && $f->{control}{halt} ) {
        $job->{halted} = 1;
        push @$lines, 'Bail out!  ' . ( $f->{control}{details} // q{} );
    }
    foreach my $info ( @{ $f->{info} // [] } ) {
        my @text = split m/\n/sx, $info->{details} // q{};
        if ( defined $cid && $job->{problems}{$cid} ) {
            push @$lines, map { "# $_" } @text;
        }
        elsif ( ( $info->{tag} // q{} ) eq 'STDERR' ) {
            push @$lines, @text;
        }
    }
    return;
}

# Whether the facet data of an event is an assertion that failed and that no
# TODO excuses.
# @param   f  HashRef  the facet data
# @returns Bool  true for such a failure
# @example next if !App::Yath::Plugin::GitTMS::is_failure($f);
sub is_failure {
    my ($f) = @_;
    return $f->{assert} && !$f->{assert}{pass} && !( $f->{amnesty} && @{ $f->{amnesty} } );
}

# The lines of the diagnostics in a list of info facets, each behind a #.
# @param   infos   ArrayRef[HashRef]  the info facets
# @param   indent  Str  what goes in front of each line
# @returns List[Str]  the lines
# @example my @lines = App::Yath::Plugin::GitTMS::diagnostic_lines( $f->{info}, q{} );
sub diagnostic_lines {
    my ( $infos, $indent ) = @_;

    my @lines;
    foreach my $info ( @{ $infos // [] } ) {
        push @lines, map { "$indent# $_" } split m/\n/sx, $info->{details} // q{};
    }
    return @lines;
}

# The lines that describe a failed assertion: the assertion, its diagnostics,
# and, for a subtest, each failure inside it with its diagnostics, indented by
# the depth of the subtest.
# @param   f  HashRef  the facet data of the assertion
# @returns List[Str]  the lines
# @example my @lines = App::Yath::Plugin::GitTMS::failure_lines($f);
sub failure_lines {
    my ($top) = @_;

    my @lines;
    my @todo = ( [ assert => $top, 0 ] );
    while ( my $item = shift @todo ) {
        my ( $kind, $f, $depth ) = @$item;
        my $indent = q{    } x $depth;
        if ( $kind eq 'info' ) {
            push @lines, diagnostic_lines( $f->{info}, $indent );
            next;
        }
        push @lines, $indent . 'not ok - ' . ( $f->{assert}{details} // q{} ), diagnostic_lines( $f->{info}, $indent );

        # The failures of a subtest come before the work that is left.
        my ( @inside, $failing_cid );
        foreach my $child ( @{ $f->{parent} ? $f->{parent}{children} // [] : [] } ) {
            my $cid = $child->{trace} ? $child->{trace}{cid} // q{} : q{};
            if ( is_failure($child) ) {
                push @inside, [ assert => $child, $depth + 1 ];
                $failing_cid = $cid;
            }
            elsif ( $child->{info} && defined $failing_cid && $cid eq $failing_cid ) {
                push @inside, [ info => $child, $depth + 1 ];
            }
        }
        unshift @todo, @inside;
    }
    return @lines;
}

# Give the outcome of a job that ended to the recorder.
# @param   job  HashRef  what the plugin kept about the job
# @param   end  HashRef  the harness_job_end facet
# @param   try  Int  the try of the job, from 0
# @returns Maybe[HashRef]  the record, or undef when this run records nothing
# @example $plugin->add_job( $job, $end, 0 );
sub add_job {
    my ( $self, $job, $end, $try ) = @_;

    my $status =
        $job->{halted} ? 'bailout'
      : $end->{fail}   ? 'fail'
      : $end->{skip}   ? 'skip'
      :                  'pass';
    my $exit = $job->{exit} // 0;

    return $self->recorder->add(
        test    => $end->{rel_file} // $end->{file},
        status  => $status,
        elapsed => ( defined $job->{started} && defined $end->{stamp} ? $end->{stamp} - $job->{started} : 0 ),
        exit    => ( $exit & 127                                      ? -1                              : $exit >> 8 ),
        failed  => $job->{failed},
        reason  => $end->{skip},
        output  => ( $status eq 'pass' ? undef : join q{}, map { "$_\n" } @{ $job->{lines} } ),
        try     => $try,
    );
}

# Called by yath when the run ends: write the records of the run.
# @returns Int  how many records it wrote
# @example $plugin->finish( settings => $settings, final_data => $final );
sub finish {
    my ($self) = @_;
    return $self->{recorder} ? $self->{recorder}->finish() : 0;
}

1;
