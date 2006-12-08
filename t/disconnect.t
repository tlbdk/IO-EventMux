#!/usr/bin/perl -w
use strict;
use warnings;

my $WITHOLD = 0;

use Test::More tests => 1;
use IO::EventMux;
use IO::EventMuxOld;

my $PORT = 7007;

my $mux = ($WITHOLD ?
    (IO::EventMuxOld->new(LineBuffered => 1))
    : (IO::EventMux->new())
);

# Test Listning TCP sockets
my $listener = IO::Socket::INET->new(
    Listen    => 5,
    LocalPort => $PORT,
    ReuseAddr => 1,
    Blocking => 0,
) or die "Listening on port $PORT: $!\n";

print "listener:$listener\n";
$mux->add_listener($listener) if $WITHOLD;
$mux->add($listener, Listen => 1, Buffered => ["Regexp", qr/(.*)\n/]) if !$WITHOLD;

my $talker = IO::Socket::INET->new(
    Proto    => 'tcp',
    PeerAddr => '127.0.0.1',
    PeerPort => $PORT,
    Blocking => 1,
) or die "Connecting to 127.0.0.1:$PORT: $!\n";
print "talker:$talker\n";
$mux->add($talker);
$mux->send($talker, ("data 1\n", "data 2\n", "data 3"));
$mux->disconnect($talker);

my $timeout = 0;
my $clients = 0;
my @eventorder;
while(1) {
    my $event = $mux->mux($timeout);
    my $type  = $event->{type};
    my $fh    = ($event->{fh} or '');
    my $data  = ($event->{data} or '');

    print("$fh $type: '$data'\n");
    push(@eventorder, $type);

    if($type eq 'connected') {
        $clients++;
    
    } elsif($type eq 'connect') {
        $clients++;
        $timeout = 1;
    
    } elsif($type eq 'disconnect') {

    } elsif($type eq 'disconnected') {
        if(--$clients == 0 and $timeout > 0) { last }

    } elsif($type eq 'read') {

    } elsif($type eq 'read_last') {

    } elsif($type eq 'timeout') {
    
    } else {
        die("Unhandled event $type");
    }
}

is_deeply(\@eventorder, 
    [qw(connected disconnected connect read read read_last 
    disconnect disconnected)], "Event order is correct");
