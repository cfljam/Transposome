package SeqIO_n;

use 5.012;
use Moose;
use namespace::autoclean;

with 'File';

# class attributes
has id => (
    is        => 'rw',
    isa       => 'Str',
    reader    => 'get_id',
    writer    => 'set_id',
    #clearer   => 'clear_id',
    predicate => 'has_id',
    );

has seq => (
    is        => 'rw',
    isa       => 'Str',
    reader    => 'get_seq',
    writer    => 'set_seq',
    #clearer   => 'clear_seq',
    predicate => 'has_seq',
    );

#has comment => (
#    is        => 'rw',
#    isa       => 'Str',
#    reader    => 'get_comment',
#    writer    => 'set_comment',
#    #clearer   => 'clear_comment',
#    predicate => 'has_comment',
#    );

has qual => (
    is        => 'rw',
    lazy      => 1,
    default   => undef,
    reader    => 'get_qual',
    writer    => 'set_qual',
    #clearer   => 'clear_qual',
    predicate => 'has_qual',
    );

# class methods
sub next_seq {
    my $self = shift;
    my $fh = shift;

    my ($name, $seq, $qual, @aux);
    my $hline = <$fh>;
    return unless defined $hline;
    chomp $hline;
    die "\nERROR: $hline does not look like Fasta or Fastq. Exiting.\n" 
	unless (substr($hline, 0, 1) eq '>' || substr($hline, 0, 1) eq '@');
    if (substr($hline, 0, 1) eq '>') {
	my $name = _set_id_per_encoding($hline);
	$self->set_id($name);

	my $sline = <$fh>;
	return unless defined $sline;
	chomp $sline;
	die "\nERROR: No sequence for Fasta record $name. Exiting.\n" if !length($sline);
	$seq .= $sline;
        $self->set_seq($seq);

	return $self;
    }
    elsif (substr($hline, 0, 1) eq '@') {
	my $name = _set_id_per_encoding($hline);
	$self->set_id($name);

        my $sline = <$fh>;
        return unless defined $sline;
        chomp $sline;
	die "\nERROR: No sequence for Fastq record $name. Exiting.\n" if !length($sline);
	$seq .= $sline;
        $self->set_seq($seq);

	my $cline = <$fh>;
	return unless defined $cline;
	chomp $cline;
	die "\nERROR: No comment line for Fastq record $name. Exiting.\n" 
	    unless length($cline) && substr($cline, 0, 1) eq '+';
	# silly to actually set this, can just print the name if that is needed. 
	#if (length($cline) > 1) {
	#    die "\nERROR: Comment line and record identifier are different lengths for $name. Exiting.\n" 
	#	unless length($name) == length($cline)-1;
	#    $self->set_comment($name);
	#}

	my $qline = <$fh>;
	return unless defined $qline;
	chomp $qline;
	die "\nERROR: No quality scores for $name\n" if !length($qline);
	$qual .= $qline;
	if (length($qual) >= length($seq)) {
	    $self->set_qual($qual);
	    return $self;
	}
	else {
	    die "\nERROR: Unequal number of quality and scores and bases for $name";
	}
    }
}

sub _set_id_per_encoding {
    my $hline = shift;
    if ($hline =~ /^.?(\S+)\s(\d)\S+/) {
	return $1."/".$2;
    }
    elsif ($hline =~ /^.?(\S+)/) {
	return $1;
    }
    else {
	return '';
    }
}
    __PACKAGE__->meta->make_immutable;

1;
