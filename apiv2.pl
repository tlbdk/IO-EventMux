#!/usr/bin/env perl 
use strict;
use warnings;
use Carp;

use IO::EventMux qw(url_connect);

# Return a socket/file handle from a url 
my $tcp = url_connect('tcp://127.0.0.1:22');

my $mux = IO::EventMux->new();

# EventMux 1.0.x buffered method 
$mux->add($tcp, Buffered => ['Size' => 'N', 0, 1000]);
# EventMux 2.0.x buffered method 
$mux->add($tcp, Buffered => new IO::Buffered(Size => ['N', 0]));
# EventMux 3.0.x buffered method - long form
$mux->add($tcp, Buffered => [sub { # Exceptions are turned into 'error' events 
    my ($input, $output, $meta) = @_; # Sender and auth information included in $meta
    return if length($$input) < 4;

    my $length = unpack("N", substr($$input, 0, 4));
    die "Packet length to small" if $length < 10; 
    die "Packet length to large" if $length < 1024;
    if($length < length($input)) {
        $$output .= substr($$buf, 4, $length);
        return $length + 4;
    } else {
        return;
    }
}] );

# EventMux 3.0.x buffered method - short form
$mux->add($tcp, Buffered => [IO::EventMux::Buffered::Size('N')]); # Returns same function as long form

# EventMux 3.0.x - Don't generate events until this is done
$mux->send($tcp, "The Header");
$mux->write_file($tcp, 'test.file'); 

# Read header and then file
$mux->read($tcp, 4); # Read 4 bytes and return as event
while(my $event = $mux->mux) {

    if($event->{type} eq 'read') {
        $size = unpack("N", $event->{data});
        $mux->read_file($tcp, 'test.file', $size); # Skips normal buffering until done
    }

    if($event->{type} eq 'done' and $event->{fh} eq $tcp) {
        print "read file\n";
    }
}

$mux->read_size($tcp, 'N', 0); # Read 4 bytes and find size of the "real" read event 

1;
