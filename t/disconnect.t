use strict;
use warnings;

# This tests how we handle a premature disconnect where a socket is 
# disconnected before we have called mux on it.
#
# It also looks at the order of the events pr. file handle so we are sure 
# EventMux returns them in the correct order:
#
# 1. connect or connected: Is the first event depending if it's from a 
#    accept call(ie. a child of a listening socket) or a connecting socket.
# 2. read, canread: is optional and might not happen as the other end can quit
#    before sending any data.
# 3. disconnect: Happens when using delayed disconnect, all disconnects EventMux 
#    detects is delayed. The user has to call disconnect($fh, 1); to get this 
#    event.
# 4. disconnected: Is the last event a file handle can generate.
#
#
#
#
my $WITHOLD = 0;

use Test::More tests => 2;
use IO::EventMux;

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
$mux->close($talker);

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

    if($type eq 'ready') {
        $clients++;
    
    } elsif($type eq 'accepted') {
        $clients++;
        $timeout = 1;
    
    } elsif($type eq 'closing') {

    } elsif($type eq 'closed') {
        if(--$clients == 0 and $timeout > 0) { last }
        ok($event->{missing} == 0, "Missing is 0 as it should be")

    } elsif($type eq 'read') {

    } elsif($type eq 'read_last') {
    
    } elsif($type eq 'sent' and $fh eq $talker) {

    } elsif($type eq 'timeout') {
    
    } else {
        die("Unhandled event $type");
    }
}

is_deeply(\@eventorder, 
    [qw(ready accepted sent closing closed read read read_last 
    closing closed)], "Event order is correct");
