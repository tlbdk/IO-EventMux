#!/usr/bin/env perl
use strict;
use warnings;

# This example program shows how to wait for a child process and listen to it's
# STDERR, STDOUT and send data to it's STDIN using EventMux. It waits for the 
# child to close its stdout, which for most programs is evidence that it is 
# terminating. Then it calls waitpid to collect the child's exit status and 
# prevent it from becoming a zombie. This call to waitpid is blocking in
# theory, but it will happen instantly for well-behaved children.

use lib "lib";
use IO::EventMux;

my $mux = IO::EventMux->new;

pipe my $readerOUT, my $writerOUT or die;
pipe my $readerERR, my $writerERR or die;
pipe my $readerIN, my $writerIN or die;

my $pid = fork;
if ($pid == 0) {
    close $readerOUT or die;
    close $readerERR or die;
    close $writerIN or die;
    open STDOUT, ">&", $writerOUT or die;
    open STDERR, ">&", $writerERR or die;
    open STDIN, ">&", $readerIN or die;
    exec "tftp";
    die;
}

close $writerOUT;
close $writerERR;
close $readerIN;
$mux->add($readerOUT, Buffered => ["Split", qr/\n/]);
$mux->add($readerERR, Buffered => ["Split", qr/\n/]);
$mux->add($writerIN, Buffered => ["Split", qr/\n/]);

print "OUT($readerOUT)\n";
print "ERR($readerERR)\n";
print "IN($writerIN)\n";


while (my $event = $mux->mux) {
    print "Got event: $event->{type} : $event->{fh} \n";
    print "OUT:$event->{data}\n" if $event->{type} eq 'read';
    
    if($event->{type} eq 'ready') {
        $mux->send($event->{fh}, "quit\n");
    }

    if($event->{error}) {
        sleep 100;
        exit;
    }
}

# vim: et tw=79 sw=4 sts=4
