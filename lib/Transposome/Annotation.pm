package Transposome::Annotation;

use 5.010;
use Moose;
use MooseX::Types::Moose qw(ArrayRef HashRef Int Num Str ScalarRef); 
use IPC::System::Simple  qw(system capture EXIT_ANY);
use List::Util           qw(sum max);
use File::Path           qw(make_path);
use Storable             qw(thaw);
use POSIX                qw(strftime);
use List::MoreUtils      qw(first_index);
use Method::Signatures;
use Path::Class::File;
use File::Basename;
use File::Spec;
use Try::Tiny;
use namespace::autoclean;

with 'MooseX::Log::Log4perl',
     'Transposome::Annotation::Typemap', 
     'Transposome::Role::File', 
     'Transposome::Role::Util';

=head1 NAME

Transposome::Annotation - Annotate clusters for repeat types.

=head1 VERSION

Version 0.09.1

=cut

our $VERSION = '0.09.1';
$VERSION = eval $VERSION;

=head1 SYNOPSIS

    use Transposome::Annotation;

    my $cluster_file = '/path/to/cluster_file.cls';
    my $seqct        = 'total_seqs_in_analysis';  # Integer
    my $cls_tot      = 'total_reads_clustered';   # Integer

    my $annotation = Transposome::Annotation->new( database  => 'repeat_db.fas',
                                                   dir       => 'outdir',
                                                   file      => 'report.txt' );

    my $annotation_results = 
       $annotation->annotate_clusters({ cluster_directory  => $cls_dir_path,
                                        singletons_file    => $singletons_file_path,
                                        total_sequence_num => $seqct,
                                        total_cluster_num  => $cls_tot });
    
 
    $annotation->clusters_annotation_to_summary( $annotation_results );

=cut

has 'database' => (
      is       => 'ro',
      isa      => 'Path::Class::File',
      required => 1,
      coerce   => 1,
);

has 'evalue' => (
    is       => 'ro',
    isa      => 'Num',
    default  => 10,
);

has 'report' => (
      is       => 'ro',
      isa      => 'Path::Class::File',
      required => 0,
      coerce   => 1,
);

has 'blastn_exec' => (
    is        => 'rw',
    isa       => 'Str',
    reader    => 'get_blastn_exec',
    writer    => 'set_blastn_exec',
    predicate => 'has_blastn_exec',
);

has 'makeblastdb_exec' => (
    is        => 'rw',
    isa       => 'Str',
    reader    => 'get_makeblastdb_exec',
    writer    => 'set_makeblastdb_exec',
    predicate => 'has_makeblastdb_exec',
);

method BUILD (@_) {
    my @path = split /:|;/, $ENV{PATH};

    for my $p (@path) {
	my $bl = File::Spec->catfile($p, 'blastn');
	my $mb = File::Spec->catfile($p, 'makeblastdb');

        if (-e $bl && -x $bl && -e $mb && -x $mb) {
            $self->set_blastn_exec($bl);
            $self->set_makeblastdb_exec($mb);
        }
    }

    try {
        die unless $self->has_makeblastdb_exec;
    }
    catch {
	if (Log::Log4perl::initialized()) {
	    $self->log->error("Unable to find makeblastdb. Check you PATH to see that it is installed. Exiting.");
	}
	else {
	    say STDERR "Unable to find makeblastdb. Check you PATH to see that it is installed. Exiting.";
	}
	exit(1);
    };

    try {
        die unless $self->has_blastn_exec;
    }
    catch {
	if (Log::Log4perl::initialized()) {
	    $self->log->error("Unable to find blastn. Check you PATH to see that it is installed. Exiting.");
	}
	else {
	    say STDERR "Unable to find blastn. Check you PATH to see that it is installed. Exiting.";
	}
	exit(1);
    };
}
    
=head1 METHODS

