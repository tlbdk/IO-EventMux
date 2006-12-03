package IO::EventMuxOld;

=head1 NAME

IO::EventMux - Multiplexer for sockets or pipes with line buffering

=head1 SYNOPSIS

  use IO::EventMux;

  my $mux = IO::EventMux->new(
    Listen => $my_fd
  );

  while (1) {
    my $event = $mux->mux();

    # ... do something with $event->{type} and $event->{fh}
  }

=head1 DESCRIPTION

This module provides multiplexing for any set of sockets, pipes, or whatever
you can set O_NONBLOCK on.  It can be useful for both server and client
processes, but it works best when the application's main loop is centered
around its C<mux()> method.

The file handles it can work with are either perl's own typeglobs or IO::Handle
objects (preferred).

=head1 METHODS

=cut

use strict;
use warnings;

use IO::Select;
use IO::Socket;
use Socket;
use Carp qw(carp cluck);
use Fcntl;
use POSIX qw(EWOULDBLOCK ENOTCONN EAGAIN F_GETFL F_SETFL O_NONBLOCK);

=head2 B<new(%options = ())>

Constructs an IO::EventMux object, setting a set of options:

=over

=item Listen

Can be either a socket or an array of sockets.  These sockets must be set up
for listening, which is easily done with IO::Socket::INET sockets:

  my $listener = IO::Socket::INET->new(
    Listen    => 5,
    LocalPort => 7007,
    ReuseAddr => 1,
  );

=item ManualAccept

If a connection comes in on a listening socket, it will by default be accepted
automatically, and mux() will return a 'connect' event.  If ManualAccept is
set, an 'accept' event will be returned instead, and the user code must handle
it itself.

=item LineBuffered

Global default for new file handles.  See C<add()> for a description. Default
is off.

=item ManualWrite

Global default for new file handles.  See C<add()> for a description. Default
is off.

=item ManualRead

Global default for new file handles.  See C<add()> for a description. Default
is off.

=item Type

Global default for new file handles.  See C<add()> for a description. Default
is off.

=back

=cut

sub new {
    my ($class, %opts) = @_;

    # TODO: deprecated
    my @listeners;
    if (ref($opts{Listen}) eq "ARRAY") {
        @listeners = @{$opts{Listen}};
    } else {
        @listeners = ($opts{Listen} or ());
    }

    bless {
        auto_accept   => !$opts{ManualAccept},
        line_buffered => $opts{LineBuffered},
        buffered      => $opts{Buffered},
        auto_write    => !$opts{ManualWrite},
        auto_read     => !$opts{ManualRead},
        type          => $opts{Type} || "stream",
        listenfh      => { map { $_ => 1 } @listeners },
        readfh        => IO::Select->new(@listeners),
        writefh       => IO::Select->new(),
        fhs           => { },
        events        => [ ],
        actionq       => [ ],
    }, $class;
}

=head2 B<mux([$timeout])>

This method will block until ether an event occurs on one of the file handles
or the $timeout (floating point seconds) expires.  If the $timeout argument is
not present, it waits forever.  If $timeout is 0, it returns immediately.

The return value is always a hash, which always has the key 'type', indicating
what kind it is.  It will also usually carry the 'fh' key, indicating what file
handle the event happened on.

The 'type' key can have the following values:

=over

=item timeout

Nothing happened and timeout occurred.

=item error

The C<select()> system call failed. The event hash will have the key 'error',
which is set to the value of $! at the time of the error.

=item connect

A new client connected to a listening socket.

=item accept

A new client is trying to connect to a listening socket, but the user code must
call accept manually.  This only happens when the ManualAccept option is
set.

=item read

A socket has incoming data.  If the socket's LineBuffered option is set, this
will always be a full line, including the terminating newline.  The data is
contained in the 'data' key of the event hash.  If recv() returned a sender
address, it is contained in the 'sender' key and must be manually unpacked
according to the socket domain, e.g. with C<Socket::unpack_sockaddr_in()>.

=item disconnect

A socket disconnected, or a pipe was closed.

=item can_write

The ManualWrite option is set for the file handle, and C<select()> has
indicated that the handle can be written to.

=item can_read

