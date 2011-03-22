package Module::Build::Chado::Role::Loader::Bcs;

use strict;
use warnings;

# Other modules:
use Moose::Role;
use Carp;
use Bio::Chado::Schema;
use Try::Tiny;
use XML::Twig;
use XML::Twig::XPath;
use Graph;
use Graph::Traversal::BFS;
use YAML qw/LoadFile/;
use namespace::autoclean;

# Module implementation
#
requires 'dbh_withcommit';

has 'schema' => (
    is         => 'rw',
    isa        => 'Bio::Chado::Schema',
    lazy_build => 1,
);

has 'loader_instance' => (
    is      => 'rw',
    isa     => 'Bio::Chado::Schema',
    lazy    => 1,
    builder => '_build_schema'
);

has 'obo_xml_loader' => (
    is         => 'rw',
    isa        => 'XML::Twig',
    lazy_build => 1
);

has 'graph' => (
    is      => 'rw',
    isa     => 'Graph',
    default => sub { Graph->new( directed => 1 ) },
    lazy    => 1,
    clearer => 'clear_graph'
);

has 'traverse_graph' => (
    is         => 'rw',
    isa        => 'Graph::Traversal',
    lazy_build => 1,
    handles    => { store_relationship => 'bfs' }
);

before 'dbrow' => sub {
    $_[0]->cvrow if !$_[0]->has_cvrow;
};

before 'get_db_id' => sub {
    $_[0]->dbrow if !$_[0]->has_dbrow;
};

has 'dbrow' => (
    is         => 'rw',
    isa        => 'HashRef[Bio::Chado::Schema::General::Db]',
    traits     => ['Hash'],
    lazy_build => 1,
    handles    => {
        get_dbrow => 'get',
        set_db_id => 'set',
        has_db_id => 'defined'
    }
);

has 'ontology_namespace' => (
    is         => 'rw',
    isa        => 'Str',
    lazy_build => 1
);

has 'loader_tag' => (
    is  => 'rw',
    isa => 'Str'
);

has 'cvrow' => (
    is         => 'rw',
    isa        => 'HashRef[Bio::Chado::Schema::Cv::Cv]',
    traits     => ['Hash'],
    lazy_build => 1,
    handles    => {
        get_cvrow => 'get',
        set_cv_id => 'set',
        has_cv_id => 'defined'
    }
);

has 'obo_xml' => (
    is  => 'rw',
    isa => 'Str'
);

has 'cvterm_row' => (
    is        => 'rw',
    isa       => 'HashRef[Bio::Chado::Schema::Cv::Cvterm]',
    traits    => ['Hash'],
    predicate => 'has_cvterm_row',
    default   => sub { {} },
    lazy      => 1,
    handles   => {
        get_cvterm_row   => 'get',
        set_cvterm_row   => 'set',
        exist_cvterm_row => 'defined'
    }
);

sub cvterm_id_by_name {
    my ( $self, $name ) = @_;

    #check if it is already been cached
    if ( $self->exist_cvterm_row($name) ) {
        return $self->get_cvterm_row($name)->cvterm_id;
    }

    #otherwise try to retrieve from database
    my $rs
        = $self->schema->resultset('Cv::Cvterm')->search( { name => $name } );
    if ( $rs->count > 0 ) {
        $self->set_cvterm_row( $name => $rs->first );
        return $rs->first->cvterm_id;
    }

    #otherwise create one using the default cv namespace
    my $row = $self->schema->resultset('Cv::Cvterm')->create_with(
        {   name   => $name,
            cv     => $self->current_cv,
            db     => $self->current_db,
            dbxref => $self->current_cv . ':' . $name
        }
    );
    $self->set_cvterm_row( $name, $row );
    $row->cvterm_id;
}

sub cvterm_ids_by_namespace {
    my ( $self, $name ) = @_;

    if ( $self->exist_cvrow($name) ) {
        my $ids = [ map { $_->cvterm_id } $self->get_cvrow($name)->cvterms ];
        return $ids;
    }

    my $rs = $self->chado->resultset('Cv::Cv')->search( { name => $name } );
    if ( $rs->count > 0 ) {
        my $row = $rs->first;
        $self->set_cvrow( $name, $row );
        my $ids = [ map { $_->cvterm_id } $row->cvterms ];
        return $ids;
    }
    croak "the given cv namespace $name does not exist : create one \n";
}

sub current_cv {
    my ($self) = @_;
    return
          $self->module_builder->prepend_namespace
        . $self->loader . '-'
        . $self->ontology_namespace;
}

sub current_db {
    my ($self) = @_;
    return $self->current_cv;
}

