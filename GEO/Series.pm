package GEO::Series;
use Moose;
extends 'GEO';
use MooseX::ClassAttribute;

use Data::Dumper;
use PhonyBone::FileUtilities qw(warnf dief);
use PhonyBone::ListUtilities qw(subtract union unique);
use Cwd;

has 'author'      => (is=>'rw');
has 'date'        => (is=>'rw');
has 'organism'    => (is=>'rw');
has 'series_type' => (is=>'rw');
has 'status'      => (is=>'rw');
has 'isb_status'  => (is=>'rw');
has 'error'       => (is=>'rw');
has 'title'       => (is=>'rw');
has 'dataset_ids' => (is=>'rw');
has 'sample_ids'  => (is=>'rw');
has 'summary'     => (is=>'rw');
#has '_rs_iter'      => (is=>'rw');

class_has 'prefix'    => (is=>'ro', isa=>'Str', default=>'GSE' );
class_has 'ftp_base'  => (is=>'ro', isa=>'Str', default=>'pub/geo/DATA/supplementary/series');
class_has 'ftp_soft'  => (is=>'ro', isa=>'Str', default=>'pub/geo/DATA/SOFT/by_series');
class_has 'collection_name'=> (is=>'ro', isa=>'Str', default=>'series');
class_has 'subdir'    => (is=>'ro', isa=>'Str', default=>'series');
class_has 'word_fields' => (is=>'ro', isa=>'ArrayRef', default=>sub {[qw(title summary)]});

sub samples {
    my ($self)=@_;
    my @samples;
    push @samples, map {$self->factory($_)} @{$self->sample_ids} if $self->sample_ids;
    wantarray? @samples:\@samples;
}

########################################################################

# return the path to the series's directory:
sub path {
    my ($self)=@_;
    return join('/', $self->data_dir, $self->subdir, $self->geo_id);
}

# This looks in the series's directory for filenames matching /GSM\d+/
# returns a list[ref] of sample filenames
sub samples_in_dir {
    my ($self)=@_;

    my $dir=$self->path;
    opendir (DIR, $dir) or die "Can't open '$dir': $!\n";
    my @samples= grep /GSM\d+/, readdir DIR;
    closedir DIR;

    @samples=unique(@samples);	# need unique here because sometimes there are both .CEL and .CHP files with same name, eg.
    wantarray? @samples:\@samples;
}

sub sample_ids_in_dir {
    my ($self)=@_;
    my @sample_ids=map {/GSM\d+/; $&} $self->samples_in_dir;
    @sample_ids=unique(@sample_ids);
    wantarray? @sample_ids:\@sample_ids;
}

# get a listing of all GSE's present in the series data dir:
sub series_dirs {
    my ($self)=@_;
    my $dir=File::Spec->catfile($self->data_dir, $self->subdir);
    opendir(DIR, $dir) or die "Can't open series dir '$dir': $!\n";
    my @subdirs=grep /^GSE\d+/, readdir DIR;
    closedir DIR;
    wantarray? @subdirs:\@subdirs;
}


# generator that returns the next sample for the series
sub next_sample {
    my ($self)=@_;
    my $iter=$self->_rs_iter or do {
	$self->_rs_iter(new GEO::RawSample::Iterator($self));
    };
    my $next=$iter->next;
    unless (defined $next) {
	undef $iter;
	$self->_rs_iter(undef);
    }
    $next;
}

########################################################################

sub tar_file { sprintf "%s_RAW.tar", shift->geo_id }
sub tar_path { 
    my ($self)=@_;
    join('/', $self->data_dir, $self->subdir, $self->geo_id, $self->tar_file);
}

sub soft_file { sprintf "%s_family.soft", shift->geo_id }
sub soft_path { 
    my ($self)=@_;
    join('/', $self->data_dir, $self->subdir, $self->geo_id, $self->soft_file);
}
    