The ManualRead option is set for the file handle, and C<select()> has
indicated that the handle can be read from.

=back

=cut

sub mux {
    my $self = shift;
    my $event;

    # We call get_event in a loop, because it may not always return an event
    # even when a socket is readable (e.g. if a half line is sent on a
    # LineBuffered socket). This means that it may take arbitrarily long to
    # return, regardless of the timeout parameter, because the same timeout is
    # reused every time.
    until ($event = $self->get_event(@_)) {}
    return $event;
}

sub get_event {
    my ($self, $timeout) = @_;

    # pending events?
    if (my $event = shift @{$self->{events}}) {
        return $event;
    }

    # actions to execute?
    while (my $action = shift @{$self->{actionq}}) {
        $action->($self);
    }

    # timeouts to respect?
    my $time = time;
    my $timeout_fh = undef;
    for my $fh ($self->{readfh}->handles) {
        if (my $abs_timeout = $self->{fhs}{$fh}{abs_timeout}) {
            my $rel_timeout = $abs_timeout - $time;

            if (!defined $timeout || $rel_timeout < $timeout) {
                $timeout = $rel_timeout;
                $timeout_fh = $fh;
            }
        }
    }

    $! = 0;
    # TODO : handle OOB data
    my @result = IO::Select->select($self->{readfh}, $self->{writefh},
        undef, (!defined $timeout || $timeout > 0 ? $timeout : 0));

    if (@result == 0) {
        if ($!) {
            return { type => 'error', error => $! };
        } elsif ($timeout_fh) {
            return { type => 'timeout', fh => $timeout_fh };
        } else {
            return { type => 'timeout' };
        }
    }

    # buffers to flush?, can_write is set.
    for my $fh (@{$result[1]}) {
        if(exists $self->{fhs}{$fh}{connected}
            and $self->{fhs}{$fh}{connected} == 0) {
            $self->{fhs}{$fh}{connected} = 1;

            my $packederror = getsockopt($fh, SOL_SOCKET, SO_ERROR);

            if(!defined $packederror) {
                $self->push_event({ type => 'connected', fh => $fh });
            } else {
                my $error = unpack("i", $packederror);
                if($error == 0) {
                    $self->push_event({ type => 'connected', fh => $fh });
                } else {
                    $self->push_event({ type => 'error',
                            fh => $fh, error=> $error });
                    $self->disconnect($fh);
                }
            }

        } elsif ($self->{fhs}{$fh}{auto_write}) {
            $self->send($fh);
        } else {
            $self->push_event({ type => 'can_write', fh => $fh });
        }
    }

    # incoming data?
    for my $fh (@{$result[0]}) {
        delete $self->{fhs}{$fh}{abs_timeout};

        if ($self->{listenfh}{$fh}) {
            # new connection
            if ($self->{auto_accept}) {
                my $client = $fh->accept or next;
                $self->push_event({ type => 'connect', fh => $client });
                $self->add($client);
            } else {
                $self->push_event({ type => 'accept', fh => $fh });
            }

        } elsif (!$self->{fhs}{$fh}{auto_read}) {
            $self->push_event({ type => 'can_read', fh => $fh });

        } else {
            $self->read_all($fh);
        }
    }

    return shift @{$self->{events}};
}

=head2 B<add($handle, [ %options ])>

Add a socket to the internal list of handles being watched.  If one of the
current listening sockets is given here, accept will be called on it.

To add a new listening socket, use C<add_listener()> instead.

The optional parameters for the handle will be taken from the IO::EventMux
object if not given here:

=over

=item LineBuffered

If true, only whole lines will be read from the file handle.

=item ManualWrite

By default, write buffering is handled automatically, which is fine for
low-throughput purposes.  If a lot of data needs to be sent over the file
handle, manual write buffering will give better performance and higher
flexibility.

In both cases you can use send() to write data to the file handle.

=item ManualRead

Never read or recv on the file handle. When the socket becomes readable, a
C<can_read> event is returned.

=item Type

Either "stream" or "dgram". Be sure to set this to "dgram" for UDP sockets.

=item Meta

An optional scalar piece of metadata for the file handle.  Can be retrieved and
manipulated later with meta()

