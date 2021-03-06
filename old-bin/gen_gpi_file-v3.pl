#!/usr/bin/perl -w

use strict;
use feature qw/say/;

use DBI;

use Getopt::Long;
use IO::File;
use autodie qw/open close/;
use Text::CSV;

# Validation section
my %options;
GetOptions( \%options, 'dsn=s', 'user=s', 'passwd=s' );
for my $arg (qw/dsn user passwd/) {
    die
        "\tperl gen_gpi_file.pl -dsn=ORACLE_DNS -user=USERNAME -passwd=PASSWD\n\n"
        if not defined $options{$arg};
}

my $host = $options{dsn};
my $user = $options{user};
my $pass = $options{passwd};

print "Connecting to the database... ";
my $dbh = DBI->connect( "dbi:Oracle:host=$host;sid=orcl;port=1521",
    $options{user}, $options{passwd},
    { RaiseError => 1, LongReadLen => 2**20 } );
say " done!!";

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Database setup
# Statement: 1 to 1
# It selects DDB_G ID and gene name from the database
# Excludes pseudogenes
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

my $statement = <<"STATEMENT";
SELECT dbxref.accession gene_id, gene.feature_id, gene.name
FROM cgm_chado.feature gene
JOIN organism ON organism.organism_id=gene.organism_id
JOIN dbxref on dbxref.dbxref_id=gene.dbxref_id
JOIN cgm_chado.cvterm gtype on gtype.cvterm_id=gene.type_id
JOIN cgm_chado.feature_relationship frel ON frel.object_id=gene.feature_id
JOIN cgm_chado.feature mrna ON frel.subject_id=mrna.feature_id
JOIN cgm_chado.cvterm mtype ON mtype.cvterm_id=mrna.type_id
WHERE gtype.name='gene' 
        AND mtype.name='mRNA' 
        AND organism.common_name = 'dicty' 
        AND gene.is_deleted = 0 
        AND gene.name NOT LIKE '%\\_ps%' ESCAPE '\\'
        AND gene.name NOT LIKE '%\\_TE%' ESCAPE '\\'
        AND gene.name NOT LIKE '%\\_RTE%' ESCAPE '\\'
STATEMENT

print "> Execute statement... ";

my $results = $dbh->prepare($statement);
$results->execute()
    or die "\n\nOh no! I could not execute: " . DBI->errstr . "\n\n";

say " done!!";


my %ddbg2gene_name    = ();
my %ddbg2locus_number = ();
my $count_prot_coding = 0;
my $unique            = 0;
my $duplications      = 0;

while ( my ( $DDB_G, $locus_no, $gene_name ) = $results->fetchrow_array ) {

    if ( !$ddbg2gene_name{$DDB_G} ) {
        $ddbg2gene_name{$DDB_G} = $gene_name;
        $unique++;
    }
    else {
        $duplications++;
    }
    $ddbg2locus_number{$DDB_G} = $locus_no;
    $count_prot_coding++;
}

say "Total number of DDB_G_ID: " . $unique;


# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Database setup
# Statement: 1 to 1
# For each DDB_G ID, get the uniprot ID
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

my $statement_ddb2uniprot = <<"STATEMENT";
SELECT gxref.accession geneid, dbxref.accession uniprot
FROM dbxref
    JOIN db ON db.db_id = dbxref.db_id
    JOIN feature_dbxref fxref ON fxref.dbxref_id = dbxref.dbxref_id
    JOIN feature polypeptide ON polypeptide.feature_id = fxref.feature_id
    JOIN feature_relationship frel ON polypeptide.feature_id = frel.subject_id
    JOIN feature transcript ON transcript.feature_id = frel.object_id
    JOIN feature_dbxref fxref2 ON fxref2.feature_id = transcript.feature_id
    JOIN dbxref dbxref2 ON fxref2.dbxref_id = dbxref2.dbxref_id
    JOIN db db2 ON db2.db_id = dbxref2.db_id
    JOIN feature_relationship frel2 ON frel2.subject_id = transcript.feature_id
    JOIN feature gene ON frel2.object_id = gene.feature_id
    JOIN cvterm ptype ON ptype.cvterm_id = polypeptide.type_id
    JOIN cvterm mtype ON mtype.cvterm_id = transcript.type_id
    JOIN cvterm gtype ON gtype.cvterm_id = gene.type_id
    JOIN dbxref gxref ON gene.dbxref_id = gxref.dbxref_id
WHERE 
    ptype.name = 'polypeptide'
    AND mtype.name = 'mRNA'
    AND gtype.name = 'gene'
    AND db2.name = 'GFF_source'
    AND db.name = 'DB:SwissProt'
    AND gxref.accession = ?
STATEMENT
#AND dbxref2.accession = 'dictyBase Curator'
#AND     AND transcript.is_deleted = 0