sub _build_cvrow {
    my ($self)    = @_;
    my $namespace = $self->current_cv;
    my $cvrow     = $self->schema->resultset('Cv::Cv')
        ->find_or_create( { name => $namespace } );
    $cvrow->definition('Ontology namespace for modwareX module');
    $cvrow->update;
    return { $namespace => $cvrow, default => $cvrow };
}

sub _build_dbrow {
    my ($self) = @_;
    my $name   = $self->current_db;
    my $row    = $self->schema->resultset('General::Db')
        ->find_or_create( { name => $name } );
    $row->description('Test database for module modwareX');
    $row->update;
    return { default => $row, $name => $row };

}

sub default_cv_id {
    $_[0]->get_cv_id('default');
}

sub get_cv_id {
    $_[0]->get_cvrow( $_[1] )->cv_id;
}

sub default_db_id {
    $_[0]->get_db_id('default');

}

sub get_db_id {
    $_[0]->get_dbrow( $_[1] )->db_id;
}

sub lookup_cv_id {
    my ( $self, $namespace ) = @_;
    my $schema = $self->schema;
    if ( $self->has_cv_id($namespace) ) {
        return $self->get_cv_id($namespace);
    }
    my $cvrow;
    try {
        $cvrow = $schema->txn_do(
            sub {
                my $name  = 'Modware-' . $self->loader_tag . '-' . $namespace;
                my $cvrow = $schema->resultset('Cv::Cv')->create(
                    {   name       => $name,
                        definition => "Ontology namespace for modwarex module"
                    }
                );
                $cvrow;
            }
        );
    }
    catch {
        confess "unable to create cv row: $_";
    };
    $self->set_cv_id( $namespace, $cvrow );
    $cvrow->cv_id;
}

sub lookup_db_id {
    my ( $self, $dbname ) = @_;
    my $schema = $self->schema;
    if ( $self->has_db_id($dbname) ) {
        return $self->get_db_id($dbname);
    }
    my $dbrow;
    try {
        $dbrow = $schema->txn_do(
            sub {
                my $name  = $self->current_db . '-' . $dbname;
                my $dbrow = $schema->resultset('General::Db')->create(
                    {   name        => $name,
                        description => "Ontology dbname for modwarex module"
                    }
                );
                $dbrow;
            }
        );
    }
    catch {
        confess "unable to create db row: $_";
    };
    $self->set_db_id( $dbname, $dbrow );
    $dbrow->db_id;
}

sub _build_schema {
    my ($self) = @_;
    Bio::Chado::Schema->connect( sub { $self->dbh_withcommit } );
}

sub _build_obo_xml_loader {
    my ($self) = @_;
    XML::Twig->new(
        twig_handlers => {
            term    => sub { $self->load_term(@_) },
            typedef => sub { $self->load_typedef(@_) }
        }
    );
}

sub _build_ontology_namespace {
    my $self = shift;

    #which namespace to use incase it is not present for a particular node
    my $twig = XML::Twig::XPath->new->parsefile( $self->obo_xml );
    my ($node) = $twig->findnodes('/obo/header/default-namespace');
    my $namespace = $node->getValue;
    $twig->purge;
    confess "no default namespace being set for this ontology" if !$namespace;
    return $namespace;
}

sub _build_traverse_graph {
    my ($self) = @_;
    Graph::Traversal::BFS->new(
        $self->graph,
        pre_edge => sub {
            $self->handle_relationship(@_);
        },
        back_edge => sub {
            $self->handle_relationship(@_);
        },
        down_edge => sub {
            $self->handle_relationship(@_);
        },
        non_tree_edge => sub {
            $self->handle_relationship(@_);
        },
    );
}

sub reset_all {
    my ($self) = @_;
    $self->clear_graph;
    $self->clear_traverse_graph;
    $self->clear_dbrow;
    $self->clear_cvrow;
    $self->clear_ontology_namespace;
}

sub load_organism {
    my $self     = shift;
    my $organism = LoadFile( $self->module_builder->organism_fixture );
    unshift @$organism, [qw/abbreviation genus species common_name/];

    my $schema = $self->schema;
    try {
        $schema->txn_do(
            sub {
                $schema->populate( 'Organism::Organism', $organism );
            }
        );
    }
    catch {
        confess "error: $_";
    };
}

sub unload_organism {
    my ($self) = @_;
    my $schema = $self->schema;
    try {
        $schema->txn_do(
            sub {
                $schema->resultset('Organism::Organism')
                    ->search( {},
                    { columns => [ 'organism_id', 'common_name' ] } )
                    ->delete_all;
            }
        );
    }
    catch {
        confess "error in deletion: $_";
    };
}