# Download the series .tar file; return nothing, but throw exceptions on error.
# downloads to current directory
# throws exceptions on errors, or returns undef
sub _fetch_tar_file {
    my ($self)=@_;
    my $ftp=$self->_get_ftp();

    # create dst dir if necessary
    unless (-d $self->path) {
	mkdir $self->path or dief "Unable to mkdir '%s': $!\n", $self->path;
	warnf "mkdir %s\n", $self->path if $ENV{DEBUG};;
    }
    my $curr_dir=getcwd;
    chdir $self->path or dief "Can't chdir to %s: %s", $self->path, $!;

    eval {
	# Cd to correct point on server:
	my $full_base_dir=join('/', $self->ftp_base, $self->geo_id);
	foreach my $subdir (split(/\//, $full_base_dir)) {
	    $ftp->cwd($subdir) or 
		die "Can't ftp cd to $subdir in '$full_base_dir': ", $ftp->message;
	}
	
	# Download the .tar file:
	my $target=$self->tar_file;
	warn "fetching $target...\n" if $ENV{DEBUG};;
	$ftp->binary;
	$ftp->get("$target") or die "Can't get $target: ",$ftp->message;
    };
    my $err=$@;
    chdir $curr_dir;
    $ftp->quit;

    die $err if $err;
    undef;
}


# Unpack the series .tar file
# unlinks tar file unless $options{keep_tars} set
# assumes the tar_file is in the current directory
# dies on errors
# returns listref of sample ids (you got a better idea?)
sub _unpack_tar {
    my ($self)=@_;
    warnf("  unpacking %s\n", $self->tar_file) if $ENV{DEBUG};

    my $dst_tar=$self->tar_file;
    my $rc=`tar xfv $dst_tar`;
    die "error unpacking $dst_tar: $rc" if $?!=0;

    # make an entry in $record for each sample file
    my @sample_files=grep /gz$/, split(/\n/, $rc);
    my $sample_ids=[];
    foreach my $file (@sample_files) {
	# insert a record in to the raw_samples db:
	if ($file=~/GSM\d+/) {
	    my $sample_id=$&;
	    push @$sample_ids, $sample_id;
	}
    }
    $self->sample_ids($sample_ids);
    
}

sub fetch_soft {
    my ($self)=@_;
    my $ftp=$self->_get_ftp;
    
    # Cd to correct point on server:
    my $target=join('.',$self->soft_file,'gz');
    my $full_base_dir=join('/', $self->ftp_soft, $self->geo_id);
    warnf("fetching %s/%s...\n", $full_base_dir, $target) if $ENV{DEBUG};

    my $curr_dir=getcwd;
    mkdir $self->path unless -d $self->path;
    chdir $self->path or dief "Can't chdir to %s: %s", $self->path, $!;
    
    eval {
	foreach my $subdir (split(/\//, $full_base_dir)) {
	    $ftp->cwd($subdir) or 
		die "Can't ftp cd to $subdir in '$full_base_dir': ", $ftp->message;
	}

	# Download the .tar file:
	warn "fetching $target...\n" if $ENV{DEBUG};;
	$ftp->binary;
	$ftp->get("$target") or die "Can't get $target: ",$ftp->message;
    };
    my $err=$@;
    chdir $curr_dir;
    $ftp->quit;
    die $err if $err;
    undef;
    
    
}

########################################################################

sub report {
    my ($self, %argHash)=@_;
    my $title=$self->title || '<no title>';
    my $organism=$self->organism || '<no organism>';
    my $sample_ids=$self->sample_ids || ['<no sample_ids>'];
    my $n_samples=$sample_ids->[0] eq '<no sample_ids>'? 0 : scalar @$sample_ids;
    my $status=$self->status || '<status unknown>';
    my $report=sprintf("%s Title: %s (%s, %s, %d samples)\n", $self->geo_id, $title, $status, $organism, $n_samples);
    if (defined $self->isb_status && $self->isb_status=~/^error/i) {
	$report.=sprintf("%17s: %s\n", 'error msg', $self->error);
    } else {
	$report.=sprintf("      isb_status: %s\n", ($self->isb_status || '<unknown>'));
    }

    if (defined $self->dataset_ids) {
	foreach my $gds (@{$self->dataset_ids}) {
	    my $ds=GEO::Dataset->new($gds);
	    $report.=sprintf("   dataset %s: %s \n    - %s\n\n", $gds, $ds->title, $ds->description);
	}
    } else {
	$report.="   no datasets\n";
    }

    if ($argHash{full}) {
	$report.=join("\n", map {$_->report} @{$self->samples});
    }

    $report;
}

# return a hash[ref] reporting on integrity status
sub error_report {
    my ($self)=@_;
    my $errors={};

    # samples: record matches filesystem?
    my $db_samples=[sort @{$self->sample_ids}];
    my $fs_samples=[sort map {/GSM\d+/; $&} $self->samples_in_dir]; # extract GSM ids out of filenames

    $errors->{fs_only}=subtract($fs_samples, $db_samples);
    $errors->{db_only}=subtract($db_samples, $fs_samples);
    $errors->{db_matches_fs} = scalar @{$errors->{fs_only}} == 0 &&
	scalar @{$errors->{db_only}} == 0? 'yes' : 'no';
    
    # do all of the samples have records in the db?
    my $sample_ids=union($db_samples, $fs_samples);
    foreach my $s_id (@$sample_ids) {
	push @{$errors->{missing_records}}, $s_id 
	    unless GEO->get_mongo_record($s_id, 'GEO::RawSample') || GEO->get_mongo_record($s_id, 'GEO::SeriesData');
    }

    # check for empty directory:
    local *DIR;
    opendir DIR, $self->path or dief "Can't open %s: $!\n";
    my @files=grep /[^.]/, readdir DIR;
    closedir DIR;
    $errors->{empty}=@files==0;

    wantarray? %$errors:$errors;
}

########################################################################
# return a hash[ref] where the keys are the GSEs we want to process
# generally called as a class method
# obtain list from:
#   $options{filter_gses} (can either be command-line list of file containing gses)
#   $options{filter_gses} eq 'use_datasets' (use GSEs stored in GDS (datasets) db
# k=$GSE, v=1
# returns a hash[ref], and not a list, so that removals from list are O(1)
sub get_filter {
    my ($self, $filter_option)=@_; 
    $filter_option||='';
    my %filter;
    if (-r $filter_option) {	# if -filter_gses provides filename
	my @gses=map {/GSE\d+/; $&} file_lines($filter_option);
	do {$filter{$_}=1} for @gses;

    } elsif ($filter_option eq 'use_datasets') {
	my @records=GEO::Dataset->get_mongo_records({}, {_id=>0, reference_series=>1});
	foreach my $r (@records) { $filter{$r->{reference_series}}=1; }
	
    } else {		# assume -filter_gses provides a list of gses
	do {$filter{$_}=1} for split(/,/, $filter_option);
    }
    warnf("%d gses in filter\n", scalar keys %filter) if $ENV{DEBUG};
    wantarray? %filter:\%filter;
}

########################################################################

1;