=head2 annotate_clusters

 Title   : annotation_clusters

 Usage   : $annotation->annotate_clusters();
           
 Function: Runs the annotation pipeline within Transposome.

                                                                           
 Returns : A Perl hash containing the cluster annotation results.

           The following is an example data structure returned by
           the annotate_clusters method:

           { annotation_report     => $anno_rp_path,
             annotation_summary    => $anno_sum_rep_path,
             singletons_report     => $singles_rp_path,
             total_sequence_num    => $total_readct,
             repeat_fraction       => $rep_frac,
             cluster_blast_reports => $blasts,
             cluster_superfamilies => $superfams }

           A description of the hash values returned:
                                                                            Return_type
           annotation_report - path to the cluster annotation file          Scalar
           annotation_summary - path to the cluster annotation summary      Scalar 
                                file        
           singletons_file - path to the singletons annotation file         Scalar
           total_sequence_num - the total number of reads clusters          Scalar
           repeat_fraction - the repeat fraction of the genome              Scalar
           cluster_blast_reports - the individual cluster blast reports     ArrayRef
           cluster_suparfamilies - the top superfamily hit for each         ArraryRef
                                   cluster

                                                                           
 Args    : A Perl hash containing data for annotation.

           The following is an example data structure taken by 
           the annotate_clusters method:

           { cluster_directory  => $cls_dir_path,
             singletons_file    => $singletons_file_path,
             total_sequence_num => $seqct,
             total_cluster_num  => $cls_tot }

           A description of the hash values taken:
                                                                            Arg_type
           cluster_directory - the directory of cluster FASTA files         Scalar
           singletons_file - the FASTA file of singleton sequences          Scalar
           total_sequence_num - the number of sequences that went into      Scalar
                                the clustering (returned from store_seq() 
                                from Transposome::SeqStore), 
           total_cluster_num - the total number of clusters (also           Scalar 
                               returned from make_clusters() from 
                               Transposome::Cluster).

=cut

