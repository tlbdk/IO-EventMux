#!/usr/bin/perl
use strict;
use warnings;

use Test::More tests => 9;
use IO::EventMux;

my $mux = IO::EventMux->new(ReadPriorityType => ['FairByEvent']);

sub create_writer {
    my ($data) = @_;

    pipe my $readerOUT, my $writerOUT or die;

    my $pid = fork;
    if ($pid == 0) {
        close $readerOUT or die;
        open STDOUT, ">&", $writerOUT or die;
        exec "sh", "-c", "echo \"$data\"; sleep 1;";
        die;
    }

    close $writerOUT;
    $mux->add($readerOUT, 
        Buffered => ["Split", qr/\n/],
        ReadSize => 4,
        Meta => { pid => $pid },
    );

    return $readerOUT;
}

my $count = 0;

my $select = IO::Select->new();
foreach my $i (1..3) {
    my $fh = create_writer(("hello\n" x  3));
    # Sleep until we can read on the socket
    $select->add($fh); $select->can_read(10); $select->remove($fh);
    $count++; 
}


my $lastfh = '';
while (my $event = $mux->mux()) {
    my $fh = $event->{fh};
    my $data = ($event->{data} or '');
    my $meta = $mux->meta($fh);
    
    print "Got event($fh): $event->{type} -> '$data'\n";

    if ($event->{type} eq "connected") {
    } elsif ($event->{type} eq "read") {
        ok($fh ne $lastfh, "We got a new file handle this time");

    } elsif ($event->{type} eq "disconnect") {
        waitpid $meta->{pid}, 0;
        print "Exit status: $?\n";
    
    } elsif ($event->{type} eq "disconnected") {
        if(--$count == 0) {
            last;
        }
        print "count:$count\n";

    } elsif ($event->{type} eq "timeout") {
    } elsif ($event->{type} eq "read_last") {
    } else {
        die("Unknown event type $event->{type}");
    }

    $lastfh = $fh;
}
