use strict;
use warnings;

use Test::More tests => 7;                      # last test to print
use IO::Socket::INET;
use Socket;

my $type;

my $icmp = IO::Socket::INET->new(
    Proto => 'ICMP',
    Type => SOCK_RAW,
);

if(defined $icmp) {
    $type = getsockopt($icmp, SOL_SOCKET, SO_TYPE);
    ok(unpack("I", $type) == SOCK_RAW, "filehandle from icmp returns SOCK_RAW");

} else {
    pass("Could not test with ICMP");
}

my $udp = IO::Socket::INET->new(
    Proto    => 'udp',
    Blocking => 0,
) or die("\n");
$type = getsockopt($udp, SOL_SOCKET, SO_TYPE);
ok(unpack("I", $type) == SOCK_DGRAM, "filehandle from udp returns SOCK_DGRAM");

my $tcp = IO::Socket::INET->new(
    Proto    => 'tcp',
    PeerAddr => '127.0.0.1',
    PeerPort => '12345',
    Blocking => 0,
) or die;
$type = getsockopt($tcp,SOL_SOCKET, SO_TYPE) or die;
ok(unpack("I", $type) == SOCK_STREAM, "filehandle from tcp returns SOCK_STREAM");

open my $cmd, "echo 1|" or die;
$type = getsockopt($cmd, SOL_SOCKET, SO_TYPE);
close $cmd;
ok(!defined $type, "filehandle from open returns undef with SO_TYPE");

$type = getsockopt(STDIN, SOL_SOCKET, SO_TYPE);
ok(!defined $type, "filehandle from STDIN returns undef with SO_TYPE");

$type = getsockopt(STDOUT, SOL_SOCKET, SO_TYPE);
ok(!defined $type, "filehandle from STDOUT returns undef with SO_TYPE");

$type = getsockopt(STDERR, SOL_SOCKET, SO_TYPE);
ok(!defined $type, "filehandle from STDERR returns undef with SO_TYPE");

