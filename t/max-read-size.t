#!perl -w -I lib
use strict;

use Test::More tests => 2;

use IO::EventMux;

my $mux = IO::EventMux->new();

sub string_fh {
    my $pid = open my $infh, "-|";
    die if not defined $pid;

    if ($pid == 0) {
        print @_;
        exit;
    }
    return $infh;
}

my $goodfh = string_fh("Hello\nHello\nLast");
my $failfh = string_fh("Hello\nHello!\nLast");

$mux->add($goodfh, Buffered => ['Split', qr/\n/, 6]);
$mux->add($failfh, Buffered => ['Split', qr/\n/, 6]);

my %types;
while ($mux->handles > 0) {
    my $event = $mux->mux();
    if ($event->{fh}) {
        $types{$event->{fh}} .= $event->{type};
    }
}

is($types{$goodfh}, join("", qw(read read read closing closed)),
    "Succeeds when it should");

is($types{$failfh}, join("", qw(read error read_last closing closed)),
    "Fails when it should");