sub load_pub {
    my ($self) = @_;
    $self->clear_ontology_namespace;
    $self->obo_xml( $self->module_builder->pub_fixture );
    $self->load_ontology;

}

sub load_rel {
    my ($self) = @_;
    $self->clear_ontology_namespace;
    $self->obo_xml( $self->module_builder->rel_fixture );
    $self->load_ontology;
}

sub load_so {
    my ($self) = @_;
    $self->clear_ontology_namespace;
    $self->obo_xml( $self->module_builder->so_fixture );
    $self->load_ontology;

}

sub load_dicty_keywords {
    my ($self) = @_;
    $self->clear_ontology_namespace;
    $self->obo_xml( $self->module_builder->dicty_keywords_fixture );
    $self->load_ontology;

}

sub load_journal_data {
    my ($self) = @_;
    $self->ontology_namespace('publication');
    my $file = $self->module_builder->journal_fixture;

    my $source = 'Medline';
    my $type   = 'journal_article';

    my $biblio = Bio::Biblio::IO->new(
        -file   => $file,
        -format => 'medlinexml',
        -result => 'medline2ref'
    );

    while ( my $citation = $biblio->next_bibref ) {
        my $count = 1;
        my $authors;
        for my $person ( @{ $citation->authors } ) {
            push @$authors,
                {
                suffix     => $person->suffix,
                surname    => $person->lastname,
                givennames => $person->initials . ' ' . $person->forename,
                rank       => $count++
                };
        }
        $count = 0;

        $self->schema->txn_do(
            sub {
                my $row = $self->schema->resultset('Pub::Pub')->create(
                    {   uniquename => 'PUB' . int( rand(9999999) ),
                        type_id    => $self->cvterm_id_by_name($type),
                        pubplace   => $source,
                        title      => $citation->title,
                        pyear      => $citation->date,
                        pages      => $citation->first_page . '--'
                            . $citation->last_page,
                        series_name => $citation->journal->name,
                        issue       => $citation->issue,
                        volume      => $citation->volume,
                        pubauthors  => $authors,
                        pubprops    => [
                            {   type_id => $self->cvterm_id_by_name('status'),
                                value   => $citation->status,

                            },
                            {   type_id =>
                                    $self->cvterm_id_by_name('abstract'),
                                value => $citation->abstract
                            },
                            {   type_id => $self->cvterm_id_by_name(
                                    'journal_abbreviation'),
                                value => $citation->journal->abbreviation
                            }
                        ]
                    }
                );
                $row->add_to_pub_dbxrefs(
                    {   dbxref => {
                            accession => $citation->journal->issn,
                            db_id     => $self->lookup_db_id('issn')
                        }
                    }
                );
            }
        );
    }

    $file   = $self->module_builder->pubmed_fixture;
    $source = 'Pubmed';
    $type   = 'pubmed_journal_article';

    $biblio = Bio::Biblio::IO->new(
        -file   => $file,
        -format => 'pubmedxml',
    );

    while ( my $citation = $biblio->next_bibref ) {
        my $count = 1;
        my $authors;
        for my $person ( @{ $citation->authors } ) {
            push @$authors,
                {
                suffix     => $person->suffix,
                surname    => $person->lastname,
                givennames => $person->initials . ' ' . $person->forename,
                rank       => $count++
                };
        }
        $count = 0;

        $self->schema->txn_do(
            sub {
                my $row = $self->schema->resultset('Pub::Pub')->create(
                    {   uniquename  => $citation->pmid,
                        type_id     => $self->cvterm_id_by_name($type),
                        pubplace    => $source,
                        title       => $citation->title,
                        pyear       => $citation->date,
                        series_name => $citation->journal->name,
                        issue       => $citation->issue,
                        volume      => $citation->volume,
                        pubauthors  => $authors,
                        pubprops    => [
                            {   type_id => $self->cvterm_id_by_name('status'),
                                value   => $citation->status,

                            },
                            {   type_id =>
                                    $self->cvterm_id_by_name('abstract'),
                                value => $citation->abstract
                            },
                            {   type_id => $self->cvterm_id_by_name(
                                    'journal_abbreviation'),
                                value => $citation->journal->abbreviation
                                    || $citation->journal->name
                            }
                        ]
                    }
                );
                $row->add_to_pub_dbxrefs(
                    {   dbxref => {
                            accession => $citation->journal->issn,
                            db_id     => $self->lookup_db_id('issn')
                        }
                    }
                );
            }
        );
    }
}

sub load_ontology {
    my ($self) = @_;
    $self->reset_all;
    my $loader = $self->obo_xml_loader;
    $loader->parsefile( $self->obo_xml );
    $loader->purge;
    $self->store_relationship;

}