method annotate_clusters (HashRef $cluster_data) {
    my $cls_with_merges_dir  = $cluster_data->{cluster_directory};
    my $singletons_file_path = $cluster_data->{singletons_file};
    my $seqct   = $cluster_data->{total_sequence_num};
    my $cls_tot = $cluster_data->{total_cluster_num};

    # set paths for annotate_clusters() method
    my $database = $self->database->absolute;
    my $db_path  = $self->_make_blastdb($database);
    my $out_dir  = $self->dir->relative;
    my $blastn   = $self->get_blastn_exec;

    # cluster report path
    my $report   = $self->file->relative;
    my ($rpname, $rppath, $rpsuffix) = fileparse($report, qr/\.[^.]*/);
    my $rp_path  = Path::Class::File->new($out_dir, $rpname.$rpsuffix);

    # set paths for annotation files
    my $anno_rep          = $rpname."_annotations.tsv";
    my $anno_summary_rep  = $rpname."_annotations_summary.tsv";
    my $anno_rp_path      = Path::Class::File->new($out_dir, $anno_rep);
    my $anno_sum_rep_path = Path::Class::File->new($out_dir, $anno_summary_rep);

    # results and variables controlling method behavior
    my $thread_range = sprintf("%.0f", $self->threads * $self->cpus);
    my $total_readct = 0;
    my $evalue       = $self->evalue;
    my $rep_frac     = $cls_tot / $seqct;
    my $single_tot   = $seqct - $cls_tot;
    my $single_frac  = 1 - $rep_frac;
   
    # log results
    my $st = POSIX::strftime('%d-%m-%Y %H:%M:%S', localtime);
    if (Log::Log4perl::initialized()) {
        $self->log->info("Transposome::Annotation::annotate_clusters started at:   $st.");
    }
    else {
	say STDERR "Transposome::Annotation::annotate_clusters started at:   $st." if $self->verbose;
    }

    my $repeat_typemap = $self->map_repeat_types($database);
    my %repeats        = %{ thaw($repeat_typemap) };

    ## get input files
    opendir my $dir, $cls_with_merges_dir || die "\n[ERROR]: Could not open directory: $cls_with_merges_dir. Exiting.\n";
    my @clus_fas_files = grep /^CL.*fa.*$|^G.*fa.*$/, readdir $dir;
    closedir $dir;

    if (@clus_fas_files < 1) {
	if (Log::Log4perl::initialized()) {
        $self->log->error("Could not find any fasta files in $cls_with_merges_dir. ".
			  "This can result from using too few sequences. ".
			  "Please report this error if the problem persists. Exiting.");
	}
	else {
	    say STDERR "Could not find any fasta files in $cls_with_merges_dir. ".
		"This can result from using too few sequences. ".
		"Please report this error if the problem persists. Exiting.";
	}
        exit(1);
    }

    ## set path to output dir
    my $annodir  = $cls_with_merges_dir."_annotations";
    my $out_path = File::Spec->rel2abs($annodir);
    make_path($annodir, {verbose => 0, mode => 0711,});

    # data structures for holding mapping results
    my @blast_out;               # container for blastn output
    my %all_cluster_annotations; # container for annotations; used for creating summary

    ## annotate singletons, then add total to results
    my ($singleton_hits, $singleton_rep_frac, $singles_rp_path, $blasts, $superfams, 
	$cluster_annotations, $top_hit_superfam, $cluster_annot) = 
    $self->_annotate_singletons(\%repeats, $singletons_file_path, $rpname, $single_tot, 
				$evalue, $thread_range, $db_path, $out_dir, $blastn);

    my $true_singleton_rep_frac = $single_frac * $singleton_rep_frac;
    my $total_rep_frac = $true_singleton_rep_frac + $rep_frac;

    for my $file (@clus_fas_files) {
	next if $file =~ /singletons/;
	my $query = File::Spec->catfile($cls_with_merges_dir, $file);
        my ($fname, $fpath, $fsuffix) = fileparse($query, qr/\.[^.]*/);
        my $blast_res = $fname;
        my ($filebase, $readct) = split /\_/, $fname, 2;
        $total_readct += $readct;
        $blast_res =~ s/\.[^.]+$//;
        $blast_res .= "_blast_$evalue.tsv";
	my $blast_file_path = Path::Class::File->new($out_path, $blast_res);

        my @blastcmd = "$blastn -dust no -query $query -evalue $evalue -db $db_path -outfmt 6 -num_threads $thread_range | ".
                       "sort -k1,1 -u | ".                       # count each read in the report only once
		       "cut -f2 | ".                             # keep only the ssids        
                       "sort | ".                                # sort the list
                       "uniq -c | ".                             # reduce the list
                       "sort -bnr | ".                           # count unique items
                       "perl -lane 'print join(\"\\t\",\@F)'";   # create an easy to parse format
	
	try {
	    @blast_out = capture(EXIT_ANY, @blastcmd);
	}
	catch {
	    if (Log::Log4perl::initialized()) {
		$self->log->error("blastn failed. Caught error: $_.");
	    }
	    else {
		say STDERR "blastn failed. Caught error: $_.";
	    }
	    exit(1);
	};

	my ($hit_ct, $top_hit, $top_hit_perc, $blhits) = $self->_parse_blast_to_top_hit(\@blast_out, $blast_file_path);
        next unless defined $top_hit && defined $hit_ct;
                                                           
        push @$blasts, $blhits unless !%$blhits;
        ($top_hit_superfam, $cluster_annot) = $self->_blast_to_annotation(\%repeats, $filebase, $readct, $top_hit, $top_hit_perc); 
        push @$superfams, $top_hit_superfam unless !%$top_hit_superfam;
	push @$cluster_annotations, $cluster_annot unless !%$cluster_annot;
    }

    @all_cluster_annotations{keys %$_} = values %$_ for @$cluster_annotations;

    open my $out, '>', $anno_rp_path or die "\n[ERROR]: Could not open file: $anno_rp_path\n";
    say $out join "\t", "Cluster", "Read_count", "Type", "Class", "Superfamily", "Family","Top_hit","Top_hit_frac";

    for my $readct (reverse sort { $a <=> $b } keys %all_cluster_annotations) {
	my @annots  = $self->mk_vec($all_cluster_annotations{$readct});
	my $cluster = shift @annots;
	say $out join "\t", $cluster, $readct, join "\t", @annots;
    }
    close $out;
    unlink glob("$db_path*");

    # log results
    my $ft = POSIX::strftime('%d-%m-%Y %H:%M:%S', localtime);
    if (Log::Log4perl::initialized()) {
	$self->log->info("Transposome::Annotation::annotate_clusters completed at: $ft.");
	$self->log->info("Results - Total sequences:                        $seqct");
	$self->log->info("Results - Total sequences clustered:              $cls_tot");
	$self->log->info("Results - Total sequences unclustered:            $single_tot");
	$self->log->info("Results - Repeat fraction from clusters:          $rep_frac");
	$self->log->info("Results - Singleton repeat fraction:              $singleton_rep_frac");
	$self->log->info("Results - Total repeat fraction:                  $total_rep_frac");
    }
    else {
	if ($self->verbose) {
	    say STDERR "Transposome::Annotation::annotate_clusters completed at: $ft.";
	    say STDERR "Results - Total sequences:                        $seqct";
	    say STDERR "Results - Total sequences clustered:              $cls_tot";
	    say STDERR "Results - Total sequences unclustered:            $single_tot";
	    say STDERR "Results - Repeat fraction from clusters:          $rep_frac";
	    say STDERR "Results - Singleton repeat fraction:              $singleton_rep_frac";
	    say STDERR "Results - Total repeat fraction:                  $total_rep_frac";
	}
    }

    return ({
	annotation_report     => $anno_rp_path, 
	annotation_summary    => $anno_sum_rep_path, 
	singletons_report     => $singles_rp_path, 
	total_sequence_num    => $total_readct, 
	repeat_fraction       => $rep_frac, 
	cluster_blast_reports => $blasts, 
	cluster_superfamilies => $superfams });

}

