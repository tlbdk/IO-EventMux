package IO::EventMux;

our $VERSION = "1.00";

#FIXME:
#
# 1. Should a user invoked non delayed disconnect still read all the data on the
# socket. eg.
#   1. read only the header from a rpm, and not downloading the rest of the
#      100mb.
#   2. wget -O - http://www.rapanden.dk, send GET request and disconnect and
#      read buffer later.
#   
#   idea:
#
#   User invoked disconnect delayed and non delayed throws out any buffers and
#   stop reading on the socket. As the user did not care about receiving data,
#   the he would have waited with calling the disconnect call.
#   
#   This also makes it much simpler to do the PriorityType as we now are sure
#   there is nothing in the socket when we detect a disconnect.
#
#   Buffering and UDP, how do we do that, we need to make a inbuffer, pr.
#   sender???
#
#

=head1 NAME

IO::EventMux - Multiplexer for sockets, pipes and any other types of
filehandles that you can set O_NONBLOCK on and does buffering for the user.

=head1 SYNOPSIS

  use IO::EventMux;

  my $mux = IO::EventMux->new();

  $mux->add($my_fh, Listen => 1);

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

=head2 B<new([%options])>

Constructs an IO::EventMux object.

=head3 PriorityType UNIMPLEMENTED, API MIGHT CHANGE 

EventMux implements different types that priority queues that determined
how events are returned.

The default is C<'None'>.

=over 2

=item FairByEvent

File handles change turn generating events and gets the minimum of number of 
reads for generating one event, but if the data returned can be used to 
generate more events all events will be pushed to the queue to be returned 
with the C<mux()> call.

  my $mux = IO::EventMux->new( PriorityType => ['FairByEvent'] );

This is also the default PriorityType.

=item FairByRead (NOT IMPLEMENTED)

File handles are read in turn and the first file handle to be able to return 
an event from the read data will return a event on the C<mux()> call.

  my $mux = IO::EventMux->new( PriorityType => ['FairByRead'] );
  my $mux = IO::EventMux->new( PriorityType => ['FairByRead', $reads_pr_turn] );

$reads_pr_turn is the number of reads the file handle gets to generate an event.

Default $reads_pr_turn is 1.

=item None

Events are generated based on the order the file handles are read, this will 
allow file handles returning allot of events to monopolize the event loop. This
also allow the other end of the file handle to fill the memory of the host as
EventMux will continue reading so long there is data on the file handle.

  my $mux = IO::EventMux->new( PriorityType => ['None'] );

Use this PriorityType with care and only on trusted sources as it's very easy to
exploit.

=back
=cut

