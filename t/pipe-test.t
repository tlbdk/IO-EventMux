use strict;
use warnings;

use Test::More tests => 3;
use IO::EventMux;
use Socket;
use Fcntl;

my $mux = IO::EventMux->new();

my ($parent, $child);
my ($readerOUT, $readerERR, $writerOUT, $writerERR);

local $^F = 1024; # avoid close-on-exec flag being set
socketpair($parent, $child, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or die "socketpair: $!";
pipe $readerOUT, $writerOUT or die;
pipe $readerERR, $writerERR or die;

my $pid = fork;
if ($pid == 0) {
    close $parent or die;
    close $readerOUT or die;
    close $readerERR or die;

    open STDOUT, ">&", $writerOUT or die;
    open STDERR, ">&", $writerERR or die;
   
    print STDERR "Hello err";
    print "Hello out";
    print {$child} "Hello socket";
    exit;
}

close $child;
close $writerOUT;
close $writerERR;

$mux->add($parent);
$mux->add($readerOUT);
$mux->add($readerERR);

while (my $event = $mux->mux()) {
    my $fh = $event->{fh};
    my $data = ($event->{data} or '');
    my $type = $event->{type};

    is($data, 'Hello err', 'STDERR works') if $fh eq $readerERR and $type eq 'read';
    is($data, 'Hello out', 'STDOUT works') if $fh eq $readerOUT and $type eq 'read';
    is($data, 'Hello socket', 'Socket works') if $fh eq $parent and $type eq 'read';

    # Wait to make sure everybody is ready to fill the buffer.
    print "Got event($fh): $event->{type} -> '$data'\n";
}