my %hash_ddbg2uniprot = ();

my $yes = 0;
my $no = 0;
for my $ddbg_id ( sort keys %ddbg2gene_name ) {
    my @uniprot = $dbh->selectrow_array($statement_ddb2uniprot, {}, ($ddbg_id) );
    if ($uniprot[0])
    {
        # say $uniprot[0];
        $hash_ddbg2uniprot{$ddbg_id} = $uniprot[0];
        $yes++;
    }
    else
    {
        say "$ddbg_id";
        $no++;
    }
}

say "yes ".$yes;
say "no ". $no;
exit;




# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Database setup
# Statement: 1 to 1
# DDB_G ID and gene PRODUCTS from the database
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

my $statement_geneproduct = <<"STATEMENT";
SELECT gporder.gene_product FROM (
SELECT gp.gene_product
FROM cgm_ddb.gene_product gp
INNER JOIN cgm_ddb.locus_gp lgp ON lgp.gene_product_no = gp.gene_product_no
WHERE lgp.locus_no = ?
ORDER BY date_created DESC
) gporder
WHERE rownum = 1
STATEMENT

# SELECT dx.accession AS DDB_G_ID,
my $result_product = $dbh->prepare($statement_geneproduct);
my $count_u  = 0;    # count unknowns gene products
my $count_t  = 1;
my $count_gp = 0;

for my $ddb ( sort keys %ddbg2locus_number ) {
    my $locus_no = $ddbg2locus_number{$ddb};
    $result_product->execute($locus_no);
    my $gene_product;

    # print $count_t. " "
    #     . $ddb . " -> "
    #     . $ddbg2locus_number{$ddb} . "\t"
    #     . $ddbg2gene_name{$ddb} . "\t";
    while ( ($gene_product) = $result_product->fetchrow_array ) {

        # print $gene_product ;
        if ( $gene_product eq "unknown" ) {
            $count_u++;
        }
        $count_gp++;
    }
    $count_t++;

    # print "\n";
}

say "WITH GENE PRODUCT: "
    . $count_gp
    . " (unknown: "
    . $count_u
    . ") out of a total of "
    . $count_t;

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Database setup
# Statement: 1 to many
# For each DDB_G ID, get all the gene and protein alternative names
# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

my $statement_syn = <<"STATEMENT";
SELECT wm_concat(syn.name) gsyn
FROM cgm_chado.feature gene
JOIN dbxref on dbxref.dbxref_id=gene.dbxref_id
LEFT JOIN cgm_chado.feature_synonym fsyn on gene.feature_id=fsyn.feature_id
LEFT JOIN cgm_chado.synonym_ syn on syn.synonym_id=fsyn.SYNONYM_ID
WHERE dbxref.accession = ?
GROUP BY dbxref.accession
STATEMENT

my $result_syn  = $dbh->prepare($statement_syn);
my $count_syn   = 0;
my $count_nosyn = 0;
my $total       = 1;
for my $ddbg_id ( sort keys %ddbg2gene_name ) {
    
    $result_syn->execute($ddbg_id);

    # print $total. " " . $ddbg_id . "\t";
    my $syn = '';
    while ( ($syn) = $result_syn->fetchrow_array ) {
        if ($syn) {

            # print $syn . "\n";
            $count_syn++;
        }
        else {
            # print "null\n";
            $count_nosyn++;
        }
    }    # while
    $total++;
}






# -------------------------------------------------------------
# Print out STATS
# Gene product
say "Gene products: "
    . $count_gp
    . " (unkowns: "
    . $count_u
    . ") out of "
    . $count_t;

# Alternative gene and protein names
say "\nTotal DDB_G ids: " . ( $total - 1 );
say "\tWith syn: " . $count_syn;
say "\tNO syn  : " . $count_nosyn;

$dbh->disconnect();

exit;

=head1 NAME

gen_gpi_file-v3.pl - Generate a GPI file from the dictyBase

=head1 VERSION
 
Version 3


=head1 SYNOPSIS

perl gen_gpi_file-v3.pl  --dsn=<Oracle DSN> --user=<Oracle user> --passwd=<Oracle password>


=head1 OPTIONS

 --dsn           Oracle database DSN
 --user          Database user name
 --passwd        Database password

=head1 OUTPUT

YYYYMMDD_HHMMSS.gpi_dicty

=head1 DESCRIPTION

Connect to the dictyOracle database and dump to a file
(YYYYMMDD_HHMMSS.gpi_dicty) the following information:

- DDB_G ID
- Gene name 
- Gene product
- Alternative gene name


=head1 DETAILS

Additional information about the GPI format can be found in the following url:
http://wiki.geneontology.org/index.php/Final_GPAD_and_GPI_file_format

=head1 ISSUES

Statement 3 needs to be revised. According to the curation statistics, there
should be ~9,000 gene products. However this script gets less.



