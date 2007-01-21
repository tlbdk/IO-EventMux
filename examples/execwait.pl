#!/usr/bin/perl -w
use strict;

# This example program shows how to wait for a child process and listen to it's
# STDERR, STDOUT and send data to it's STDIN using EventMux. It waits for the 
# child to close its stdout, which for most programs is evidence that it is 
# terminating. Then it calls waitpid to collect the child's exit status and 
# prevent it from becoming a zombie. This call to waitpid is blocking in
# theory, but it will happen instantly for well-behaved children.

use FindBin qw($Bin);
use lib "$Bin/../../trunk/backend";
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
    exec "sh", "-c", q(strace -e trace=write cat && sleep 1);
    die;
}

close $writerOUT;
close $writerERR;
close $readerIN;
$mux->add($readerOUT, LineBuffered => 1);
$mux->add($readerERR, LineBuffered => 1);
$mux->add($writerIN, LineBuffered => 0);

my $dataIN = "hello\n" x 1;
my $dataOUT = '';
my $dataERR = '';

my $closed = 0;
while (my $event = $mux->mux) {
    print "Got event: $event->{type}\n";

    if ($event->{type} eq "connected" and ($event->{fh} == $writerIN)) {
        $mux->send($event->{fh}, $dataIN);

    } elsif ($event->{type} eq "read" and ($event->{fh} == $readerOUT)) {
        $dataOUT .= $event->{data};
        
        if(length($dataIN) == length($dataOUT)) {
            $mux->disconnect($writerIN);
        }
    
    } elsif ($event->{type} eq "read" and ($event->{fh} == $readerERR)) {
        $dataERR .= $event->{data};
    
    } elsif ($event->{type} eq "disconnect" and ($event->{fh} == $readerOUT)) {
        print "OUT:$dataOUT";

        if($closed++) {
            waitpid $pid, 0;
            print "Exit status: $?\n";
            last;
        }
    
    } elsif ($event->{type} eq "disconnect" and ($event->{fh} == $readerERR)) {
        print "OUT:$dataERR";
        
        if($closed++) {
            waitpid $pid, 0;
            print "Exit status: $?\n";
            last;
        }
    
    }
}

# vim: et tw=79 sw=4 sts=4