=back

=cut

sub add {
    my ($self, $arg, %opts) = @_;

    my $client = ($self->{listenfh}{$arg} ? $arg->accept() : $arg)
        or return;

    $self->{readfh}->add($client);

    # If this is not UDP(SOCK_DGRAM) send a connect event.
    if (!UNIVERSAL::can($client, "socktype") or ($client->socktype||0) != SOCK_DGRAM) {
        $self->{writefh}->add($client);
        $self->{fhs}{$client}{connected} = 0;
    }

    $self->{fhs}{$client}{line_buffered} = (exists $opts{LineBuffered} ?
        $opts{LineBuffered} : $self->{line_buffered});
    
    $self->{fhs}{$client}{buffered} = (exists $opts{Buffered} ?
        $opts{Buffered} : $self->{buffered});

    $self->{fhs}{$client}{auto_write} = (exists $opts{ManualWrite} ?
        !$opts{ManualWrite} : $self->{auto_write});

    $self->{fhs}{$client}{auto_read} = (exists $opts{ManualRead} ?
        !$opts{ManualRead} : $self->{auto_read});

    $self->{fhs}{$client}{type} = (exists $opts{Type} ?
        $opts{Type} : $self->{type});

    if ($self->{fhs}{$client}{auto_read} || $self->{fhs}{$client}{auto_write}) {
        $self->nonblock($client);
    }

    if ($opts{Meta}) {
        $self->{fhs}{$client}{meta} = $opts{Meta};
    }
}

=head2 B<handles()>

Returns a list of file handles managed by this object.

=cut

sub handles {
    my ($self) = @_;
    return $self->{readfh}->handles;
}

=head2 B<meta($fh, [$newval])>

Set or get a piece of metadata on the filehandle.  This can be any scalar
value.

=cut

sub meta {
    my ($self, $fh, $newval) = @_;

    if (@_ > 2) {
        $self->{fhs}{$fh}{meta} = $newval;
    }
    return $self->{fhs}{$fh}{meta};
}

=head2 B<remove($fh)>

Make EventMux forget about a file handle. The caller will then take over the
responsibility of closing it.

=cut

sub remove {
    my ($self, $fh) = @_;

    $self->{readfh}->remove($fh);
    $self->{writefh}->remove($fh);
    delete $self->{listenfh}{$fh};
    delete $self->{fhs}{$fh};
}

=head2 B<disconnect($fh, [ $instant ])>

Close a file handle.  File handles managed by EventMux must be closed through
this method to make sure all resources are freed.

If $instant is not true, a 'disconnect' event will be returned by mux() before
actually closing the file handle.

=cut

sub disconnect {
    my ($self, $fh, $instant) = @_;

    return if $self->{fhs}{$fh}{disconnecting};

    $self->{readfh}->remove($fh);
    $self->{writefh}->remove($fh);
    $self->{fhs}{$fh}{disconnecting} = 1;
    delete $self->{listenfh}{$fh};

    if ($instant) {
        $self->close_fh($fh);
    } else {
        $self->push_event({ type => 'disconnect', fh => $fh });

        # wait with the close so a valid file handle can be returned
        push @{$self->{actionq}}, sub {
            $self->close_fh($fh);
        };
    }
}

=head2 B<close_fh($fh)>

Force the file handle to be closed. I<Must only> be called after a "disconnect"
event has been received from C<mux()>.

=cut

sub close_fh {
    my ($self, $fh) = @_;

    if ($self->{fhs}{$fh}) {
        delete $self->{fhs}{$fh};
        shutdown $fh, 2;
        close $fh or warn "closing $fh: $!";
    }
}

=head2 B<add_listener($socket)>

Register a new listening socket.

=cut

sub add_listener {
    my ($self, @socks) = @_;

    foreach my $sock (@socks) {
        $self->nonblock($sock);
        $self->{readfh}->add($sock);
        $self->{listenfh}{$sock} = 1;
    }
}

=head2 B<timeout($fh, [ $set_timeout ])>

Get or set the read timeout for this file handle in seconds. When no data has
been received for this many seconds, a 'timeout' event will be returned for this
file handle.

Set the undefined value for infinite timeout, which is the default.

