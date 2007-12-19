use strict;
use warnings;

use Test::More tests => 5;
use IO::EventMux;
use IO::Socket::INET;
use IO::Select;
use Socket;

my $mux = IO::EventMux->new();

my $udpc = IO::Socket::INET->new(
    PeerAddr => "127.0.0.1",
    PeerPort => 11046,
    Proto    => 'udp',
    Blocking => 0,
) or die "Could not open socket on (127.0.0.1:11046): $!\n";
$mux->add($udpc);
is($mux->type($udpc), 'dgram', "UDP(Connected) connect: Type was detected as dgram");

my $udpl = IO::Socket::INET->new(
    LocalAddr => "127.0.0.1",
    LocalPort => 11046,
    Proto    => 'udp',
    Blocking => 0,
) or die "Could not open socket on (127.0.0.1:11046): $!\n";
$mux->add($udpl);
is($mux->type($udpl), 'dgram', "UDP(Connected) listeing: Type was detected as dgram");

my $udpnc = IO::Socket::INET->new(
    ReuseAddr    => 1,    
    Proto        => 'udp',
    Blocking     => 0,
) or die "Could not open non connected udp socket: $!\n";
$mux->add($udpnc);
is($mux->type($udpnc), 'dgram', "UDP(non connected): Type was detected as stream");

my $tcpl = IO::Socket::INET->new(
    LocalPort    => 11045,
    LocalAddr    => "127.0.0.1",
    ReuseAddr    => 1,    
    Proto        => 'tcp',
    Blocking     => 0,
) or die "Could not open socket on (127.0.0.1:10046): $!\n";
$mux->add($tcpl);
is($mux->type($tcpl), 'stream', "TCP listening: Type was detected as stream");

my $tcpc = IO::Socket::INET->new(
    PeerPort    => 11045,
    PeerAddr    => "127.0.0.1",
    ReuseAddr    => 1,    
    Proto        => 'tcp',
    Blocking     => 0,
) or die "Could not open socket on (127.0.0.1:10046): $!\n";
$mux->add($tcpc);
is($mux->type($tcpc), 'stream', "TCP connecting: Type was detected as stream");