=head2 clusters_annotation_to_summary

 Title   : clusters_annotation_to_summary

 Usage   : $annotation->clusters_annotation_to_summary();
           
 Function: Take individual cluster annotation files and generate a grand
           summary for the whole genome which describes the repeat abundance
           classified down to the family level.

 Returns : No data returned. This is the final step in the Transposome analysis
           pipeline.

                                                                            Arg_type
 Args    : In order, 1) the cluster annotation file                         Scalar
                     2) the annotation summary file                         Scalar
                     3) the singletons annotation file                      Scalar
                     4) the total number of reads with a blast hit          Scalar
                     5) the total number of reads that went                 Scalar
                        into the clustering                                
                     6) the repeat fraction of the genome                   Scalar
                     7) the individual cluster blast reports                ArrayRef
                     8) the top superfamily hit for each cluster            ArrayRef

=cut 

method clusters_annotation_to_summary (HashRef $annotation_results) {
    my $anno_rp_path      = $annotation_results->{annotation_report};
    my $anno_sum_rep_path = $annotation_results->{annotation_summary};
    my $singles_rp_path   = $annotation_results->{singletons_report};
    my $total_readct      = $annotation_results->{total_sequence_num};
    my $rep_frac          = $annotation_results->{repeat_fraction};
    my $blasts            = $annotation_results->{cluster_blast_reports};
    my $superfams         = $annotation_results->{cluster_superfamilies};

    # log results
    my $st = POSIX::strftime('%d-%m-%Y %H:%M:%S', localtime);

    my %top_hit_superfam;
    @top_hit_superfam{keys %$_} = values %$_ for @$superfams;

    for my $f (keys %top_hit_superfam) {
	if ($f =~ /(^RL[CG][-_][a-zA-Z]+)/) {
            my $fam = $1;
            $top_hit_superfam{$fam} = $top_hit_superfam{$f};
            delete $top_hit_superfam{$f};
        }
    }

    open my $outsum, '>', $anno_sum_rep_path or die "\n[ERROR]: Could not open file: $anno_sum_rep_path\n";

    my %annot;
    my %fams;
    my $total_ct = 0;
    my $hashct   = @$blasts;
    my $hitct;
    for my $blast (@$blasts) {
        for my $fam (keys %$blast) {
            $total_ct += $blast->{$fam};
	    if ($fam =~ /(^RL[CG][-_][a-zA-Z]+)/) {
                my $famname = $1;
                if (exists $fams{$famname}) {
                    $fams{$famname} += $blast->{$fam};
                }
                else {
                    $fams{$famname} = $blast->{$fam};
                }
            }
            else {
                if (exists $fams{$fam}) {
                    $fams{$fam} += $blast->{$fam};
                }
                else {
                    $fams{$fam} = $blast->{$fam};
                }
            }
        }
    }
    my $total_gcov = 0;

    say $outsum join "\t", "ReadNum", "Superfamily", "Family", "ReadCt/ReadsWithHit", "HitPerc", "GenomeFrac";
    for my $k (reverse sort { $fams{$a} <=> $fams{$b} } keys %fams) {
        if (exists $top_hit_superfam{$k}) {
	    my $hit_perc   = sprintf("%.12f",$fams{$k}/$total_ct);
	    my $gperc_corr = $hit_perc * $rep_frac;
            $total_gcov += $gperc_corr;
	    my $fam = $k;
	    $fam =~ s/_I// if $fam =~ /_I_|_I$/;
	    $fam =~ s/_LTR// if $fam =~ /_LTR_|_LTR$/;
            say $outsum join "\t", $total_readct, $top_hit_superfam{$k}, $fam, $fams{$k}."/".$total_ct, $hit_perc, $gperc_corr;
        }
    }
    close $outsum;
    if (Log::Log4perl::initialized()) {
	$self->log->info("Results - Total repeat fraction from annotations: $total_gcov");
    }
    else {
	say STDERR "Results - Total repeat fraction from annotations: $total_gcov" if $self->verbose;
    }

    # log results
    my $ft = POSIX::strftime('%d-%m-%Y %H:%M:%S', localtime);
    if (Log::Log4perl::initialized()) {
	$self->log->info("Transposome::Annotation::clusters_annotation_to_summary started at:   $st.");
	$self->log->info("Transposome::Annotation::clusters_annotation_to_summary completed at: $ft.");
    }
    else {
	if ($self->verbose) {
	    say STDERR "Transposome::Annotation::clusters_annotation_to_summary started at:   $st.";
	    say STDERR "Transposome::Annotation::clusters_annotation_to_summary completed at: $ft.";
	}
    }
}

