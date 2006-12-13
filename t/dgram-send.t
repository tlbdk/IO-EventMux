#!/usr/bin/perl -I lib
use strict;
use warnings;

use Test::More tests => 1;
use IO::EventMux;
use Socket;

# This test how we deal file handles that say they can be written to but
# return POSIX::EWOULDBLOCK making EventMux hang trying to get an event
# forever.

my $mux = IO::EventMux->new();

foreach my $i (1..339) {
    my $fh = IO::Socket::INET->new(
        Proto    => 'udp',
        Type     => SOCK_DGRAM,
        Blocking => 0,
    ) or die "Could not open socket on 127.0.0.1: $!\n";
    
    $mux->add($fh, Type => "dgram");
    
    my $transaction_id = 1;
    my $flags = 0; 
    my $questions = 1;
    my $answer_rrs = 0;
    my $authority_rrs = 0;
    my $additional_rrs = 0;
    my $name = "\x20\x43\x4b".("\x41"x 30)."\x00";
    my $type = 0x21;
    my $class = 0x01;

    my $packet = pack("nnnnnna34nn", 
            $transaction_id, $flags,
            $questions,
            $answer_rrs,$authority_rrs,$additional_rrs,
            $name, $type, $class);
 
    my $addr = pack_sockaddr_in(137, inet_aton("127.0.0.1"));
    $mux->sendto($fh, $addr, $packet);
}

while(1) {
    my $event = $mux->mux(0); # FIXME: We hang here after some reads return.
    print "$event->{type}\n";
}