sub load_fixture {
    my $self = shift;
    $self->load_organism;
    $self->load_rel;
    $self->load_so;
}

sub unload_pub {
    my ($self) = @_;
    $self->clear_ontology_namespace;
    $self->obo_xml( $self->module_builder->pub_fixture );
    $self->unload_ontology( $self->current_cv );
}

sub unload_rel {
    my ($self) = @_;
    $self->clear_ontology_namespace;
    $self->obo_xml( $self->module_builder->rel_fixture );
    $self->unload_ontology( $self->current_cv );
}

sub unload_so {
    my ($self) = @_;
    $self->clear_ontology_namespace;
    $self->obo_xml( $self->module_builder->so_fixture );
    $self->unload_ontology( $self->current_cv );
}

sub unload_dicty_keywords {
    my ($self) = @_;
    $self->clear_ontology_namespace;
    $self->obo_xml( $self->module_builder->dicty_keywords_fixture );
    $self->unload_ontology( $self->current_cv );
}

sub unload_ontology {
    my ( $self, $name ) = @_;
    my $schema = $self->schema;
    try {
        $schema->txn_do(
            sub {
                $schema->resultset('General::Db')->search( { name => $name } )
                    ->delete_all;
                $schema->resultset('Cv::Cv')->search( { name => $name } )
                    ->delete_all;
            }
        );
    }
    catch {
        confess "error in deleting: $_";
    }
}

sub handle_relationship {
    my ( $self, $parent, $child, $traverse ) = @_;
    my ( $relation_id, $parent_id, $child_id );

    # -- relation/edge
    if ( $self->graph->has_edge_attribute( $parent, $child, 'id' ) ) {
        $relation_id
            = $self->graph->get_edge_attribute( $parent, $child, 'id' );
    }
    else {

        # -- get the id from the storage
        $relation_id = $self->name2id(
            $self->graph->get_edge_attribute(
                $parent, $child, 'relationship'
            ),
        );
        $self->graph->set_edge_attribute( $parent, $child, 'id',
            $relation_id );
    }

    # -- parent
    if ( $self->graph->has_vertex_attribute( $parent, 'id' ) ) {
        $parent_id = $self->graph->get_vertex_attribute( $parent, 'id' );
    }
    else {
        $parent_id = $self->name2id($parent);
        $self->graph->set_vertex_attribute( $parent, 'id', $parent_id );
    }

    # -- child
    if ( $self->graph->has_vertex_attribute( $child, 'id' ) ) {
        $child_id = $self->graph->get_vertex_attribute( $child, 'id' );
    }
    else {
        $child_id = $self->name2id($child);
        $self->graph->set_vertex_attribute( $child, 'id', $child_id );
    }

    my $schema = $self->schema;
    try {
        $schema->txn_do(
            sub {
                $schema->resultset('Cv::CvtermRelationship')->create(
                    {   object_id  => $parent_id,
                        subject_id => $child_id,
                        type_id    => $relation_id
                    }
                );
            }
        );
    }
    catch { confess "error in inserting: $_" };
}

sub name2id {
    my ( $self, $name ) = @_;
    my $row = $self->schema->resultset('Cv::Cvterm')
        ->search( { 'name' => $name, }, { rows => 1 } )->single;

    if ( !$row ) {    #try again in dbxref
        $row
            = $self->schema->resultset('General::Dbxref')
            ->search( { accession => { -like => '%' . $name } },
            { rows => 1 } )->single;
        if ( !$row ) {
            $self->alert("serious problem: **$name** nowhere to be found");
            return;
        }
        return $row->cvterm->cvterm_id;
    }
    $row->cvterm_id;
}

sub build_relationship {
    my ( $self, $node, $cvterm_row ) = @_;
    my $child = $cvterm_row->name;
    for my $elem ( $node->children('is_a') ) {
        my $parent = $self->normalize_name( $elem->text );
        $self->graph->set_edge_attribute( $parent, $child, 'relationship',
            'is_a' );
    }

    for my $elem ( $node->children('relationship') ) {
        my $parent = $self->normalize_name( $elem->first_child_text('to') );
        $self->graph->add_edge( $parent, $child );
        $self->graph->set_edge_attribute( $parent, $child, 'relationship',
            $self->normalize_name( $elem->first_child_text('type') ) );
    }
}

