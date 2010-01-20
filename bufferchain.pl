#!/usr/bin/env perl 
use strict;
use warnings;
use Carp qw(carp cluck croak);
use Data::Dumper;
use Benchmark qw(:all);

# Make packet
my $id = 309;
my $data = ($id++).": Hello socket"; 
$data = "1234567890";
my $fh = 'fh';

my $mux = new IO::EventMux();

$mux->add($fh, ReadFilter => [
    sub {
        my ($input, $session) = @_; # Sender and auth information included in $session
        return if length($$input) < 4;
        return substr($$input, 0, 4, '');
    },
    sub {
        my ($input, $session) = @_; # Sender and auth information included in $session
        return if length($$input) < 2;
        return substr($$input, 0, 2, '');
    }
]);

print "start: ".$data."\n";

$mux->add($fh, ReadFilter => [
    sub {
        my ($input, $session) = @_; # Sender and auth information included in $session
        return if length($$input) < 4;
        return substr($$input, 0, 4, '');
    },
]);

cmpthese(-1, {
    'Name1' => sub { 
        $mux->append($fh, "aaaa");
        $mux->mux();
    },
    'simple' => sub {
        my $var = sub {
            my $str = "aaaa";
            if(length($str) >= 4) {
                my $str2 = substr($str, 0, 4, '');
            }
        };
        $var->();
    }
});
exit;

while(my $str = substr($data, 0, 3, '')) {
    $mux->append($fh, $str); # Will be called by when the socket is full
    while(my $event = $mux->mux($fh)) {
        print Dumper($event);
    }
}

package IO::EventMux;
use Carp qw(carp cluck croak);
use Data::Dumper;

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
    
    my $filters = $self->{readfilters}{$fh};
   
    # print "bufferchain\n";
    # Add input data to first buffer
    my $inputs = $self->{input}{$fh};
    $inputs->[0][0] .= $buf;

    for (my $i = 0; $i < int @{$filters}; $i++) {
        my $input = '';
        #print Dumper($inputs);
        while(my $buf = shift @{$inputs->[$i]}) {
            $input .= $buf;
            while(my @output = $filters->[$i]->(\$input, $self->{meta})) {
                #print Dumper(\@output);
                push(@{$inputs->[$i+1]}, @output);
            }
        }
        $inputs->[$i][0] = $input . (@{$inputs->[$i]} ?  $inputs->[$i][0] : '');
        #print Dumper($inputs);
    }
   
    while(my $data = shift @{$inputs->[-1]}) {
        push (@{$self->{events}}, {
            type => 'read',
            data => $data,
            fh => $fh,
        });
    }
}

sub add {
    my($self, $fh, %args) = @_; 

    croak "Not all elements in ReadFilter is code refs" 
        if ref $args{ReadFilter} eq 'ARRAY' and grep { ref $_ ne 'CODE' } @{$args{ReadFilter}};
    
    croak "ReadFilter is not a an ARRAY or a code ref" 
        if ref $args{ReadFilter} ne 'ARRAY' and ref $args{ReadFilter} ne 'CODE';

    $self->{readfilters}{$fh} = $args{ReadFilter};

    # Prepare buffers
    for (my $i = 0; $i < int @{$self->{readfilters}{$fh}}; $i++) {
        $self->{input}{$fh}[$i] = [];
    }
}

sub mux {
    my ($self, $fh) = @_;

    return shift @{$self->{events}};
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