=head2 _annotate_singletons

 Title   : _annotation_singletons

 Usage   : This is a private method, do not use it directly.
           
 Function: Runs the annotation for singleton sequences within Transposome.

                                                                            Return_type
 Returns : In order, 1) path to the singletons annotation file,             Scalar
                     4) the repeat fraction of the singletons,              Scalar

                                                                            Arg_type
 Args    : In order, 1) singletons file generated by make_clusters()        Scalar
                        from Transposome::Cluster


=cut

method _annotate_singletons ($repeats, 
			     Str $singletons_file_path, 
			     $rpname, 
			     $single_tot,
                             $evalue, 
			     $thread_range, 
			     $db_path, 
			     $out_dir, 
			     $blastn) {

    my $top_hit_superfam = {};
    my $hit_superfam     = {};
    my $cluster_annot    = {};
    my $top_hit_cluster_annot = {};
    my @blasts;
    my @superfams;
    my @cluster_annotations;

    # set paths for annotation files
    my $singles_rep         = $rpname."_singletons_annotations.tsv";
    my $singles_rp_path     = Path::Class::File->new($out_dir, $singles_rep);
    my $singles_rep_sum     = $rpname."_singletons_annotations_summary.tsv";
    my $singles_rp_sum_path = Path::Class::File->new($out_dir, $singles_rep_sum);

    my @blastcmd = "$blastn -dust no -query $singletons_file_path -evalue $evalue -db $db_path ".
                   "-outfmt 6 -num_threads $thread_range -max_target_seqs 1 |".
                   "sort -k1,1 -u > $singles_rp_path";

    my $exit_code;
    try {
	$exit_code = system([0..5], @blastcmd);
    }
    catch {
	$self->log->error("blastn failed with exit code: $exit_code. Caught error: $_.")
	    if Log::Log4perl::initialized();
	exit(1);
    };
    
    my ($singleton_hits, $singleton_rep_frac) = (0, 0);
    my (%blasthits, @blct_out);

   if (-s $singles_rp_path) {
        open my $singles_fh, '<', $singles_rp_path or die "\n[ERROR]: Could not open file: $singles_rp_path\n";
	while (<$singles_fh>) {
	    chomp;
	    $singleton_hits++;
	    my @f = split;
	    $blasthits{$f[1]}++;
        }
	close $singles_fh;
    }

    for my $hittype (keys %blasthits) {
	push @blct_out, $blasthits{$hittype}."\t".$hittype."\n";
    }

    if ($singleton_hits > 0) {
        $singleton_rep_frac = $singleton_hits / $single_tot;
    }

    push @blasts, \%blasthits;

    ## mapping singleton blast hits to repeat types
    my ($hit_ct, $top_hit, $top_hit_perc, $blhits) = $self->_parse_blast_to_top_hit(\@blct_out, $singles_rp_sum_path);
    return unless defined $top_hit && defined $hit_ct;

    ($top_hit_superfam, $top_hit_cluster_annot) = $self->_blast_to_annotation($repeats, 'singletons', $singleton_hits, $top_hit, $top_hit_perc);

    for my $hit (keys %blasthits) {
	my $hit_perc = sprintf("%.12f", $blasthits{$hit} / $single_tot);
	($hit_superfam, $cluster_annot) = $self->_blast_to_annotation($repeats, 'singletons', $singleton_hits, \$hit, \$hit_perc);
	push @superfams, $hit_superfam unless !%$hit_superfam;
	push @cluster_annotations, $cluster_annot unless !%$cluster_annot;
    }

    push @superfams, $top_hit_superfam unless !%$top_hit_superfam;
    push @cluster_annotations, $top_hit_cluster_annot unless !%$top_hit_cluster_annot;


    return ($singleton_hits, $singleton_rep_frac, $singles_rp_path, \@blasts, 
	    \@superfams, \@cluster_annotations, $top_hit_superfam, $top_hit_cluster_annot);
}