sub load_typedef {
    my ( $self, $twig, $node ) = @_;

    my $name        = $node->first_child_text('name');
    my $id          = $node->first_child_text('id');
    my $is_obsolete = $node->first_child_text('is_obsolete');
    my $namespace = $self->current_cv;

    my $def_elem = $node->first_child('def');
    my $definition;
    $definition = $def_elem->first_child_text('defstr') if $def_elem;

    my $schema = $self->schema;
    my $cvterm_row;
    try {
        $cvterm_row = $schema->txn_do(
            sub {
                my $cvterm_row = $schema->resultset('Cv::Cvterm')->create(
                    {   cv_id => $self->lookup_cv_id($namespace),
                        is_relationshiptype => 1,
                        name                => $self->normalize_name($name),
                        definition          => $definition || '',
                        is_obsolete         => $is_obsolete || 0,
                        dbxref              => {
                            db_id     => $self->lookup_db_id($namespace),
                            accession => $id,
                        }
                    }
                );
                $cvterm_row;
            }
        );
    }
    catch {
        confess "Error in inserting cvterm $_\n";
    };

    #hold on to the relationships between nodes
    $self->build_relationship( $node, $cvterm_row );

    #no additional dbxref
    return if !$def_elem;

    $self->create_more_dbxref( $def_elem, $cvterm_row, $namespace );
}

sub load_term {
    my ( $self, $twig, $node ) = @_;

    my $name        = $node->first_child_text('name');
    my $id          = $node->first_child_text('id');
    my $is_obsolete = $node->first_child_text('is_obsolete');
    my $namespace = $self->current_cv;

    my $def_elem = $node->first_child('def');
    my $definition;
    $definition = $def_elem->first_child_text('defstr') if $def_elem;

    my $schema = $self->schema;
    my $cvterm_row;
    try {
        $cvterm_row = $schema->txn_do(
            sub {
                my $cvterm_row = $schema->resultset('Cv::Cvterm')->create(
                    {   cv_id       => $self->lookup_cv_id($namespace),
                        name        => $self->normalize_name($name),
                        definition  => $definition || '',
                        is_obsolete => $is_obsolete || 0,
                        dbxref      => {
                            db_id     => $self->lookup_db_id($namespace),
                            accession => $id,
                        }
                    }
                );
                $cvterm_row;
            }
        );
    }
    catch {
        confess "Error in inserting cvterm $_\n";
    };

    #hold on to the relationships between nodes
    $self->build_relationship( $node, $cvterm_row );

    #no additional dbxref
    return if !$def_elem;

    $self->create_more_dbxref( $def_elem, $cvterm_row, $namespace );
}

sub normalize_name {
    my ( $self, $name ) = @_;
    return $name if $name !~ /:/;
    my $value = ( ( split /:/, $name ) )[1];
    return $value;
}

sub create_more_dbxref {
    my ( $self, $def_elem, $cvterm_row, $namespace ) = @_;
    my $schema = $self->schema;

    # - first one goes with alternate id
    my $alt_id = $def_elem->first_child_text('alt_id');
    if ($alt_id) {
        try {
            $schema->txn_do(
                sub {
                    $cvterm_row->create_related(
                        'cvterm_dbxrefs',
                        {   dbxref => {
                                accession => $alt_id,
                                db_id     => $self->lookup_db_id($namespace)
                            }
                        }
                    );
                }
            );
        }
        catch {
            confess "error in creating dbxref $_";
        };
    }

    #no more additional dbxrefs
    my $def_dbx = $def_elem->first_child('dbxref');
    return if !$def_dbx;

    my $dbname = $def_dbx->first_child_text('dbname');
    try {
        $schema->txn_do(
            sub {
                $cvterm_row->create_related(
                    'cvterm_dbxrefs',
                    {   dbxref => {
                            accession => $def_dbx->first_child_text('acc'),
                            db_id     => $self->lookup_db_id($dbname)
                        }
                    }
                );
            }
        );
    }
    catch { confess "error in creating dbxref $_" };
}

1;    # Magic true value required at end of module

# ABSTRACT: L<Bio::Chado::Schema> base Moose role to load and unload fixtures in chado  database


=attr schema

Bio::Chado::Schema instance

=attr obo_xml_loader

XML::Twig instance

=attr graph

Graph instance for DAG 

=attr traverse_graph

Graph::Traversal instance for DAG

=attr ontology_namespace

=attr obo_xml

obo_xml file that is currently getting loaded


=method current_cv

Current cv that is getting loaded

=method current_db

Current db name

=method reset_all

Reset all attributes

=method load_organism

=method load_rel

=method load_so

=method unload_organism

=method unload_rel

=method unload_so

=method load_fixture

Runs all the load methods in succession

=method load_ontology

Loads ontology from an obo_xml file

=method load_term

Loads the term section of obo_xml file

=method load_typedef

Loads the typedef section of obo_xml file
