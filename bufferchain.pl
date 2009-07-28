#!/usr/bin/env perl 
use strict;
use warnings;
use Carp;
    

my $id = 309;
my $data = ($id++).": Hello socket"; 
$data = pack("Na*", length($data), $data);

my $fh = 'fh';
my $self = {
    meta => {
        fh => $fh,
    },
    input => {},
};

my @buffers = (
    sub {
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
    },
    sub {
        my ($input, $output, $meta) = @_; 
        if($$input =~ /^(\d+):(.*)$/) {
            $meta->{id} = $meta->{fh}.$1;
            $$output = $2;
            return length($input);
        } else {
            die "Invalid packet";
        }
    }
);

print "start".$data."\n";

# Prepare buffers
for (my $i = 0; $i <= int @buffers; $i++) {
    $self->{input}{fh}[$i] = '';
}

while(my $str = substr($data, 0, 3, '')) {
    my $res = bufferchain($self, $fh, $str, @buffers);
    print "res: ".(defined $res ? $res : 'undef')."\n";
}

sub bufferchain {
    my ($self, $fh, $data, @buffers) = @_;

    print "bufferchain\n";

    my $input = $self->{input}{$fh};
    $input->[0] .= $data;
   
    my $length;
    for (my $i = 0; $i < int @buffers; $i++) {
        $length = $buffers[$i]->(\$input->[$i], \$input->[$i+1], $self->{meta});
        print "len: ".(defined $length ? $length : 'undef')."\n";
        if($length) {
            print "input:".$input->[$i],"\n";
            print "output:".$input->[$i+1]."\n";
            substr($input->[$i], 0, $length, '');
        } else {
            last;
        }
    }

    return $length ? $input->[-1] : ();
}

