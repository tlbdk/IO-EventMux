#!/usr/bin/env perl 
use strict;
use warnings;
use Carp;

# Make packet
my $id = 309;
my $data = ($id++).": Hello socket"; 
$data = pack("Na*", length($data), $data);
my $fh = 'fh';

my $mux = new IO::EventMux();

$mux->add($fh, Buffered => [
    \&IO::EventMux::size_buffer,
    \&IO::EventMux::string_num_id,
]);

print "start".$data."\n";

while(my $str = substr($data, 0, 3, '')) {
    $mux->append($fh, $str);
    my $event = $mux->mux($fh) or next;
    print Dumper($event);    
}

package IO::EventMux;

sub new {
    my ($class) = @_;
    
    return bless {
        meta => {
            fh => $fh,
        },
        input => {},
        events => [],
    }, $class;
}

sub append {
   my($self, $fh, $buf) = @_; 
    
    my $buffers = $self->{buffered}{$fh};
    
    my $input = $self->{input}{$fh};
    $input->[0] .= $data;

    print "bufferchain\n";
   
    my $length;
    for (my $i = 0; $i < int @{$buffers}; $i++) {
        $length = $buffers->[$i]->(\$input->[$i], \$input->[$i+1], $self->{meta});
        print "len: ".(defined $length ? $length : 'undef')."\n";
        if($length) {
            print "input:".$input->[$i],"\n";
            print "output:".$input->[$i+1]."\n";
            substr($input->[$i], 0, $length, '');
        } else {
            last;
        }
    }

    push (@{$self->{events}}, $input->[-1]) if $length;
}

sub add {
    my($self, $fh, %args) = @_; 

    my $self->{buffered}{$fh} = $args{Buffered};

    # Prepare buffers
    for (my $i = 0; $i <= int @buffers; $i++) {
        $self->{input}{$fh}[$i] = '';
    }
}

sub mux {
    my ($self, $fh) = @_;

}

sub buf_size {
    my ($input, $output, $meta) = @_; # Sender and auth information included in $meta
    return if length($$input) < 4; # We should have at least the length bytes

    my $length = unpack("N", substr($$input, 0, 4));
    die "Packet length to small: $length" if $length < 4;
    die "Packet length to big: $length" if $length > 2 * 1024 * 1024; # Max 2MB

    if($length + 4 <= length($$input)) {
        $$output .= substr($$input, 4, $length);
        return $length + 4;
    } else {
        # Return if we don't have enough data yet
        return;
    }
}

sub buf_string_num_id {
    my ($input, $output, $meta) = @_; 
    if($$input =~ /^(\d+):(.*)$/) {
        $meta->{id} = $meta->{fh}.$1;
        $$output = $2;
        return length($input);
    } else {
        die "Invalid packet";
    }
}