The timeout is reset to infinity if any data is read from the file handle, so it
should be set again before the next read if desired.

=cut

sub timeout {
    my ($self, $fh, $new_val) = @_;

    my $time = time;

    if (@_ > 2) {
        if (!defined $new_val) {
            delete $self->{fhs}{$fh}{abs_timeout};
        } else {
            $self->{fhs}{$fh}{abs_timeout} = $new_val + $time;
        }
    }
    return $self->{fhs}{$fh}{abs_timeout} - $time;
}

=head2 B<buflen($fh)>

Queries the length of the output buffer for this file handle.  This only
applies if ManualWrite is turned off, which is the default. For Type="dgram"
sockets, it returns the number of datagrams in the queue.

An application can use this method to see whether it should send more data or
wait until the buffer queue is a bit shorter.

=cut

sub buflen {
    my ($self, $fh) = @_;
    my $meta = $self->{fhs}{$fh};

    if ($meta->{type} eq "dgram") {
        return $meta->{outbuffer} ? scalar(@{$meta->{outbuffer}}) : 0;
    }

    return $meta->{outbuffer} ? length($meta->{outbuffer}) : 0;
}

=head2 B<send($fh, @data)>

Attempt to write each item of @data to $fh. Can only be used when ManualWrite is
off (default).

=over

=item If the socket is of Type="stream" (default)

Returns true on success, undef on error.  The data may or may not have been
written to the socket when the function returns.  Therefore the socket should
not be closed until L</B<buflen($fh)>> returns 0.  If an unrecoverable error
occurs, the file handled will be closed.

=item If the socket is of Type="dgram"

Each item in @data will be sent as a separate packet.  Returns the number of
packets written to the socket, which may include packets that were already in
the queue. Returns undef on error, in which case the file handle is closed.

=back

=cut

sub send {
    my ($self, $fh, @data) = @_;
    return $self->sendto($fh, undef, @data);
}

=head2 B<sendto($fh, $to, @data)>

Like C<send()>, but with the recepient C<$to> as a packed sockaddr structure,
such as the one returned by C<Socket::pack_sockaddr_in()>. Only for Type="dgram"
sockets.

=cut

sub sendto {
    my ($self, $fh, $to, @data) = @_;

    if (not defined $fh) {
        carp "send() on an undefined file handle";
        return;
    }
    my $meta = $self->{fhs}{$fh} or return undef;
    return undef if $meta->{disconnecting};

    if (not $meta->{auto_write}) {
        carp "send() on a ManualWrite file handle";
        return;
    }

    if ($meta->{type} eq "dgram") {
        return $self->send_dgram($fh, $to, @data);
    } else {
        return $self->send_stream($fh, @data);
    }
}

sub send_dgram {
    my ($self, $fh, $all_to, @newdata) = @_;
    my $meta = $self->{fhs}{$fh} or return undef;

    push @{$meta->{outbuffer}}, map { [$_, $all_to] } @newdata;

    my $packets_sent = 0;

    while (my $queue_item = shift @{$meta->{outbuffer}}) {
        my ($data, $to) = @$queue_item;
        my $rv = $self->my_send($fh, $data, (defined $to ? $to : ()));

        if (!defined $rv) {
            if ($! == POSIX::EWOULDBLOCK) {
                # retry later
                unshift @{$meta->{outbuffer}}, $queue_item;
                $self->{writefh}->add($fh);
                return $packets_sent;
            } else {
                # error on socket
                warn "send: $!";
                $self->disconnect($fh);
            }
            return undef;

        } elsif ($rv < length $data) {
            cluck "Incomplete datagram sent (should not happen)";

        } else {
            # all pending data was sent
            $packets_sent++;
        }
    }

    $self->{writefh}->remove($fh);

    return $packets_sent;
}

