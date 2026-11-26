package Git::TMS::TestRepo;

# ABSTRACT: Throwaway git repositories and bare remotes for the tests of git-tms

use 5.014;

use strict;
use warnings FATAL => 'all';

use re '/aa';

no autovivification;

use Cwd        ();
use File::Path ();
use File::Spec ();
use File::Temp ();
use IPC::Run3  ();

use parent qw{Exporter};
our @EXPORT_OK = qw{scratch git new_repo bare_repo clone_repo commit_file write_file in_dir};

# The git of each test sees no global or system configuration, so the
# configuration of the person who runs the tests cannot change what a test
# does.  The variables that git sets for a hook would point git at the
# repository being committed to, so they go too.  The code under test runs git
# itself, so the change holds for the whole process rather than a scope.
delete @ENV{ grep { m/\A GIT_/sx } keys %ENV };
## no critic (Variables::RequireLocalizedPunctuationVars)
$ENV{GIT_CONFIG_NOSYSTEM} = 1;
$ENV{GIT_CONFIG_GLOBAL}   = File::Spec->devnull;
## use critic

=head1 SYNOPSIS

    use Git::TMS::TestRepo qw{scratch new_repo bare_repo clone_repo commit_file git};

    my $root   = scratch();
    my $origin = bare_repo( $root, 'origin.git' );
    my $repo   = clone_repo( $root, $origin, 'work' );
    commit_file( $repo, 'a.txt', "a\n" );
    my $tree = git( $repo, qw{rev-parse HEAD^{tree}} );

=head1 DESCRIPTION

Every repository is under a temporary directory that is removed when the test
ends.  Each commit gives git a name and an address on its command line, so
that the code under test runs with no identity in the configuration, as a CI
job does.

=cut

# A new temporary directory, removed when the test ends.
# @returns Str  the path of the directory
# @example my $root = scratch();
sub scratch {
    return Cwd::abs_path( File::Temp::tempdir( 'git-tms-XXXXXX', TMPDIR => 1, CLEANUP => 1 ) );
}

# Run git in a directory, and die when it fails.
# @param   dir   Str  the directory
# @param   args  Str  the arguments of git
# @returns Str  what git printed on its standard output, without the last line end
# @throws  the command and what git printed on its standard error
# @example my $tree = git( $repo, qw{rev-parse HEAD^{tree}} );
sub git {
    my ( $dir, @args ) = @_;

    my ( $out, $err ) = ( q{}, q{} );
    IPC::Run3::run3( [ 'git', '-C', $dir, @args ], \undef, \$out, \$err );
    die "git @args in $dir failed: $err" if $?;
    chomp $out;
    return $out;
}

# Make a repository with a work tree.
# @param   root  Str  the directory to make it in
# @param   name  Str  the name of its directory
# @returns Str  the path of the repository
# @example my $repo = new_repo( $root, 'work' );
sub new_repo {
    my ( $root, $name ) = @_;

    my $dir = File::Spec->catdir( $root, $name );
    File::Path::make_path($dir);
    git( $dir, qw{-c init.defaultBranch=main init --quiet} );
    return $dir;
}

# Make a bare repository, to be a remote.
# @param   root  Str  the directory to make it in
# @param   name  Str  the name of its directory
# @returns Str  the path of the repository
# @example my $origin = bare_repo( $root, 'origin.git' );
sub bare_repo {
    my ( $root, $name ) = @_;

    my $dir = File::Spec->catdir( $root, $name );
    File::Path::make_path($dir);
    git( $dir, qw{-c init.defaultBranch=main init --quiet --bare} );
    return $dir;
}

# Clone a repository, with its remote named origin.
# @param   root    Str  the directory to clone into
# @param   remote  Str  the path of the repository to clone
# @param   name    Str  the name of the directory of the clone
# @returns Str  the path of the clone
# @example my $repo = clone_repo( $root, $origin, 'work' );
sub clone_repo {
    my ( $root, $remote, $name ) = @_;

    my $dir = File::Spec->catdir( $root, $name );
    git( $root, 'clone', '--quiet', $remote, $dir );
    return $dir;
}

# Write a file under a directory, making the directories it needs.
# @param   dir      Str  the directory
# @param   path     Str  the path of the file under it, with / between its parts
# @param   content  Str  the bytes of the file
# @returns Str  the full path of the file
# @example write_file( $repo, 't/a.t', $test );
sub write_file {
    my ( $dir, $path, $content ) = @_;

    my $file = File::Spec->catfile( $dir, split m{/}sx, $path );
    File::Path::make_path( ( File::Spec->splitpath($file) )[1] );
    open my $fh, '>:raw', $file or die "Cannot write $file: $!";
    print {$fh} $content;
    close $fh or die "Cannot write $file: $!";
    return $file;
}

# Write a file in a repository and commit it.
# @param   dir      Str  the repository
# @param   path     Str  the path of the file, with / between its parts
# @param   content  Str  the bytes of the file
# @returns Str  the id of the new commit
# @example commit_file( $repo, 'a.txt', "a\n" );
sub commit_file {
    my ( $dir, $path, $content ) = @_;

    write_file( $dir, $path, $content );
    git( $dir, 'add', q{--}, $path );
    git( $dir, qw{-c user.name=Tester -c user.email=tester@test.test commit --quiet -m}, "add $path" );
    return git( $dir, qw{rev-parse HEAD} );
}

# Run code in a directory, and come back to the directory that was current,
# also when the code dies.
# @param   dir   Str  the directory
# @param   code  CodeRef  the code
# @returns List  what the code returned
# @throws  what the code threw
# @example my $out = in_dir( $repo, sub { run_prove() } );
sub in_dir {
    my ( $dir, $code ) = @_;

    my $back = Cwd::getcwd();
    chdir $dir or die "Cannot change to $dir: $!";
    my @result;
    my $ok    = eval { @result = $code->(); 1 };
    my $error = $@;
    chdir $back or die "Cannot change back to $back: $!";
    die $error if !$ok;
    return wantarray ? @result : $result[0];
}

1;
