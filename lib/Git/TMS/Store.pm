package Git::TMS::Store;

# ABSTRACT: Test results as lines of JSON in git notes on trees, one ref for each configuration

use 5.014;

use strict;
use warnings FATAL => 'all';

use re '/aa';

no autovivification;

use Readonly;

use Cpanel::JSON::XS ();
use Git::TMS::Git    ();

Readonly my $LOCAL      => 'refs/notes/tms/results';
Readonly my $TRACKING   => 'refs/notes/tms-remote';
Readonly my $PUSH_TRIES => 3;

# A name that is one level of a ref on every platform: no slash, no space, no
# character that git or a Windows file system refuses.
Readonly my $NAME_RX => qr/\A [[:alnum:]] (?: [[:alnum:]_.+-]* [[:alnum:]_+-] )? \z/sx;

=head1 SYNOPSIS

    use Git::TMS::Store;

    my $store = Git::TMS::Store->new( dir => '/src/My-Dist' );

    my ( $tree, $why ) = $store->tested_tree();
    $store->add_records( 'linux-perl5.40', $tree, { v => 1, test => 't/a.t', status => 'pass' } );

    my $by_tree = $store->records( [$tree] );
    $store->push_to(q{origin});
    $store->fetch_from(q{origin});

=head1 DESCRIPTION

The store keeps the results of one configuration in the notes ref
F<refs/notes/tms/results/CONFIG>.  A note hangs on the tree that was tested, not
on a commit, so every commit with that tree shares the results.  A note holds
one JSON object for each line, sorted, with no duplicates.  That is the format
that the C<cat_sort_uniq> strategy of C<git notes merge> keeps, so two jobs
that wrote to one ref merge without a conflict.

A fetch copies the refs of a remote to
F<refs/notes/tms-remote/REMOTE/results/CONFIG>.  A read takes the local refs
and the fetched refs together.

The notes are not compressed.  Git already compresses each object with zlib,
and compresses similar notes against each other in a pack.  A note that is
gzipped first is no smaller in a pack, and C<cat_sort_uniq> cannot merge it.

=cut

