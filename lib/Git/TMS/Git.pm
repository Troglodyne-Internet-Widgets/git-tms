package Git::TMS::Git;

# ABSTRACT: Run git in one repository, with no shell between

use 5.014;

use strict;
use warnings FATAL => 'all';

use re '/aa';

no autovivification;

use IPC::Run3 ();

=head1 SYNOPSIS

    use Git::TMS::Git;

    my $git  = Git::TMS::Git->new( dir => '/src/My-Dist' );
    my $tree = $git->run(qw{rev-parse HEAD^{tree}});

    my ( $exit, $out, $err ) = $git->call(qw{diff --quiet HEAD --});

=head1 DESCRIPTION

Each call runs one git process from a list of arguments, through
L<IPC::Run3>.  No shell parses the arguments, so a path with a space or a
quote in it needs no quoting, on Windows as on Unix.

=cut

# Make an object that runs git in one directory.
# @param   dir  Str  the directory that git runs in.  Without it, git runs in the current directory.
# @returns Git::TMS::Git  the object
# @example my $git = Git::TMS::Git->new( dir => '/src/My-Dist' );
sub new {
    my ( $class, %args ) = @_;
    return bless { dir => $args{dir}, config => [] }, $class;
}

# Run git, and return what it printed.  It dies when git exits with a status
# other than 0.  A first argument that is a reference to a scalar is the
# standard input of git, as for call.
# @param   @args  Str  the arguments of git, one to each element
# @returns Str  what git printed on its standard output
# @throws  a message that names the git command and gives what git printed on its standard error
# @example my $tree = $git->run(qw{rev-parse HEAD^{tree}});
sub run {
    my ( $self, @args ) = @_;

    my ( $exit, $out, $err ) = $self->call(@args);
    if ($exit) {
        my @shown = grep { ref ne 'SCALAR' } @args;
        chomp $err;
        die "git @shown failed with status $exit: $err\n";
    }
    return $out;
}

# Run git, and return its exit status with what it printed.  A first argument
# that is a reference to a scalar is the standard input of git.
# @param   @args  Str  the arguments of git, one to each element
# @returns List  the exit status of git (0 for success, -1 when a signal killed it), its standard output and its standard error
# @throws  the message of IPC::Run3 when git cannot be started at all
# @example my ( $exit, $out, $err ) = $git->call( \"line\n", qw{notes add -F -}, $tree );
sub call {
    my ( $self, @args ) = @_;

    my $input   = ref $args[0] eq 'SCALAR' ? shift @args : \undef;
    my @command = ( 'git', ( defined $self->{dir} ? ( '-C', $self->{dir} ) : () ), @{ $self->{config} }, @args );

    my ( $out, $err ) = ( q{}, q{} );
    IPC::Run3::run3( \@command, $input, \$out, \$err, { binmode_stdin => ':raw', binmode_stdout => ':raw', binmode_stderr => ':raw' } );

    my $status = $?;
    my $exit   = $status & 127 ? -1 : $status >> 8;
    return ( $exit, $out, $err );
}

# Give git a name and an address for the commits that it makes for notes, when
# the repository and the environment give it none.  A CI job usually has no
# identity, and git then refuses to write a note.  An identity that git can
# find already wins.
# @returns Bool  true when it had to supply the identity
# @example $git->ensure_identity();
sub ensure_identity {
    my ($self) = @_;

    return 0 if $self->{identity_checked}++;
    my ($exit) = $self->call(qw{var GIT_COMMITTER_IDENT});
    return 0 if !$exit;
    push @{ $self->{config} }, qw{-c user.name=git-tms -c user.email=git-tms@invalid};
    return 1;
}

# Read one value of the git configuration.
# @param   key  Str  the name of the value, such as tms.remote
# @returns Str|Undef  the value without its line end, or undef when it is not set
# @example my $remote = $git->config('tms.remote') // 'origin';
sub config {
    my ( $self, $key ) = @_;

    # One scalar in every context, so that a call in a list is still one value.
    my ( $exit, $out ) = $self->call( 'config', '--get', $key );
    chomp $out;
    return $exit ? undef : $out;
}

1;
