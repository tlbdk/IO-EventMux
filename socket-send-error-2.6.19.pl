#!/usr/bin/perl -I lib
use strict;
use warnings;

use Test::More tests => 1;
use IO::Socket::INET;
use IO::Select;
use Socket;

my $s = IO::Select->new();

foreach my $i (1..1000) {
    my $fh = IO::Socket::INET->new(
        Proto    => 'udp',
        Type     => SOCK_DGRAM,
        Blocking => 1,
    ) or die "Could not open socket on 127.0.0.1: $!\n";

    $s->add($fh);
    my $addr = pack_sockaddr_in(1000, inet_aton("127.0.0.1"));
    my $rv = $fh->send("", 0, $addr);
    if(!defined $rv) {
        print "$i\n";
    }
}
#my @arr = $s->can_write();
#select(undef, undef, undef, 1.0);
#sleep 5;
print "done\n";
sleep 1000;
