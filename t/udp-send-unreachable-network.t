use strict;
use warnings;

use Test::More tests => 2;

use IO::EventMux;
use Socket;

my $mux = IO::EventMux->new();

my $udpnc = IO::Socket::INET->new(
    ReuseAddr    => 1,    
    Proto        => 'udp',
    Blocking     => 0,
) or die "Could not open non connected udp socket: $!\n";
$mux->add($udpnc);

my $receiver = pack_sockaddr_in(161, inet_aton("255.255.255.255")); 
$mux->sendto($udpnc, $receiver, "hello");

my $event = $mux->mux();

pass("We don't not die so we handle network is unreachable on UDP");

is_deeply($event, 
    { receiver => $receiver, 
        fh => $udpnc, 
        error => "Network is unreachable",
        type => 'error',
    },
"We get a correct event back");
