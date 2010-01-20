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


# EventMux 3.0.x - Don't generate events until this is done
$mux->send($tcp, "The Header");
$mux->send_file($tcp, 'test.file'); 

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

############################

# EventMux 3.0.x - Don't generate events until this is done
$mux->add($fh, 
    SendFilter => sub {  
        my ($input, $output, $session) = @_; # Sender and auth information included in $meta
        $$output .= pack('N', length($$input)).$$input;
    },
    ReadFilter => sub { # Exceptions are turned into 'error' events 
        my ($input, $output, $session) = @_; # Sender and auth information included in $meta
        return if length($$input) < 4;

        my $length = unpack("N", substr($$input, 0, 4));
        die "Packet length to small" if $length < 10; 
        die "Packet length to large" if $length < 1024;
        if($length < length($input)) {
            $$output .= substr($$input, 4, $length);
            return $length + 4; # Number of bytes to remove from $$input
        } else {
            return;
        }
    },
);


# Filters api - test test
# @data = map { /(.*)\n/ } map { unpack "N" ) $data;

# EventMux 3.0.x buffered method - short form
$mux->add($tcp, ReadFilter => IO::EventMux::Buffered::Size('N')); # Returns same function as long form

# EventMux 3.0.x Stacked filters, you can parse both an array ref and a sub ref 
$mux->add($tcp, ReadFilter => [ 
    IO::EventMux::Buffered::Size('N'), # Read length bytes and length data
    IO::EventMux::Buffered::Regex(qr/(.*)\n/si), # Split on lines
    # TODO: Use @+ and @- to get the match positions so we can return them
] );

$mux->add($tcp, ReadFilter => sub {
     my ($input, $output, $session) = @_; ## ?????
     $$output = $$input; # Replace output with input
     return 0; # Don't remove stuff from $$input 
}); # Simple skip buffer



$mux->append($fh, "data"); # Don't send data only append
$mux->append($fh, "data"); # 
$muc->send($fh); # Send all data and also call SendFilter before

# Add tempory filter that will return an event after 4 bytes and then will be removed from the ReadFilter stack
$mux->add_filter($fh,
    ReadFilter => sub {
        my ($input, $output, $session) = @_; # Sender and auth information included in $meta
        if(length($$input) < 4) {
            $$output .= substr($$input, 0, 4);
            die "DELETE";
        }
    },
);

# Insert af filter on first position
$mux->insert_filter($fh, 0, sub { });

# Would be a wrapper for the above
$mux->read($fh, 4);

# Call the sub after 4 bytes of input data
$mux->read($fh, 4, sub {
    my ($data, $session) = @_;
    my $length = unpack("N", substr($$input, 0, 4));

    # Read file from $fh to test.file
    $mux->read_file($fh, "test.file");
});

$mux->read_unpack($fh, "N", sub {
    my($data, $session) = @_;

});


1;
