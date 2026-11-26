package App::Prove::Plugin::GitTMS;

# ABSTRACT: Record the outcome of each test file that prove runs in git notes

use 5.014;

use strict;
use warnings FATAL => 'all';

use re '/aa';

no autovivification;

use Readonly;

use Git::TMS::Harness ();

Readonly my %KNOWN => map { $_ => 1 } qw{config merge};

=head1 DESCRIPTION

Run prove with the plugin:

    prove -l -PGitTMS t
    prove -l -PGitTMS=config=linux-perl5.40 t
    prove -l -PGitTMS=config=linux-perl5.40,merge=0 t

The plugin makes prove run its tests through L<Git::TMS::Harness>.  When the
run ends, the record of each test file is in the note of the tested tree, in
the notes ref of the configuration.  C<git tms push> sends them to a remote.

The plugin takes these arguments, each as C<name=value>:

=over

=item config

The name of the configuration, such as C<linux-perl5.40>.  Without it, the
plugin reads C<GIT_TMS_CONFIG>, and then makes a name from the operating
system and the version of perl.  A CI matrix names each of its cells here.

=item merge

The plugin turns on C<merge>, as C<prove -m> does, so that the diagnostics of
a failed assertion reach the record.  C<merge=0> leaves it off.

=back

=cut

# Called by prove for -PGitTMS.  It sets the harness class of prove, and turns
# on merge.
# @param   plugin  HashRef  app_prove, the App::Prove object, and args, the arguments after the =
# @returns Bool  true
# @throws  a message that names an argument that the plugin does not know
# @example App::Prove::Plugin::GitTMS->load( { app_prove => $app, args => ['config=linux-perl5.40'] } );
sub load {
    my ( $class, $plugin ) = @_;

    my %args;
    foreach my $arg ( @{ $plugin->{args} // [] } ) {
        my ( $name, $value ) = split m/=/sx, $arg, 2;
        die "git-tms: the prove plugin does not know the argument '$arg'.  It takes config= and merge=.\n" if !$KNOWN{$name} || !defined $value;
        $args{$name} = $value;
    }

    my $app = $plugin->{app_prove};
    Git::TMS::Harness->configure( config => $args{config} );
    $app->harness('Git::TMS::Harness');
    $app->merge(1) if $args{merge} // 1;
    return 1;
}

1;
