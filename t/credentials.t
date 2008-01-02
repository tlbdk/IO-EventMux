use strict;
use warnings;

use Test::More tests => 3;

use IO::EventMux;
use File::Temp qw(tempfile);
use IO::Socket::UNIX;

# Get a filename to listen to
my ($fh, $filename) = tempfile();
close $fh;
unlink($filename);

my $listener = IO::Socket::UNIX->new(
    Listen   => SOMAXCONN,
    Blocking => 1,
    Local    => $filename,
) or die "Listening to ${filename}: $!";


my $connected = IO::Socket::UNIX->new(
    Blocking => 1,
    Peer     => $filename,
) or die "Listening to ${filename}: $!";

my %fhs = ( $listener => 'listener', $connected => 'connected' );

my $mux = IO::EventMux->new();
$mux->add($listener);
$mux->add($connected);

while(1) {
    my $event = $mux->mux(5);

    #print "FH:".($fhs{$event->{fh}} or 'new') ."\n" if exists $event->{fh};
    #use Data::Dumper; print Dumper($event);
    
    if($event->{type} eq 'accepted') {
        is($event->{pid}, $$, "PID is correct");
        is($event->{gid}, (split(/\s/,$())[0], "GID is correct");
        is($event->{uid}, $<, "UID is correct");
        exit;
    
    } elsif($event->{type} eq 'error') {
        fail "Got error";
        exit;

    } elsif($event->{type} eq 'timeout') {
        fail "Got timeout";
        exit;
    }
}