sub send_stream {
    my ($self, $fh, @data) = @_;
    my $meta = $self->{fhs}{$fh} or return undef;

    # send pending data before this
    my $data = join "",
        (defined $meta->{outbuffer} ? $meta->{outbuffer} : ()), @data;

    delete $meta->{outbuffer};

    if (length $data == 0) {
        # no data to send
        $self->{writefh}->remove($fh);
        return 0;
    }

    my $rv = $self->my_send($fh, $data);
    
    if (!defined $rv) {
        if ($! == POSIX::EWOULDBLOCK or $! == POSIX::EAGAIN or !$self->{fhs}{$fh}{connected}) {
            # try later
            $meta->{outbuffer} = $data;
            $self->{writefh}->add($fh);
            return 0;
        } else {
            # error on socket
            warn "send: $!";
            $self->disconnect($fh);
        }
        return undef;

    } elsif ($rv < 0) {
        warn;
        $self->disconnect($fh);
        return undef;

    } elsif ($rv < length $data) {
        # only part of the data was sent
        $meta->{outbuffer} = substr $data, $rv;
        $self->{writefh}->add($fh);
    } else {
        # all pending data was sent
        $self->{writefh}->remove($fh);
    }

    return $rv;
}

sub my_send {
    my ($self, $fh, $data, @to) = @_;

    my $rv;
    $! = undef;
    if (UNIVERSAL::can($fh, "send") and !$fh->isa("IO::Socket::SSL")) {
        $rv = eval { $fh->send($data, 0, @to) };
    } else {
        $rv = eval { syswrite $fh, $data };
    }
    return $@ ? undef : $rv;
}

sub select_write {
    $_[0]->{writefh}->add($_[1]);
}

sub unselect_write {
    $_[0]->{writefh}->remove($_[1]);
}

sub push_event {
    push @{$_[0]->{events}}, $_[1];
}

# nonblock($socket) puts socket into nonblocking mode
sub nonblock {
    my $socket = $_[1];

    my $flags = fcntl($socket, F_GETFL, 0)
        or die "Can't get flags for socket: $!\n";
    if (not $flags & O_NONBLOCK) {
        fcntl($socket, F_SETFL, $flags | O_NONBLOCK)
            or die "Can't make socket nonblocking: $!\n";
    }
}

# Keeps reading from a file handle until POSIX::EWOULDBLOCK is returned
sub read_all {
    my ($self, $fh) = @_;
    my $cfg = $self->{fhs}{$fh};

    while (1) {
        my ($data, $rv, $sender) = ('');
        if (UNIVERSAL::can($fh, "recv") and !$fh->isa("IO::Socket::SSL")) {
            $rv = $fh->recv($data, 65536, 0);
            $sender = $rv if defined $rv && $rv ne "";
        } else {
            $rv = sysread $fh, $data, 65536;
        }

        if (not defined $rv) {
            if ($! != POSIX::EWOULDBLOCK) {
                $self->push_event({ type => 'error', error => $!, fh => $fh });
            }
            return;
        }

        if (length $data == 0 and $cfg->{type} eq "stream") {
            # client disconnected
            $self->disconnect($fh);
            return;
        }

        my %event = (type => 'read', fh => $fh);
        $event{'sender'} = $sender if defined $sender;

        if($cfg->{buffered}) {
            my ($type, @args) = @{$cfg->{buffered}};
            $cfg->{inbuffer} .= $data;
            
            if($type eq "Size"){
                my ($pattern, $offset) = (@args, 0);
                my $length = 
                    (unpack($pattern, $cfg->{inbuffer}))[0];
                my $datastart = length(pack($pattern, $length));

                while($length <= length($cfg->{inbuffer})) {
                    my %copy = %event;
                    $copy{'data'} = substr($cfg->{inbuffer},
                        $datastart, $length+$offset);
                    substr($cfg->{inbuffer}, $datastart, $length+$offset) = '';
                    $self->push_event(\%copy);
                }
            }
            
        } elsif ($cfg->{line_buffered}) {
            $cfg->{inbuffer} .= $data;
            while ($cfg->{inbuffer} =~ s/(.*\n)//) {
                my %copy = %event;
                $copy{'data'} = $1;
                $self->push_event(\%copy);
            }

        } else {
            $event{'data'} = $data;
            $self->push_event(\%event);
        }
    }
}

1;

=head1 AUTHOR

Jonas Jensen <jbj@knef.dk>
Troels Liebe Bentsen <tlb@rapanden.dk>

=cut

# vim: et sw=4 sts=4 tw=80
