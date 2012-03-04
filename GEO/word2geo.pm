package GEO::word2geo;
use Moose;
extends 'Mongoid';
use MooseX::ClassAttribute;
use Data::Dumper;

has 'geo_id' => (is=>'rw', isa=>'Str');
has 'word' => (is=>'rw', isa=>'Str');
has 'source' => (is=>'rw', isa=>'Str');

class_has 'db_name'         => (is=>'ro', isa=>'Str', default=>'geo');
class_has 'collection_name' => (is=>'ro', isa=>'Str', default=>'word2geo');
class_has 'indexes' => (is=>'rw', isa=>'ArrayRef', default=>sub { [{geo_id=>1, word=>1},{unique=>1}] });


sub equals {
    my ($self, $other)=@_;
    $self->geo_id eq $other->geo_id && $self->word eq $other->word;
}

sub as_string {
    my ($self)=@_;
    sprintf("%s:%s", $self->{word}, $self->{geo_id});
}



1;

