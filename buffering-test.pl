#!/usr/bin/env perl 
use strict;
use warnings;
use Carp;
use Data::Dumper;
use Benchmark;

my $index = 0;
my $buffer1 = '';
my $buffer2 = '';

buffer_add("x" x 15);
print Dumper($buffer1, $buffer2, $index);
buffer_remove(10);

print Dumper($buffer1, $buffer2, $index);

exit;
cmpthese(-1, {
    'Name1' => '...code1...',
	'Name2' => '...code2...',
});


sub buffer_add {
    my ($str) = @_;
    my $size = length($str);
    my $left1 = 8 - length($buffer1);
    my $left2 = 8 - length($buffer2);

    if($left1 > 0) {
        $buffer1 .= substr($str, 0, $left1);
    }

    if($left2 > 0) {
        $buffer2 .= substr($str, $left1, $left2);
   
    # TODO Check if there is still more stuff in $str

    } else {
        die "Buffer full";
    }
}

sub buffer_remove {
   my ($size) = @_;
   if($index + $size < length($buffer1)) {
       $index += $size;
       return substr($buffer1, $index, $size);
   } else {
       my $result = substr($buffer1, $index)
            .substr($buffer2, 0, $size - length($buffer1));
       $index = 0;
       $buffer1 = $buffer2;
       $buffer2 = '';
       return $result;
   }

}