=head2 _make_blastdb

 Title : _make_blastdb
 
 Usage   : This is a private method, do not use it directly.
           
 Function: Creates a BLAST database of the repeat types being used
           for annotation.
                                                                            Return_type
 Returns : In order, 1) the blast database                                  Scalar

                                                                            Arg_type
 Args    : In order, 1) the Fasta file of repeats being                     Scalar
                        used for annotation

=cut 

method _make_blastdb (Path::Class::File $db_fas) {
    my $makeblastdb = $self->get_makeblastdb_exec;
    my ($dbname, $dbpath, $dbsuffix) = fileparse($db_fas, qr/\.[^.]*/);

    my $db = $dbname."_blastdb";
    my $db_path = Path::Class::File->new($self->dir, $db);
    unlink $db_path if -e $db_path;

    try {
	my @makedbout = capture([0..5],"$makeblastdb -in $db_fas -dbtype nucl -title $db -out $db_path 2>&1 > /dev/null");
    }
    catch {
	if (Log::Log4perl::initialized()) {
	    $self->log->error("Unable to make blast database. Here is the exception: $_.");
	    $self->log->error("Ensure you have removed non-literal characters (i.e., "*" or "-") in your repeat database file.");
	    $self->log->error("These cause problems with BLAST+. Exiting.");
	}
	else {
	    say STDERR "Unable to make blast database. Here is the exception: $_.";
	    say STDERR "Ensure you have removed non-literal characters (i.e., "*" or "-") in your repeat database file.";
	    say STDERR "These cause problems with BLAST+. Exiting.";
	}
	exit(1);
    };

    return $db_path;
}

=head2 _parse_blast_to_top_hit

 Title   : _parse_blast_to_top_hit

 Usage   : This is a private method, do not use it directly.
           
 Function: Calculates the top blast hit for each cluster.
 
                                                                            Return_type
 Returns : In order, 1) the total hit count                                 ScalarRef
                     2) the top blast hit                                   ScalarRef
                     3) the top blast hit percentage                        ScalarRef
                     4) a hash of all the hits and their counts             HashRef

                                                                            Arg_type
 Args    : In order, 1) the blast hits for the cluster                      ArrayRef
                     2) the blast output file                               Scalar
           

=cut

method _parse_blast_to_top_hit (ArrayRef $blast_out, Path::Class::File $blast_file_path) {
    my %blhits;
    my $hit_ct = 0;

    for my $hit (@$blast_out) {
        chomp $hit;
        my ($ct, $hittype) = split /\t/, $hit;
        next unless defined $ct;
        $blhits{$hittype} = $ct;
        $hit_ct++;
    }
    
    my $sum = sum values %blhits;
    if ($hit_ct > 0) {
        open my $out, '>', $blast_file_path or die "\n[ERROR]: Could not open file: $blast_file_path\n";
        my $top_hit = (reverse sort { $blhits{$a} <=> $blhits{$b} } keys %blhits)[0];
        my $top_hit_perc = sprintf("%.2f", $blhits{$top_hit} / $sum);
        keys %blhits; #reset iterator
  
        for my $hits (reverse sort { $blhits{$a} <=> $blhits{$b} } keys %blhits) {
            my $hit_perc = sprintf("%.2f", $blhits{$hits} / $sum);
            say $out join "\t", $hits, $blhits{$hits}, $hit_perc;
        }
        close $out;
        return (\$hit_ct, \$top_hit, \$top_hit_perc, \%blhits);
    }
    else { ## if (!%blhits) {
        unlink $blast_file_path;
        return (undef, undef, undef);
    }
}