sub new {
    my ($class, %opts) = @_;

    bless {
        buffered      => ['None'],
        prioritytype  => ['FairByEvent', 1],
        auto_accept   => 1,
        auto_write    => 1,
        auto_read     => 1,
        read_size     => 65536,
        return_last   => 1,
        type          => 'stream',
        listenfh      => { },
        readfh        => IO::Select->new(),
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

=item connected

A socket connected to a remote host, this can be use full when working with
nonblocking connects so you know when the remote connection accepted the
connection.

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

=item read_last

A socket has incoming data that did not match the buffering rules, this can
happen with the following buffering types: Size, FixedSize and Regexp.

The Buffering types: "Split", "Disconnect" and "None".expect this and will
return a read instead.

The default is 1, in the sense that "None" is the default buffering type, but 
else it's off by default.

=item disconnect

A socket/pipe was set to be disconnected/closed delayed and EventMux stooped
listening for events on this file handle. Data like Meta is still accessible.

=item disconnected

A socket/pipe was disconnected/closed, the file descriptor,
all internal references, and data store with the file handle was removed.

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
    until ($event = $self->_get_event(@_)) {}
    return $event;
}

sub _get_event {
    my ($self, $timeout) = @_;

    # pending events?
    if (my $event = shift @{$self->{events}}) {
        return $event;
    }
    
    # actions to execute?
    while (my $action = shift @{$self->{actionq}}) {
        $action->($self);
    }

    # try after we have flushed the action queue
    if (my $event = shift @{$self->{events}}) {
        return $event;
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
                $self->_push_event({ type => 'connected', fh => $fh });
            } else {
                my $error = unpack("i", $packederror);
                if($error == 0) {
                    $self->_push_event({ type => 'connected', fh => $fh });
                } else {
                    $self->_push_event({ type => 'error',
                            fh => $fh, error=> $error });
                }
            }

        } elsif ($self->{fhs}{$fh}{auto_write}) {
            $self->send($fh);
        } else {
            $self->_push_event({ type => 'can_write', fh => $fh });
        }
    }

    # incoming data, can_read is set.
    for my $fh (@{$result[0]}) {
        delete $self->{fhs}{$fh}{abs_timeout};

        if ($self->{listenfh}{$fh}) {
            # new connection
            if ($self->{auto_accept}) {
                my $client = $fh->accept or next;
                $self->_push_event({ type => 'connect', fh => $client });
                $self->add($client, %{$self->{fhs}{$fh}{opts}}, Listen => 0);
                # Set connected as we already sent a connect.
                $self->{fhs}{$client}{connected} = 1;
            } else {
                $self->_push_event({ type => 'accept', fh => $fh });
            }

        } elsif (!$self->{fhs}{$fh}{auto_read}) {
            $self->_push_event({ type => 'can_read', fh => $fh });

        } else {
            $self->_read_all($fh);
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

=head3 Listen

Defines if this is should be treated as a listening socket, the default is no.

The socket must be set up for listening, which is easily done with 
IO::Socket::INET:

  my $listener = IO::Socket::INET->new(
    Listen    => 5,
    LocalPort => 7007,
    ReuseAddr => 1,
  );

  $mux->add($listener, Listen => 1);

=head3 Type

Either "stream" or "dgram". Should be auto detected in most cases.

Defaults to "stream".

=head3 ManualAccept

If a connection comes in on a listening socket, it will by default be accepted
automatically, and mux() will return a 'connect' event.  If ManualAccept is set
an 'accept' event will be returned instead, and the user code must handle it
itself.

  $mux->add($my_fh, ManualAccept => 1);

=head3 ManualWrite

By default EventMux handles nonblocking writing and you should use 
$mux->send($fh, $data) or $mux->sendto($fh, $addr, $data) to send your data, 
but if some reason you send data yourself you can tell EventMux not to do 
writing for you and generate a 'can_write' event for you instead.
    
  $mux->add($my_fh, ManualWrite => 1);

In both cases you can use send() to write data to the file handle.

Note: If both ManualRead and ManualWrite is set, EventMux will not set the 
socket to nonblocking. 

=head3 ManualRead

By default EventMux will handle nonblocking reading and generate a read event
with the data, but if some reason you would like to do the reading yourself 
you can EventMux not to generate a 'can_read' event for you instead.
    
  $mux->add($my_fh, ManualRead => 1);

Never read or recv on the file handle. When the socket becomes readable, a
C<can_read> event is returned.

Note: If both ManualRead and ManualWrite is set, EventMux will not set the 
socket to nonblocking. 

=head3 ReadSize

By default EventMux will try to read 65536 bytes from the file handle, setting
this options to something smaller might help make it easier for EventMux to be
fair about how it returns it's event, but will also give more overhead as more
system calls will be required to empty a file handle.

=head3 Buffered

Can be a number of different buffering types, common for all of them is that
they define when a event should be generated based on when there is enough data
for the buffering type to be satisfied. All buffering types also generate an 
event with the remaining data when there is a disconnect.

The default buffering type is C<'None'>

=over 2

=item Size

Buffering that reads the size from the data to determine when to generate
an event. Only the data is returned not the bytes that hold the length 
information.
  
  $mux->add($my_fh, Buffered => ['Size', $template]);

$template is a pack TEMPLATE, an event is returned when length defined in the 
$template is reached.

  $mux->add($my_fh, Buffered => ['Size', $template, $offset]);

$offset is the numbers of bytes to add to the length that was unpacked with
the $template.

=item FixedSize

Buffering that uses a fixed size to determine when to generate an event.

  $mux->add($my_fh, Buffered => ['FixedSize', $size]);

$size is the number of bytes to buffer.

=item Split

Buffering that uses a regular expressing to determine where to split data into events. 
Only the data is returned not the splitter pattern itself.

  $mux->add($my_fh, Buffered => ['Split', $regexp]);

$regexp is a regular expressing that tells where the split the data.

This also works as line buffering when qr/\n/ is used or for a C string with
qr/\0/.

=item Regexp

Buffering that uses a regular expressing to determine when there is enough data
for an event. Only the match defined in the () is returned not the complete 
regular expressing.
  
  $mux->add($my_fh, Buffered => ['Regexp', $regexp]);

$regexp is a regular expressing that tells what data to return.

An example would be qr/^(.+)\n/ that would work as line buffing.

=item Disconnect

Buffering that waits for the disconnect to generate an event. 

  $mux->add($my_fh, Buffered => ['Disconnect']);

=item None

Disable Buffering and return data when it's received. This is the default state.

  $mux->add($my_fh, Buffered => ['None']);

=back

=head3 Priority

Set the priority of the for returning event from EventMux, fh's with higher 
priority will have their events returned first.

  $mux->add($my_fh, Priority => $priority);

$priority is the priority number from 0-2^31.

Default Priority is 0.

=head3 Meta

An optional scalar piece of metadata for the file handle.  Can be retrieved and
manipulated later with meta()

=cut

sub add {
    my ($self, $client, %opts) = @_;
    
    $self->{fhs}{$client}{buffered} = (exists $opts{Buffered} ?
        $opts{Buffered} : $self->{buffered});

    # Set return_last if default for the buffering type.
     if($self->{fhs}{$client}{buffered}[0] eq 'None' or 
        $self->{fhs}{$client}{buffered}[0] eq 'Split' or 
        $self->{fhs}{$client}{buffered}[0] eq 'Disconnect') {
        $self->{fhs}{$client}{return_last} = 1;
    }

    $self->{fhs}{$client}{auto_accept} = (exists $opts{ManualAccept} ?
        !$opts{ManualAccept} : $self->{auto_accept});

    $self->{fhs}{$client}{auto_write} = (exists $opts{ManualWrite} ?
        !$opts{ManualWrite} : $self->{auto_write});

    $self->{fhs}{$client}{auto_read} = (exists $opts{ManualRead} ?
        !$opts{ManualRead} : $self->{auto_read});

    $self->{fhs}{$client}{read_size} = (exists $opts{ReadSize} ?
        $opts{ReadSize} : $self->{read_size});

    if ($self->{fhs}{$client}{auto_read} 
        || $self->{fhs}{$client}{auto_write} || $opts{Listen}) {
        $self->nonblock($client);
    }
    
    $self->{fhs}{$client}{meta} = $opts{Meta} if exists $opts{Meta};

    $self->{listenfh}{$client} = 1 if $opts{Listen};
    
    $self->{readfh}->add($client);

    # If this is not UDP(SOCK_DGRAM) send a connected event.
    if ((!UNIVERSAL::can($client, "socktype") 
            or ($client->socktype || 0) != SOCK_DGRAM)) {
        #FIXME Only works on IO::Socket, change to use a socktype that works for
        # all kind of filehandles.

        if (!$opts{Listen}) {
            $self->{writefh}->add($client);
            $self->{fhs}{$client}{connected} = 0;
        }
    
    } else {
        $self->{fhs}{$client}{type} = 'dgram';
    }

    $self->{fhs}{$client}{type} = (exists $opts{Type} ?
        $opts{Type} : $self->{type});

    # Save %opts, so we can given the to $fh->accept() children.
    $self->{fhs}{$client}{opts} = \%opts;
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

=head2 B<disconnect($fh, [ $delayed ])>

Close a file handle.  File handles managed by EventMux must be closed through
this method to make sure all resources are freed.

If $instant is not true, a 'disconnect' event will be returned by mux() before
actually closing the file handle.

=cut

sub disconnect {
    my ($self, $fh, $delayed) = @_;

    return if $self->{fhs}{$fh}{disconnecting};
    $self->{fhs}{$fh}{disconnecting} = 1;

    # Return the leftovers in inbuffer to the user.
    $self->_read_all($fh);
    
    $self->{readfh}->remove($fh);
    $self->{writefh}->remove($fh);
    delete $self->{listenfh}{$fh};

    if ($delayed) {
        $self->_push_event({ type => 'disconnect', fh => $fh });
        
        # wait with the close so a valid file handle can be returned
        push @{$self->{actionq}}, sub {
            $self->close_fh($fh);
            $self->_push_event({ type => 'disconnected', fh => $fh });
        };
            
    } else {
        $self->close_fh($fh);
        $self->_push_event({ type => 'disconnected', fh => $fh });
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

  $mux->sendto($my_fh, pack_sockaddr_in($port, inet_aton($ip)), $data);

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
        return $self->_send_dgram($fh, $to, @data);
    } else {
        return $self->_send_stream($fh, @data);
    }
}

sub _send_dgram {
    my ($self, $fh, $all_to, @newdata) = @_;
    my $meta = $self->{fhs}{$fh} or return undef;

    push @{$meta->{outbuffer}}, map { [$_, $all_to] } @newdata;

    my $packets_sent = 0;

    while (my $queue_item = shift @{$meta->{outbuffer}}) {
        my ($data, $to) = @$queue_item;
        my $rv = $self->_my_send($fh, $data, (defined $to ? $to : ()));

        if (!defined $rv) {
            if ($! == POSIX::EWOULDBLOCK) {
                # retry later
                unshift @{$meta->{outbuffer}}, $queue_item;
                $self->{writefh}->add($fh);
                return $packets_sent;
            } else {
                $self->_push_event({ type => 'error', error => $!, 
                    fh => $fh });
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

sub _send_stream {
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

    my $rv = $self->_my_send($fh, $data);
    
    if (!defined $rv) {
        if ($! == POSIX::EWOULDBLOCK or $! == POSIX::EAGAIN 
                or !$self->{fhs}{$fh}{connected}) {
            # try later
            $meta->{outbuffer} = $data;
            $self->{writefh}->add($fh);
            return 0;
        } else {
            $self->_push_event({ type => 'error', error => $!, 
                fh => $fh });
        }
        return undef;

    } elsif ($rv < 0) {
        $self->_push_event({ type => 'error', error => $!, 
            fh => $fh });
        return undef;

    } elsif ($rv < length $data) {
        # only part of the data was sent
        $meta->{outbuffer} = substr $data, $rv;
        $self->{writefh}->add($fh);
        
    } else {
        # all pending data was sent
        $self->{writefh}->remove($fh);
    }

    if($rv and !$self->{fhs}{$fh}{connected}) {
        $self->{fhs}{$fh}{connected} = 1;
        $self->_push_event({ type => 'connected', fh => $fh });
    }

    return $rv;
}

sub _my_send {
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

sub _push_event {
    push @{$_[0]->{events}}, $_[1];
}

=head2 B<nonblock($socket)> 

Puts socket into nonblocking mode.

=cut

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
sub _read_all {
    my ($self, $fh) = @_;
    my $cfg = $self->{fhs}{$fh};

    my $canread = 1;
    my $eventcount = int(@{$self->{events}}); 
    EVENT: while (int(@{$self->{events}}) > $eventcount or $canread) {
        my ($sender);
        
        READ: while($canread) {
            my ($data, $rv) = ('');
            if (UNIVERSAL::can($fh, "recv") and !$fh->isa("IO::Socket::SSL")) {
                $rv = $fh->recv($data, $cfg->{read_size}, 0);
                $sender = $rv if defined $rv && $rv ne "";
            } else {
                $rv = sysread $fh, $data, $cfg->{read_size};
            }

            if (not defined $rv) {
                if ($! != POSIX::EWOULDBLOCK) {
                    $self->_push_event({ type => 'error', error => $!, 
                            fh => $fh });
                }
                $canread = 0;
                last READ;
            }

            if (length $data == 0 and $cfg->{type} eq "stream") {
                # client disconnected
                $self->disconnect($fh, 1);
                $canread = 0;
                last READ;
            }

            $cfg->{inbuffer} .= $data;
            
            # For dgram it's one read at a time.
            if($cfg->{type} eq "dgram") { last READ; }

            if($self->{prioritytype}[0] eq 'FairByRead') {
                $canread = 0;
                last READ;
            
            } elsif ($self->{prioritytype}[0] eq 'FairByEvent') {
                last READ;
            }
        }

        # No data on socket, break out of loop. 
        if(not defined $cfg->{inbuffer}) {
            last;
        }
        
        my ($buffertype, @args) = @{$cfg->{buffered}};
        
        my %event = (type => 'read', fh => $fh);
        $event{'sender'} = $sender if defined $sender;

        if($buffertype eq 'Size') {
            my ($pattern, $offset) = (@args, 0); # Defaults to 0 if no offset
            my $length = 
                (unpack($pattern, $cfg->{inbuffer}))[0];
            
            my $datastart = length(pack($pattern, $length));

            while($length <= length($cfg->{inbuffer})) {
                my %copy = %event;
                $copy{'data'} = substr($cfg->{inbuffer},
                    $datastart, $length+$offset);
                substr($cfg->{inbuffer}, $datastart, $length+$offset) = '';
                $self->_push_event(\%copy);
            }
            
        } elsif($buffertype eq 'FixedSize') {
            my ($length) = (@args);
            
            while($length <= length($cfg->{inbuffer})) {
                my %copy = %event;
                $copy{'data'} = substr($cfg->{inbuffer}, 0, $length);
                substr($cfg->{inbuffer}, 0, $length) = '';
                $self->_push_event(\%copy);
            }

        } elsif($buffertype eq 'Split') {
            my ($regexp) = (@args);

            while ($cfg->{inbuffer} =~ s/(.*)$regexp//) {
                if($1 ne '') {
                    my %copy = %event;
                    $copy{'data'} = $1;
                    $self->_push_event(\%copy);
                }
            }

        } elsif($buffertype eq 'Regexp') {
            my ($regexp) = (@args);

            while ($cfg->{inbuffer} =~ s/$regexp//) {
                if($1 ne '') {
                    my %copy = %event;
                    $copy{'data'} = $1;
                    $self->_push_event(\%copy);
                }
            }

        } elsif($buffertype eq 'Disconnect') {
        
        } elsif($buffertype eq 'None') {
            $event{'data'} = $cfg->{inbuffer};
            $cfg->{inbuffer} = '';
            $self->_push_event(\%event);
        
        } else {
            die("Unknown Buffered type: $buffertype");
        }
        
        # Return the last bit of buffer to the user when we get a disconnect.
        if($cfg->{disconnecting} and defined $cfg->{inbuffer} 
                and length($cfg->{inbuffer}) > 0) {
            if($cfg->{return_last}) {
                $self->_push_event({ type => 'read', fh => $fh, 
                    data => $cfg->{inbuffer}});
            } else {
                $self->_push_event({ type => 'read_last', fh => $fh, 
                    data => $cfg->{inbuffer}});
            }
            $cfg->{inbuffer} = '';
        } 
        
        if ($self->{prioritytype}[0] eq 'FairByEvent' 
            and int(@{$self->{events}}) > $eventcount) {
            last EVENT;
        }

        $eventcount = int(@{$self->{events}});
    }
}

1;

=head1 AUTHOR

Jonas Jensen <jonas@infopro.dk>, Troels Liebe Bentsen <troels@infopro.dk>

=cut

# vim: et sw=4 sts=4 tw=80
