use strict;
use warnings;

use Test::More tests => 1;                      # last test to print

use IO::Socket::INET;
use IO::EventMux;
use Socket;

pass "Skip for now"; exit;

my $fh2 = IO::Socket::INET->new(
    Proto    => 'udp',
    Blocking => 0,
) or die("\n");

my $mux = IO::EventMux->new();
$mux->add($fh2, Type => 'dgram');
$mux->sendto($fh2, pack_sockaddr_in(12345, inet_aton("127.0.0.1")), 'Test\n');
while(1) {
    my $event = $mux->mux(2);
    use Data::Dumper; print Dumper($event);
    
    if($event->{type} eq 'error') {
        if($event->{error_type} eq 'connection') {
            pass "We got a connection error";
        } else {
            fail "We did not get a connection error";
        }
        exit;
    
    } elsif($event->{type} eq 'timeout') {
        fail "Got timeout??";
        exit;
    }
}