=head2 _blast_to_annotation

 Title   : _blast_to_annotation

 Usage   : This is a private method, do not use it directly.
           
 Function: This method takes the blast hits and uses a key of repeat
           types to determine the taxonomic lineage for each repeat.

                                                                            Return_type
 Returns : In order, 1) the repeat annotation for each                      HashRef
                        top hit (per cluster)
                     2) a hash containing all hits and counts per           HashRef
                        superfamily
                                                                            Arg_type
 Args    : In order, 1) a hash containing taxonomic                         HashRef
                        relationships for all repeat types
                     2) the name of the cluster file being annotated        Scalar
                     3) the total number of reads with a blast hit          Scalar
                     4) the top blast hit                                   ScalarRef
                     5) the top blast hit percentage                        ScalarRef

=cut

method _blast_to_annotation (HashRef $repeats, Str $filebase, Int $readct, ScalarRef $top_hit, ScalarRef $top_hit_perc) {
    my %top_hit_superfam;
    my %cluster_annot;

    keys %$repeats;

    for my $type (keys %$repeats) {
        if ($type eq 'pseudogene' || $type eq 'simple_repeat' || $type eq 'integrated_virus') {
            if ($type eq 'pseudogene' && $$top_hit =~ /rrna|trna|snrna/i) {
                my $anno_key = $self->mk_key($filebase, $type, $$top_hit, $$top_hit_perc);
                $cluster_annot{$readct} = $anno_key;
                last;
            }
            elsif ($type eq 'simple_repeat' && $$top_hit =~ /msat/i) {
                my $anno_key = $self->mk_key($filebase, $type, "Satellite", "MSAT", $$top_hit, $$top_hit_perc);
                $cluster_annot{$readct} = $anno_key;
                last;
            }
            elsif ($type eq 'simple_repeat' && $$top_hit =~ /sat/i) {
                my $anno_key = $self->mk_key($filebase, $type, "Satellite", "SAT", $$top_hit, $$top_hit_perc);
                $cluster_annot{$readct} = $anno_key;
                last;
            }
            elsif ($type eq 'integrated_virus' && $$top_hit =~ /caul/i) {
                my $anno_key = $self->mk_key($filebase, $type, "Caulimoviridae", $$top_hit, $$top_hit_perc);
                $cluster_annot{$readct} = $anno_key;
                last;
            }
            elsif ($type eq 'integrated_virus' && ($$top_hit eq 'PIVE' || $$top_hit eq 'DENSOV_HM')) {
                my $anno_key = $self->mk_key($filebase, $type, "DNA Virus", $$top_hit, $$top_hit_perc);
                $cluster_annot{$readct} = $anno_key;
                last;
            }
            elsif ($type eq 'endogenous_retrovirus' && ($$top_hit =~ /erv/i || $$top_hit =~ /^RLE/i)) {
		$$top_hit =~ s/_I// if $$top_hit =~ /_I_|_I$/;
		$$top_hit =~ s/_LTR// if $$top_hit =~ /_LTR_|_LTR$$/;
                my $anno_key = $self->mk_key($filebase, $type, "Endogenous Retrovirus", $$top_hit, $$top_hit_perc);
                $cluster_annot{$readct} = $anno_key;
                last;
            }
            next;
        }
        for my $class (keys %{$repeats->{$type}}) {
	    for my $superfam (@{$repeats->{$type}{$class}}) {
		my $superfam_index = first_index { $_ eq $superfam } @{$repeats->{$type}{$class}};
                for my $superfam_h (keys %$superfam) {
                    if ($superfam_h =~ /sine/i) {
			for my $sine_fam_h (@{$superfam->{$superfam_h}}) {
			    my $sine_fam_index = first_index { $_ eq $sine_fam_h } @{$superfam->{$superfam_h}};
                            for my $sine_fam_mem (keys %$sine_fam_h) {
                                for my $sines (@{$repeats->{$type}{$class}[$superfam_index]{$superfam_h}[$sine_fam_index]{$sine_fam_mem}}) {
                                    for my $sine (@$sines) {
                                        if ($sine =~ /$$top_hit/) {
                                            ## only include the same level of depth as others
				            $top_hit_superfam{$$top_hit} = $sine_fam_mem;
                                            my $anno_key = $self->mk_key($filebase, $type, $class, $superfam_h, 
									 $sine_fam_mem, $$top_hit, $$top_hit_perc);
                                            $cluster_annot{$readct} = $anno_key;
                                            last;
                                        }
                                    }
                                }
                            }
                        }
                    }
		    elsif ($superfam_h =~ /gypsy/i) {# && $$top_hit =~ /^RLG|Gyp/i) {
                        my $gypsy_fam = $$top_hit; 
			if ($gypsy_fam =~ /^RLG|Gyp/i) {
			    if ($gypsy_fam =~ /(^RLG[_-][a-zA-Z]+)/) {
				$gypsy_fam = $1;
			    }
			    $gypsy_fam =~ s/_I// if $gypsy_fam =~ /_I_|_I$/;
			    $gypsy_fam =~ s/_LTR// if $gypsy_fam =~ /_LTR_|_LTR$/;
			    $top_hit_superfam{$$top_hit} = $superfam_h;
			    my $anno_key = $self->mk_key($filebase, $type, $class, $superfam_h, $gypsy_fam, $$top_hit, $$top_hit_perc);
			    $cluster_annot{$readct} = $anno_key;
			}
                        last;
                    }
                    elsif ($superfam_h =~ /copia/i) { # && $$top_hit =~ /^RLC|Cop/i) {
                        my $copia_fam = $$top_hit;
			if ($copia_fam =~ /^RLC|Cop/i) {
			    if ($copia_fam =~ /(^RLC[_-][a-zA-Z]+)/) {
				$copia_fam = $1;
			    }
			    $copia_fam =~ s/_I// if $copia_fam =~ /_I_|_I$/;                                               
			    $copia_fam =~ s/_LTR// if $copia_fam =~ /_LTR_|_LTR$/;
			    $top_hit_superfam{$$top_hit} = $superfam_h;
			    my $anno_key = $self->mk_key($filebase, $type, $class, $superfam_h, $copia_fam, $$top_hit, $$top_hit_perc);
			    $cluster_annot{$readct} = $anno_key;
			}
                        last;
                    }
		    elsif ($superfam_h =~ /bel|pao/i && $$top_hit =~ /^RLB|BEL/i) {
                        my $bel_fam = $$top_hit;
                        if ($bel_fam =~ /(^RLC[_|-][a-zA-Z]+)/) {
                            $bel_fam = $1;
                        }
                        $bel_fam =~ s/_I// if $bel_fam =~ /_I_|_I$/;
                        $bel_fam =~ s/_LTR// if $bel_fam =~ /_LTR_|_LTR$/;
                        $top_hit_superfam{$$top_hit} = $superfam_h;
                        my $anno_key = $self->mk_key($filebase, $type, $class, $superfam_h, $bel_fam, $$top_hit, $$top_hit_perc);
                        $cluster_annot{$readct} = $anno_key;
                        last;
                    }
                    else {
                        for my $fam (@{$repeats->{$type}{$class}[$superfam_index]{$superfam_h}}) {
                            for my $mem (@$fam) {
                                if ($mem =~ /$$top_hit/i) {
			            $$top_hit =~ s/_I_// if $$top_hit =~ /_I_/;
			            $$top_hit =~ s/_LTR_// if $$top_hit =~ /_LTR_/;
				    $$top_hit =~ s/_I// if $$top_hit =~ /_I$/;
                                    $$top_hit =~ s/_LTR// if $$top_hit =~ /LTR$/;
                                    $top_hit_superfam{$$top_hit} = $superfam_h;
				    my $unk_fam = q{ };
                                    my $anno_key = $self->mk_key($filebase, $type, $class, $superfam_h, $unk_fam, $$top_hit, $$top_hit_perc);
                                    $cluster_annot{$readct} = $anno_key;
                                    last;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    return (\%top_hit_superfam, \%cluster_annot);
}

=head1 AUTHOR

S. Evan Staton, C<< <statonse at gmail.com> >>

=head1 BUGS

Please report any bugs or feature requests through the project site at 
L<https://github.com/sestaton/Transposome/issues>. I will be notified,
and there will be a record of the issue. Alternatively, I can also be 
reached at the email address listed above to resolve any questions.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Transposome::Annotation


=head1 LICENSE AND COPYRIGHT

Copyright (C) 2013-2015 S. Evan Staton

This program is distributed under the MIT (X11) License, which should be distributed with the package. 
If not, it can be found here: L<http://www.opensource.org/licenses/mit-license.php>

=cut

__PACKAGE__->meta->make_immutable;

1;
