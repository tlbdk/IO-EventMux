use strict;
use warnings;

use Test::More tests => 2;
use IO::EventMux;
use Data::Dumper;

my $mux = IO::EventMux->new();

sub string_fh {
    my $pid = open my $infh, "-|";
    die if not defined $pid;

    if ($pid == 0) {
        print @_;
        exit;
    }
    return $infh;
}

# Handle WSDL request
my $data = "GET /soap.php?WSDL HTTP/1.0\x0d\x0a".
           "Host: localhost\x0d\x0a\x0d\x0a";

my $goodfh = string_fh($data);
$mux->add($goodfh, Buffered => ['HTTP']);

my %types;
while ($mux->handles > 0) {
    my $event = $mux->mux();
    $types{$event->{fh}}{types} .= $event->{type};

    if($event->{type} eq 'read') {
        $types{$event->{fh}}{data} .= $event->{data};
    } 
}

is($types{$goodfh}{types}, join("", qw(read closing closed)),
    "Type came back in the right order");

is($types{$goodfh}{data}, $data, "Data was correct");