# Make a store for the repository in a directory.
# @param   dir  Str  a directory in the work tree.  Without it, the current directory.
# @param   git  Git::TMS::Git  the object that runs git, in place of dir
# @returns Git::TMS::Store  the store
# @example my $store = Git::TMS::Store->new( dir => '/src/My-Dist' );
sub new {
    my ( $class, %args ) = @_;
    return bless { git => $args{git} // Git::TMS::Git->new( dir => $args{dir} ) }, $class;
}

# The object that runs git for this store.
# @returns Git::TMS::Git  the object
# @example my $top = $store->git->run(qw{rev-parse --show-toplevel});
sub git {
    my ($self) = @_;
    return $self->{git};
}

# Make sure that a name can be one level of a ref, and return it.
# @param   kind  Str  what the name names, for the message, such as configuration
# @param   name  Str  the name
# @returns Str  the name
# @throws  a message that names the kind and the name, when the name is not one plain level of letters, digits, dots, underscores, plus signs and hyphens
# @example my $config = Git::TMS::Store::check_name( configuration => 'linux-perl5.40' );
sub check_name {
    my ( $kind, $name ) = @_;

    my $ok = defined $name && $name =~ $NAME_RX && index( $name, q{..} ) < 0 && $name !~ m/[.]lock\z/sx;
    die sprintf( "git-tms: the %s name '%s' is not usable.  Use letters, digits, '.', '_', '+' and '-', starting with a letter or a digit.\n", $kind, $name // q{} ) if !$ok;
    return $name;
}

# The local notes ref of a configuration.
# @param   config  Str  the name of the configuration
# @returns Str  the full name of the ref
# @throws  as check_name does
# @example my $ref = Git::TMS::Store::results_ref('linux-perl5.40');
sub results_ref {
    my ($config) = @_;
    return join q{/}, $LOCAL, check_name( configuration => $config );
}

# The ref that a fetch from a remote writes for a configuration.
# @param   remote  Str  the name of the remote
# @param   config  Str  the name of the configuration
# @returns Str  the full name of the ref
# @throws  as check_name does
# @example my $ref = Git::TMS::Store::tracking_ref( 'origin', 'linux-perl5.40' );
sub tracking_ref {
    my ( $remote, $config ) = @_;
    return join q{/}, $TRACKING, check_name( remote => $remote ), 'results', check_name( configuration => $config );
}

# The tree that a test run tests, which is the tree of HEAD while no tracked
# file differs from HEAD.  Untracked files, such as blib/, do not count.
# @returns List  the tree id, or undef and the reason that no tree id describes the work tree
# @example my ( $tree, $why ) = $store->tested_tree();
sub tested_tree {
    my ($self) = @_;

    my ( $exit, $tree ) = $self->git->call(qw{rev-parse --verify --quiet HEAD^{tree}});
    return ( undef, 'this is not a git work tree with a commit' ) if $exit;
    chomp $tree;

    my ( $diff, undef, $err ) = $self->git->call(qw{diff --quiet HEAD --});
    return ( undef, 'tracked files differ from HEAD, so no tree id describes what was tested' ) if $diff == 1;
    return ( undef, "git diff failed: $err" )                                                   if $diff;
    return ($tree);
}

# Add records to the note of a tree in the ref of a configuration.  The note
# keeps the records it had, and gains each new one that it lacks.
# @param   config   Str  the name of the configuration
# @param   tree     Str  the id of the tested tree
# @param   @records  HashRef  the records, each one a hash that becomes one line of JSON
# @returns Int  the number of lines in the note afterwards
# @throws  as check_name does, or when git cannot write the note
# @example $store->add_records( 'linux-perl5.40', $tree, @records );
sub add_records {
    my ( $self, $config, $tree, @records ) = @_;

    my $ref  = results_ref($config);
    my $json = _json();
    my ( $missing, $old ) = $self->git->call( 'notes', '--ref', $ref, 'show', $tree );
    my @lines = $missing ? () : split m/\n/sx, $old;
    foreach my $record (@records) {
        push @lines, $json->encode($record);
    }

    my %seen;
    my @note = grep { $_ ne q{} && !$seen{$_}++ } sort @lines;

    $self->git->ensure_identity();
    $self->git->run( \join( q{}, map { "$_\n" } @note ), 'notes', '--ref', $ref, qw{add --force --file -}, $tree );
    return scalar @note;
}

# The notes refs that hold results: the local ones, and those that a fetch
# copied from each remote.
# @returns ArrayRef[HashRef]  one hash for each ref, with ref, config, and remote (undef for a local ref)
# @example my @configs = map { $_->{config} } @{ $store->result_refs() };
sub result_refs {
    my ($self) = @_;

    my $out = $self->git->run( 'for-each-ref', '--format=%(refname)', "$LOCAL/", "$TRACKING/" );
    my @refs;
    foreach my $ref ( split m/\n/sx, $out ) {
        if ( $ref =~ m{\A \Q$LOCAL\E / ([^/]+) \z}sx ) {
            push @refs, { ref => $ref, config => $1, remote => undef };
        }
        elsif ( $ref =~ m{\A \Q$TRACKING\E / ([^/]+) /results/ ([^/]+) \z}sx ) {
            push @refs, { ref => $ref, config => $2, remote => $1 };
        }
    }
    return \@refs;
}

# The records of some trees, from every ref that result_refs names.  A record
# that a local ref and a fetched ref both hold comes back once.  Each record
# gains the field config, the name of its configuration.
# @param   trees    ArrayRef[Str]  the ids of the trees
# @param   configs  ArrayRef[Str]  as the named argument configs, only these configurations.  All of them when not given.
# @returns HashRef[ArrayRef[HashRef]]  for each tree that has records, its records, ordered by test, configuration, run and try
# @example my $by_tree = $store->records( [$tree], configs => ['linux-perl5.40'] );
sub records {
    my ( $self, $trees, %args ) = @_;

    my %want    = map { $_ => 1 } @$trees;
    my %configs = map { $_ => 1 } @{ $args{configs} // [] };

    # Each note blob, with the tree and the configuration it holds results for.
    my %holders;
    foreach my $ref ( @{ $self->result_refs() } ) {
        next if %configs && !$configs{ $ref->{config} };
        foreach my $line ( split m/\n/sx, $self->git->run( 'notes', '--ref', $ref->{ref}, 'list' ) ) {
            my ( $blob, $object ) = split q{ }, $line;
            push @{ $holders{$blob} }, [ $object, $ref->{config} ] if $want{$object};
        }
    }
    return {} if !%holders;

    my $contents = $self->blobs( [ keys %holders ] );
    my $json     = _json();
    my ( %by_tree, %seen );
    foreach my $blob ( keys %holders ) {
        foreach my $holder ( @{ $holders{$blob} } ) {
            my ( $tree, $config ) = @$holder;
            foreach my $line ( split m/\n/sx, $contents->{$blob} // q{} ) {
                next if $seen{$tree}{$config}{$line}++;
                my $record = eval { $json->decode($line) };
                next if ref $record ne 'HASH';
                push @{ $by_tree{$tree} }, { %$record, config => $config };
            }
        }
    }
    foreach my $list ( values %by_tree ) {
        @$list = map { $_->[1] } sort { $a->[0] cmp $b->[0] } map { [ join( "\0", $_->{test} // q{}, $_->{config}, $_->{run} // q{}, sprintf( '%06d', $_->{try} // 0 ) ), $_ ] } @$list;
    }
    return \%by_tree;
}

# The contents of some blobs, read through one git cat-file process.
# @param   ids  ArrayRef[Str]  the blob ids
# @returns HashRef[Str]  the content of each blob that the repository has, by id
# @throws  when git cat-file fails, or prints what it does not document
# @example my $contents = $store->blobs( [$id] );
sub blobs {
    my ( $self, $ids ) = @_;

    my $out = $self->git->run( \join( q{}, map { "$_\n" } @$ids ), qw{cat-file --batch} );
    my %content;
    my $at = 0;
    while ( $at < length $out ) {
        my $end    = index $out, "\n", $at;
        my $header = substr $out, $at, $end - $at;
        $at = $end + 1;
        next if $header =~ m/\s missing \z/sx;
        my ( $id, $size ) = $header =~ m/\A (\S+) \s \S+ \s (\d+) \z/sx or die "git-tms: git cat-file printed '$header'\n";
        $content{$id} = substr $out, $at, $size;
        $at += $size + 1;
    }
    return \%content;
}

# Push every local results ref to a remote.  When the remote refuses a ref
# because another job pushed to it first, fetch that ref, merge it with the
# cat_sort_uniq strategy, and push again, up to three times.
# @param   remote  Str  the name of the remote
# @returns HashRef  pushed, the refs that the remote now has, and merged, the refs that needed a merge first
# @throws  as check_name does; when git push fails for another reason than a refusal; or when a ref is still refused after three tries
# @example my $result = $store->push_to(q{origin});
sub push_to {
    my ( $self, $remote ) = @_;

    check_name( remote => $remote );
    my %config_of = map { $_->{ref} => $_->{config} } grep { !defined $_->{remote} } @{ $self->result_refs() };
    my @pending   = sort keys %config_of;
    my %merged;

    my $tries = 0;
    while ( @pending && $tries++ < $PUSH_TRIES ) {
        my ( $exit, $out, $err ) = $self->git->call( qw{push --porcelain}, $remote, map { "$_:$_" } @pending );
        my @refused = map { m{\A ! \t ([^:]+) :}sx ? $1 : () } split m/\n/sx, $out;
        if ( !$exit ) {
            @pending = ();
            last;
        }
        die "git-tms: git push to $remote failed: $err" if !@refused;

        my %tracking = map { ( $_, join q{/}, $TRACKING, $remote, 'results', $config_of{$_} ) } @refused;
        $self->git->run( 'fetch', $remote, map { "+$_:$tracking{$_}" } @refused );
        $self->git->ensure_identity();
        foreach my $ref (@refused) {
            $self->git->run( 'notes', '--ref', $ref, qw{merge --strategy cat_sort_uniq --quiet}, $tracking{$ref} );
            $merged{$ref} = 1;
        }
        @pending = @refused;
    }
    die "git-tms: $remote still refuses @pending after $PUSH_TRIES tries\n" if @pending;
    return { pushed => [ sort keys %config_of ], merged => [ sort keys %merged ] };
}

# Fetch every results ref of a remote into the refs that it tracks there.  A
# ref that the remote no longer has is removed from them.
# @param   remote  Str  the name of the remote
# @returns ArrayRef[Str]  the configurations that the remote has
# @throws  as check_name does, or when git fetch fails
# @example my $configs = $store->fetch_from(q{origin});
sub fetch_from {
    my ( $self, $remote ) = @_;

    my $tracking = join q{/}, $TRACKING, check_name( remote => $remote ), 'results';
    $self->git->run( qw{fetch --prune --quiet}, $remote, "+$LOCAL/*:$tracking/*" );
    return [ sort map { $_->{config} } grep { ( $_->{remote} // q{} ) eq $remote } @{ $self->result_refs() } ];
}

# The encoder and decoder of a line: UTF-8, with the keys in order, so that the
# same record is always the same line.
sub _json {
    return Cpanel::JSON::XS->new->utf8->canonical;
}

1;
