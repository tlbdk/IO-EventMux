package IO::EventMux;
use strict;
use warnings;

our $VERSION = '1.02';

# FIXME: Rename Socket::MsgHdr to something else so we can publish the new module

=head1 NAME

IO::EventMux - Multiplexer for sockets, pipes and any other types of
filehandles that you can set O_NONBLOCK on and does buffering for the user.

=head1 SYNOPSIS

  use IO::EventMux;

  my $mux = IO::EventMux->new();

  $mux->add($my_fh);

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

use IO::Select;
use IO::Socket;
use Socket;
use Carp qw(carp cluck croak);
use Errno qw(EPROTO ECONNREFUSED ETIMEDOUT EMSGSIZE ECONNREFUSED EHOSTUNREACH 
             ENETUNREACH EACCES EAGAIN ENOTCONN ECONNRESET EWOULDBLOCK);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);

use IO::EventMux::Socket::MsgHdr;
use constant {
    SOL_IP             => 0,
    IP_RECVERR         => 11,
    SO_EE_ORIGIN_NONE  => 0,
    SO_EE_ORIGIN_LOCAL => 1,
    SO_EE_ORIGIN_ICMP  => 2,
    SO_EE_ORIGIN_ICMP6 => 3,
};

=head2 B<new([%options])>

Constructs an IO::EventMux object.

EventMux implements different types of priority queues that determined
how events are returned or written.

=head3 ReadPriorityType

The ReadPriorityType defines how reads should be return with the mux call and
how "fair" it should be. There is currently only 2 ReadPriorityTypes types to
select from and using the default is recommended. 

The default is C<'FairByEvent'>.

=over 2

=item FairByEvent

File handles change turn generating events and gets the minimum of number of 
reads for generating one event, but if the data returned can be used to 
generate more events. All events will be pushed to the queue to be returned 
with the C<mux()> call.

  my $mux = IO::EventMux->new( ReadPriorityType => ['FairByEvent'] );

  or

  my $mux = IO::EventMux->new( ReadPriorityType => ['FairByEvent',
                                                    $reads_pr_turn] );

$reads_pr_turn is the number of reads the file handle gets to generate an event.

Default $reads_pr_turn is 10. -1 for unlimited. 

=item None

Events are generated based on the order the file handles are read, this will 
allow file handles returning allot of events to monopolize the event loop. This
also allow the other end of the file handle to fill the memory of the host as
EventMux will continue reading so long there is data on the file handle.

  my $mux = IO::EventMux->new( ReadPriorityType => ['None'] );

Use this ReadPriorityType with care and only on trusted sources as it's very
easy to exploit.

=back

=cut

sub new {
    my ($class, %opts) = @_;
    
    # TODO: The whole options system is a ugly hack and needs to be fixed but
    # until then this is how we set the defaults.
    if(exists $opts{ReadPriorityType} and @{$opts{ReadPriorityType}} == 1) {
        push(@{$opts{ReadPriorityType}}, 10);
    }

    bless {
        buffered      => ['None'],
        readprioritytype  => (exists $opts{ReadPriorityType} ? 
            $opts{ReadPriorityType} :
            ['FairByEvent', 10]),
        auto_accept   => 1,
        auto_write    => 1,
        auto_read     => 1,
        read_size     => 65536,
        errors        => 0,
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
which is set to the value of $! at the time of the error. Use kill() on the
file handle to make the error be handled like a normal "closed" event.

=item accepted

A new client connected to a listening socket and the connection was accepted by
EventMux. The listening socket file handle is in the 'parent_fh' key.

=item ready 

A file handle is ready to be written to, this can be use full when working with
nonblocking connects so you know when the remote connection accepted the
connection.

=item accepting

A new client is trying to connect to a listening socket, but the user code must
call accept manually.  This only happens when the ManualAccept option is
set.

=item read

A socket has incoming data.  If the socket's Buffered option is set, this
will be what the buffering rule define.

The data is contained in the 'data' key of the event hash.  If recv() 
returned a sender address, it is contained in the 'sender' key and must be 
manually unpacked according to the socket domain, e.g. with 
C<Socket::unpack_sockaddr_in()>.

=item read_last

A socket last data before it was closed did not match the buffering rules, this
can happen with the following buffering types: Size, FixedSize and Regexp. And
is generally an indicator that you received data that you did not expect.

The Buffering types: "Split", "Disconnect" and "None" expects this and will
return a read instead.

The default is not to return read_last, in the sense that "None" is the default 
buffering type.

=item sent

A socket has sent all the data in it's queue with the send call. This however
does not indicate that the data has reached the other end, normally only that
the data has reached the local buffer of the kernel.

=item closing

A file handle was detected to be have been closed by the other end or the file 
handle was set to be closed by the user. So EventMux stooped listening for 
events on this file handle. Event data like 'Meta' is still accessible.

The 'missing' key indicates the amount of data or packets left in the user 
space buffer when the file handle was closed. This does not indicate the amount
of data received by the other end, only that the user space buffer left. 

=item closed

A socket/pipe was disconnected/closed, the file descriptor, all internal 
references, and data store with the file handle was removed.

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
        return;
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
    # FIXME : handle OOB data and exceptions
    my @result = IO::Select->select($self->{readfh}, $self->{writefh},
        [@{$self->{readfh}}, @{$self->{writefh}}],
        (!defined $timeout || $timeout > 0 ? $timeout : 0));

    #use Data::Dumper; print Dumper({readeble => $result[0], writeble =>
    #   $result[1], exception => $result[2]}) if @result > 0;

    if (@result == 0) {
        if ($!) {
            die "Died because of unknown error: $!";
        } elsif ($timeout_fh) {
            return { type => 'timeout', fh => $timeout_fh };
        } else {
            return { type => 'timeout' };
        }
    }

    #print("can_write:",int(@{$result[1]}),"\n");
    #print("can_read:",int(@{$result[0]}),"\n");
    #system("ls -l /proc/$$/fd|wc\n");

    # buffers to flush?, can_write is set.
    for my $fh (@{$result[1]}) {
        $self->push_event($self->socket_errors($fh)) 
            if $self->{fhs}{$fh}{errors}; 
        if(exists $self->{fhs}{$fh}{ready}
            and $self->{fhs}{$fh}{ready} == 0) {
            $self->{fhs}{$fh}{ready} = 1;

            my $packederror = getsockopt($fh, SOL_SOCKET, SO_ERROR);
            if(!defined $packederror) {
                $self->push_event({ type => 'ready', fh => $fh });
            } else {
                my $error = unpack("i", $packederror);
                if($error == 0) {
                    $self->push_event({ type => 'ready', fh => $fh });
                } else {
                    my $str;
                    
                    if($error == ECONNREFUSED) {
                        $str = "Connection refused";
                    } elsif($error == ETIMEDOUT) {
                        $str = "Connection timed out";
                    } elsif($error == ECONNRESET) {
                        $str = "Connection reset by peer";
                    } else {
                        die "Died because of unknown error code: $error";
                    }
                    
                    $self->push_event({ type => 'error',
                        fh => $fh, error => "get_event(can_write):$str",
                        errno => $error,
                    });
                }
            }

        } elsif ($self->{fhs}{$fh}{auto_write}) {
            my $cfg = $self->{fhs}{$fh} or die("Unknown filehandle $fh");

            if ($cfg->{type} eq "dgram") {
                $self->_send_dgram($fh);
            } else {
                $self->_send_stream($fh);
            }

        } else {
            $self->push_event({ type => 'can_write', fh => $fh });
        }
    }

    # incoming data, can_read is set.
    for my $fh (@{$result[0]}) {
        $self->push_event($self->socket_errors($fh)) 
            if $self->{fhs}{$fh}{errors}; 
        delete $self->{fhs}{$fh}{abs_timeout};
        if ($self->{listenfh}{$fh}) {
            # new connection
            if ($self->{auto_accept}) {
                my $client = $fh->accept or next;
                
                my %cred;
                # TODO: Support localhost TCP via: /proc/net/tcp
                if(not defined $self->{fhs}{$fh}{family} 
                        or $self->{fhs}{$fh}{family} eq 'unix') {
                    
                    my $rv = getsockopt($client, SOL_SOCKET, SO_PEERCRED);
                    if(defined $rv) {
                        my ($pid, $uid, $gid) = unpack('LLL', $rv);
                        %cred = (pid => $pid, uid => $uid, gid => $gid);
                        $self->{fhs}{$fh}{family} = 'unix';
                    } else {
                        $self->{fhs}{$fh}{family} = 'unknown';
                    }
                }
                
                $self->push_event({ type => 'accepted', fh => $client,
                        parent_fh => $fh, %cred});
                
                # Add accepted client to IO::EventMux
                $self->add($client, %{$self->{fhs}{$fh}{opts}}, Listen => 0);
                
                # Set ready as we already sent a connect.
                $self->{fhs}{$client}{ready} = 1;
            
            } else {
                $self->push_event({ type => 'accepting', fh => $fh });
            }

        } elsif (!$self->{fhs}{$fh}{auto_read}) {
            $self->push_event({ type => 'can_read', fh => $fh });

        } else {
            $self->_read_all($fh);
        }
    }

    return shift @{$self->{events}};
}

=head2 B<add($handle, [ %options ])>

Add a socket to the internal list of handles being watched.

The optional parameters for the handle will be taken from the IO::EventMux
object if not given here:


=head3 Listen

Defines if this is should be treated as a listening socket, the default is to 
auto detect if the socket is in listening mode or not. I should not be necessary
to set this value.

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
you can have EventMux generate a 'can_read' event for you instead.
    
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

=head3 Errors

By default EventMux will not deal with socket errors on non connected sockets
such as a UDP socket in listening mode or where no peer has been defined. Or
in other words whenever you use C<sendto()> on socket. When enabling error 
handling, EventMux sets the socket to collect errors with the MSG_ERRQUEUE 
option and collect errors with recvmsg() call.

Errors are sent as errors events, eg: 

  $event = {
    data     => 'packet data',
    dst_port => 'destination port',
    from     => 'ip where the error is from',
    errno    => 'error number',
    dst_ip   => 'destination ip',
  }

=head3 Buffered

Can be a number of different buffering types, common for all of them is that
they define when a event should be generated based on when there is enough data
for the buffering type to be satisfied. All buffering types also generate an 
event with the remaining data when there is a disconnect.

As a protection against a hostile remote end filling your memory a $max_read_size
is defined for most of buffering types, this defines the maximum amount of data
to read from a file handle before generating an event.

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

  $mux->add($my_fh, Buffered => ['Size', $template, $offset, $max_read_size]);

$max_read_size is the maximum number of bytes to read from the file handle pr.
event. The default is 1048576 bytes.

If the size read from the template is bigger than $max_read_size an error event
will be generated and only $max_read_size will be read from the socket.

=item FixedSize

Buffering that uses a fixed size to determine when to generate an event.

  $mux->add($my_fh, Buffered => ['FixedSize', $size]);

$size is the number of bytes to buffer.

=item Split

Buffering that uses a regular expressing to determine where to split data into events. 
Only the data is returned not the splitter pattern itself.

  $mux->add($my_fh, Buffered => ['Split', $regexp]);
  
  or 

  $mux->add($my_fh, Buffered => ['Split', $regexp, $max_read_size]);

$regexp is a regular expressing that tells where the split the data.

This also works as line buffering when qr/\n/ is used or for a C string with
qr/\0/.

$max_read_size is the maximum number of bytes to read from the file handle pr.
event. The default is 1048576 bytes. 

If no match has been reach after matching $max_read_size of data from the
buffer a error event will be generated and the $max_read_size of data will be
returned in a data event.

=item Regexp

Buffering that uses a regular expressing to determine when there is enough data
for an event. Only the match defined in the () is returned not the complete regular expressing.
  
  $mux->add($my_fh, Buffered => ['Regexp', $regexp]);

  or 
  
  $mux->add($my_fh, Buffered => ['Regexp', $regexp, $max_read_size]);

$regexp is a regular expressing that tells what data to return.

An example would be qr/^(.+)\n/ that would work as line buffing.

$max_read_size is the maximum number of bytes to read from the file handle pr.
event. The default is 1048576 bytes. 

If no match has been reach after matching $max_read_size of data from the
buffer a error event will be generated and the $max_read_size of data will be
returned in a data event.

=item Disconnect

Buffering that waits for the file handle to be closed or disconnected to 
generate a 'read' event. 

  $mux->add($my_fh, Buffered => ['Disconnect']);
    
  or

  $mux->add($my_fh, Buffered => ['Disconnect', $max_read_size]);

$max_read_size is the maximum number of bytes to read from the file handle pr.
event. The default is 1048576 bytes. 

If more data than $max_read_size if received before the file handle is closed or
disconnected, an error event will be generated and $max_read_size of data will
be returned in a data event.

=item None

Disable Buffering and return data when it's received. This is the default state.

  $mux->add($my_fh, Buffered => ['None']);

  or

  $mux->add($my_fh, Buffered => ['None', $max_read_size]);


$max_read_size is the maximum number of bytes to read from the file handle pr.
event. The default is 1048576 bytes. 

=back

=head3 Meta

An optional scalar piece of metadata for the file handle.  Can be retrieved and
manipulated later with meta()

=cut

sub add {
    my ($self, $fh, %opts) = @_;

    croak "undefined fh given" if !defined $fh;

    $self->{fhs}{$fh}{buffered} = (exists $opts{Buffered} ?
        $opts{Buffered} : $self->{buffered});

    # Set return_last if default for the buffering type.
    if($self->{fhs}{$fh}{buffered}[0] eq 'None' or 
        $self->{fhs}{$fh}{buffered}[0] eq 'Split' or 
        $self->{fhs}{$fh}{buffered}[0] eq 'Disconnect') {
        $self->{fhs}{$fh}{return_last} = 1;
    }

    if ($self->{fhs}{$fh}{buffered}[0] =~ /^Split|Regexp$/) {
        if (@{$self->{fhs}{$fh}{buffered}} < 3) {
            $self->{fhs}{$fh}{max_read_size} = 1048576;
        } else {
            (undef, undef, $self->{fhs}{$fh}{max_read_size}) =
                @{$self->{fhs}{$fh}{buffered}};
        }
    }
    
    $self->{fhs}{$fh}{errors} = (exists $opts{Errors} ?
        $opts{Errors} : $self->{errors});
    
    if($self->{fhs}{$fh}{errors}) {
        # Set socket to recieve errors
        setsockopt($fh, SOL_IP, IP_RECVERR, 1);
    }

    $self->{fhs}{$fh}{auto_accept} = (exists $opts{ManualAccept} ?
        !$opts{ManualAccept} : $self->{auto_accept});

    $self->{fhs}{$fh}{auto_write} = (exists $opts{ManualWrite} ?
        !$opts{ManualWrite} : $self->{auto_write});

    $self->{fhs}{$fh}{auto_read} = (exists $opts{ManualRead} ?
        !$opts{ManualRead} : $self->{auto_read});

    $self->{fhs}{$fh}{read_size} = (exists $opts{ReadSize} ?
        $opts{ReadSize} : $self->{read_size});

    if ($self->{fhs}{$fh}{auto_read} 
        || $self->{fhs}{$fh}{auto_write} || $opts{Listen}) {
        $self->nonblock($fh);
    }
    
    $self->{fhs}{$fh}{meta} = $opts{Meta} if exists $opts{Meta};

    $self->{fhs}{$fh}{type} = 'stream';
    
    $self->{listenfh}{$fh} = 1 if $opts{Listen};

    my $type = getsockopt($fh, SOL_SOCKET, SO_TYPE);
    $type = unpack("S", $type) if defined $type;
    # Check if it's a socket and not a pipe
    if(defined $type) {
        $self->{fhs}{$fh}{class} = 'socket';
       
        # Check if the socket is set to listening
        my $listening = getsockopt($fh, SOL_SOCKET, SO_ACCEPTCONN);
        $listening = unpack("I", $listening) if defined $listening;
        if($listening) {
            $self->{listenfh}{$fh} = 1 if not exists $opts{Listen};
        } 
        
        if($type == SOCK_STREAM) { # type = 1
            # Add to find out when to send ready event.
            if (!exists $self->{listenfh}{$fh}) {
                $self->{writefh}->add($fh);
                $self->{fhs}{$fh}{ready} = 0;
            }
        } elsif($type == SOCK_DGRAM or $type == SOCK_RAW) { # type = 2,3
            $self->{fhs}{$fh}{type} = 'dgram';
            
        } else {
            croak "Unknown socket type: $type";
        }

    } else {
        $self->{fhs}{$fh}{class} = 'other';
        $self->{writefh}->add($fh);
        $self->{fhs}{$fh}{ready} = 0;
    }
    
    $self->{readfh}->add($fh);
    
    $self->{fhs}{$fh}{type} =  $opts{Type} if exists $opts{Type};

    # Save %opts, so we can given the to $fh->accept() children.
    $self->{fhs}{$fh}{opts} = \%opts;
    $self->{fhs}{$fh}{inbuffer} = '';
    
    if($self->{fhs}{$fh}{type} eq 'dgram') {
        @{$self->{fhs}{$fh}{outbuffer}} = ();
    } else {
        $self->{fhs}{$fh}{outbuffer} = '';
    }
}

=head2 B<handles()>

Returns a list of file handles managed by this object.

=cut

sub handles {
    my ($self) = @_;
    return $self->{readfh}->handles;
}

=head2 B<type()>

Returns the socket type for a file handle

=cut

sub type {
    my ($self, $fh) = @_;
    return $self->{fhs}{$fh}{type};
}

=head2 B<class()>

Returns the socket class for a file handle

=cut

sub class {
    my ($self, $fh) = @_;
    return $self->{fhs}{$fh}{class};
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


=head2 B<close($fh)>

Close a file handle. File handles managed by EventMux must be closed through
this method to make sure all resources are freed.

IO::EventMux will delay closing the file handle until the out buffer is empty 
and at the same time stop listening on read event on that socket. This in turn 
will also generate a 'closing' and a 'closed' event.

Note: All meta data associated with the file handle will be kept until the 
final 'closed' event is returned.

=cut

sub close {
    my ($self, $fh) = @_;

    return if $self->{fhs}{$fh}{disconnecting};
    $self->{fhs}{$fh}{disconnecting} = 1;
    
    if(exists $self->{listenfh}{$fh}) {
        delete $self->{listenfh}{$fh};
        $self->push_event({ type => 'closing', fh => $fh });
        
        # wait with the close so a valid file handle can be returned
        push @{$self->{actionq}}, sub {
            $self->push_event({ type => 'closed', fh => $fh });
            $self->_close_fh($fh);
        };
    
    } else {
        $self->_read_all($fh);
        
        if($self->buflen($fh) == 0) {
            $self->{writefh}->remove($fh);
            $self->push_event({ type => 'closing', fh => $fh });
                        
            # wait with the close so a valid file handle can be returned
            push @{$self->{actionq}}, sub {
                $self->kill($fh);
            };
        }
    }
    
    $self->{readfh}->remove($fh);
}

=head2 B<kill($fh)>

Closes a file handle without giving time to finish any outstanding operations. 
Returns a 'closed' event, delete all buffers and does not keep 'Meta' data.

Note: Does not return the 'read_last' event.

=cut

sub kill {
    my ($self, $fh) = @_;

    $self->{readfh}->remove($fh);
    $self->{writefh}->remove($fh);

    $self->push_event({ type => 'closed', fh => $fh, 
            missing => $self->buflen($fh) });
    
    $self->_close_fh($fh);
}

sub _close_fh {
    my ($self, $fh) = @_;

    if ($self->{fhs}{$fh}) {
        delete $self->{fhs}{$fh};
        shutdown $fh, 2;
        CORE::close $fh or warn "closing $fh: $!";
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
    my $meta = $self->{fhs}{$fh} or croak "$fh not handled by EventMux";

    if ($meta->{type} eq "dgram") {
        return $meta->{outbuffer} ? scalar(@{$meta->{outbuffer}}) : 0;
    }

    return $meta->{outbuffer} ? length($meta->{outbuffer}) : 0;
}

=head2 B<send($fh, @data)>

Queues @data to be written to the file handle $fh. Can only be used when ManualWrite is
off (default).

=over

=item If the socket is of Type="stream"

Returns true on success, undef on error. The data is sent when the socket
becomes unblocked and a 'sent' event is posted when all data is sent and the 
buffer is empty. Therefore the socket should not be closed until 
L</B<buflen($fh)>> returns 0 or a sent request has been posted.  

=item If the socket is of Type="dgram"

Each item in @data will be sent as a separate packet.  Returns true on success
and undef on error.

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

    my $cfg = $self->{fhs}{$fh} or return;
    return if $cfg->{disconnecting};

    if (not $cfg->{auto_write}) {
        carp "send() on a ManualWrite file handle";
        return;
    }

    if ($cfg->{type} eq "dgram") {
        push @{$cfg->{outbuffer}}, map { [$_, $to] } @data;
        $self->{writefh}->add($fh);
        return 1;
    
    } else {
        # send pending data before this
        $cfg->{outbuffer} .= join('', @data);
        $self->{writefh}->add($fh);
        return 1;
    }
}

sub _send_dgram {
    my ($self, $fh) = @_;
    my $cfg = $self->{fhs}{$fh} or return;
    
    my $packets_sent = 0;

    while (my $queue_item = shift @{$cfg->{outbuffer}}) {
        my ($data, $to) = @$queue_item;
        my $rv = $self->_my_send($fh, $data, (defined $to ? $to : ()));

        if (!defined $rv) {
            if ($! == EWOULDBLOCK) {
                # retry later
                unshift @{$cfg->{outbuffer}}, $queue_item;
                return $packets_sent;
            
            } elsif($cfg->{errors} and my @events = $self->socket_errors($fh)) {
                unshift @{$cfg->{outbuffer}}, $queue_item;
                push_event(@events);
                next;
            } else {
                die "Died because of unknown error: $!";
            }
            return;

        } elsif ($rv < length $data) {
            die "Incomplete datagram sent (should not happen)";

        } else {
            # all pending data was sent
            $packets_sent++;
        }
    }
    
    
    $self->push_event({type => 'sent', fh => $fh});
    $self->{writefh}->remove($fh);
    
    if($self->{fhs}{$fh}{disconnecting}) {
        $self->push_event({ type => 'closing', fh => $fh });
                        
        # wait with the close so a valid file handle can be returned
        push @{$self->{actionq}}, sub {
            $self->kill($fh);
        };
    }

    return $packets_sent;
}

sub _send_stream {
    my ($self, $fh) = @_;
    my $cfg = $self->{fhs}{$fh} or return;

    if ($cfg->{outbuffer} eq '') {
        # no data to send
        $self->{writefh}->remove($fh);
        return 0;
    }

    my $rv = $self->_my_send($fh, $cfg->{outbuffer});
    
    # Check for undef or -1 as both can be error retvals 
    if (!defined $rv or $rv < 0) {
        if ($! == EWOULDBLOCK or $! == EAGAIN) {
            return;
        
        } else {
            if($! =~ /Bad file descriptor/) {
                #use Data::Dumper; print Dumper($self->{fhs});
                die "Died because IO::Eventmux was passed a: $!";
            } else {
                die "Died because of unknown error: $!";
            }
        }
        
        return;

    } elsif ($rv < length $cfg->{outbuffer}) {
        # only part of the data was sent
        substr($cfg->{outbuffer}, 0, $rv) = '';
        $self->{writefh}->add($fh);
        
    } else {
        # all pending data was sent
        $cfg->{outbuffer} = '';
        $self->push_event({type => 'sent', fh => $fh});
        $self->{writefh}->remove($fh);

        if($self->{fhs}{$fh}{disconnecting}) {
            $self->push_event({ type => 'closing', fh => $fh });
                        
            # wait with the close so a valid file handle can be returned
            push @{$self->{actionq}}, sub {
                $self->kill($fh);
            };
        }
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

# rv can be sender or undef, error is 0 on tcp shutdown
sub _my_read {
    my ($self, $fh, $read_size, $flags) = @_;

    my $rv; my $data; my $error; my $type;
    $! = undef;
    $@ = undef;
    if (UNIVERSAL::can($fh, "recv") and !$fh->isa("IO::Socket::SSL")) {
        $rv = eval { $fh->recv($data, $read_size, ($flags or 0)) };
        $type = 'recv';
    } else {
        $rv = eval { sysread $fh, $data, $read_size };
        $type = 'sysread';
    }
    
    # Check for errors in read
    if($! or $@ or !defined $rv or ($rv =~ /^\d+$/ and $rv <= 0)) { 
        if($! == EWOULDBLOCK) { 
            $error = EWOULDBLOCK;

        # Try to get socket errors if it's a socket we are dealing with.
        } elsif($self->{fhs}{$fh}{class} eq 'socket') {
            my $packederror = getsockopt($fh, SOL_SOCKET, SO_ERROR);
            $error = unpack("i", $packederror) if defined $packederror;
        }
        
        #if(defined $error and $error == 0) {
        #    use Data::Dumper; print Dumper({ 
        #        error => $error, '$!' => $!, '$@' => $@, rv => $rv, 
        #        type => $type, val => ECONNRESET, 
        #    });
        #}

        if(defined $error and $error != 0) {
            # We could get an error from getsockopt
        } elsif($! =~ /Connection refused/) {
            $error = ECONNREFUSED;
        } elsif($! =~ /Connection timed out/) {
            $error = ETIMEDOUT;
        } elsif($! =~ /Connection reset by peer/) {
            $error = ECONNRESET;
        } else {
            $error = 0; 
        }

    } elsif($rv eq "" or $rv =~ /^\d$/) {
        $rv = undef;
    }

    return ($rv, $data, $error);
}



=head2 B<push_event($event)> 

Puts socket into nonblocking mode.

=cut

sub push_event {
    my($self, @events) = @_;
    push @{$_[0]->{events}}, @events;
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

=head2 B<socket_errors($socket)> 

Read "MSG_ERRQUEUE" errors on socket 

=cut

sub socket_errors {
    my ($self, $sock) = @_;
    
    my @results;
    my $msgHdr = new IO::EventMux::Socket::MsgHdr(
        buflen => 512,
        controllen => 256,
        namelen => 16,
    );
    
    # Copy errors to msgHdr
    my $old_errno = $!;
    my $rv = recvmsg($sock, $msgHdr, MSG_ERRQUEUE);
    if(not defined $rv) {
        if($old_errno != $! and $! != EAGAIN) {
            print "error(socket_errors):$!\n";
        }
        return;
    }
    
    # Unpack errors
    my @cmsg = $msgHdr->cmsghdr();
    while (my ($level, $type, $data) = splice(@cmsg, 0, 3)) {
        if($level == SOL_IP and $type == IP_RECVERR) {
            my ($from, $dst_ip, $dst_port, $pkt);

            # struct sock_extended_err from man recvmsg
            my ($ee_errno, $ee_origin, $ee_type, $ee_code, $ee_pad, 
                $ee_info, $ee_data, $ee_other) = unpack("ICCCCIIa*", $data);
            
            if($ee_origin == SO_EE_ORIGIN_NONE) {
                print "error(socket_errors): origin is none??\n";
                next;
            
            } elsif($ee_origin == SO_EE_ORIGIN_LOCAL) {
                $from = 'localhost';

            } elsif($ee_origin == SO_EE_ORIGIN_ICMP) {
                # Get offender ip($from)(the one who sent the ICMP message)
                # and $dst_ip and $dst_port from packet in ICMP packet.
                ($from, $dst_ip, $dst_port) = (
                    inet_ntoa((unpack_sockaddr_in($ee_other))[1]),
                    inet_ntoa((unpack_sockaddr_in($msgHdr->name))[1]),
                    (unpack_sockaddr_in($msgHdr->name))[0]
                );
                
                # Get what's left of the packet
                $pkt = $msgHdr->buf; 
           
            } elsif($ee_origin == SO_EE_ORIGIN_ICMP6) {
                die "IPv6 not supported, patches welcome"; 
            }

            if($ee_errno == ECONNREFUSED) {
                push(@results, {
                    type => 'error',
                    errno => $ee_errno, 
                    from => $from, 
                    dst_ip => $dst_ip,
                    dst_port => $dst_port, 
                    data => $pkt,
                    fh => $sock,
                });
	        } elsif($ee_errno == EMSGSIZE) {
                push(@results, {
                    type => 'error',
                    errno => $ee_errno, 
                    mtu => $ee_info, 
                    fh => $sock,
                });
            } elsif($ee_errno == ETIMEDOUT or $ee_errno == EPROTO 
                    or $ee_errno == EHOSTUNREACH or $ee_errno == ENETUNREACH
                    or $ee_errno == EACCES) {
                push(@results, {
                    type => 'error',
                    fh => $sock,
                    errno => $ee_errno, 
                });
            } else {
                push(@results, {
                    type => 'error',
                    fh => $sock,
                    error => 'unknown ee_errno: $ee_errno',
                    errno => $ee_errno, 
                });
            }
      
        } else {
            print "error(socket_errors): unknown type: $type and/or $level\n";
        }
    }
    return @results;
}

# Keeps reading from a file handle until EWOULDBLOCK is returned
sub _read_all {
    my ($self, $fh) = @_;
    my $cfg = $self->{fhs}{$fh};
    my $canread = -1;
    my $disconnected = 0;

    if($self->{readprioritytype}[0] eq 'FairByEvent') {
        $canread = $self->{readprioritytype}[1]; 
    }

    # Loop while we are generating new events or reading from the file handle
    my $eventcount = int(@{$self->{events}}); 
    EVENT: while (int(@{$self->{events}}) > $eventcount or $canread) {
        my ($sender);

        # $canread is 0 only when we would have blocked or found a disconnect.
        READ: while($canread-- != 0) {
            my $read_size = $cfg->{read_size};
            if ($cfg->{max_read_size}) {
                my $buf_space = $cfg->{max_read_size} - length $cfg->{inbuffer};
                if ($buf_space < $read_size) {
                    $read_size = $buf_space;
                }
                if ($read_size <= 0) {
                    $canread = 0;
                    last READ;
                }
            }

            my ($rv, $data, $error) = $self->_my_read($fh, $read_size, 0);
            if ($error) {
                my $str;
                if ($error == EWOULDBLOCK) {
                    $canread = 0;
                    last READ;
                
                } elsif($error == ECONNREFUSED) {
                    $str = "Connection refused";
                } elsif($error == ETIMEDOUT) {
                    $str = "Connection timed out";
                } elsif($error == ECONNRESET) {
                    $str = "Connection reset by peer";
                } elsif ($! =~ /Bad file descriptor/) {
                    die "Died because IO::EventMux was passed a $!";
                } else {
                    die "Died because of unknown error code: $error, $!";
                }
                    
                $self->push_event({ type => 'error', 
                    error => "read_all:$str", errno => $error,
                    fh => $fh,
                });

                $canread = 0;
                last READ;
            
            } elsif(defined $rv) {
                $sender = $rv;
            }
            
            if (length $data == 0 and $cfg->{type} eq "stream") {
                # client disconnected
                $disconnected = 1;

                $canread = 0;
                last READ;
            }

            $cfg->{inbuffer} .= $data;

            # For dgram it's one read at a time.
            if($cfg->{type} eq "dgram") { 
                $canread = -1; 
                last READ;
            }

            if ($self->{readprioritytype}[0] eq 'FairByEvent') {
                $canread = -1;
                last READ;
            }
        }

        # No data on file handle or buffer, break out of loop. 
        if($cfg->{inbuffer} eq '') {
            last EVENT;
        }

        my ($buffertype, @args) = @{$cfg->{buffered}};

        my %event = (type => 'read', fh => $fh);
        $event{'sender'} = $sender if defined $sender;

        if($buffertype eq 'Size') {
            my ($pattern, $offset) = (@args, 0); # Defaults to 0 if no offset
            # FIXME: Check that we have enough data to do the unpack.
            #        eg. length(pack($pattern, 30 x (1))); # remember to check
            #        for * elements.
            #
            my $length = (unpack($pattern, $cfg->{inbuffer}))[0]+$offset;
            my $datastart = length(pack($pattern, $length));
            # FIXME: We might have a bug here, look in IO::Buffered::Size 
            while($length <= length($cfg->{inbuffer})) {
                my %copy = %event;
                $copy{'data'} = substr($cfg->{inbuffer},
                    $datastart, $length);
                substr($cfg->{inbuffer}, 0, $length+$datastart) = '';
                $self->push_event(\%copy);
                
                if(length $cfg->{inbuffer} > 0) {
                    $length = (unpack($pattern, $cfg->{inbuffer}))[0]+$offset;
                    $datastart = length(pack($pattern, $length));
                }
            }

        } elsif($buffertype eq 'FixedSize') {
            my ($length) = (@args);

            while($length <= length($cfg->{inbuffer})) {
                my %copy = %event;
                $copy{'data'} = substr($cfg->{inbuffer}, 0, $length);
                substr($cfg->{inbuffer}, 0, $length) = '';
                $self->push_event(\%copy);
            }

        } elsif($buffertype eq 'Split') {
            my ($regexp) = (@args);

            while ($cfg->{inbuffer} =~ s/(.*?)$regexp//) {
                if($1 ne '') {
                    my %copy = %event;
                    $copy{'data'} = $1;
                    $self->push_event(\%copy);
                }
            }

        } elsif($buffertype eq 'Regexp') {
            my ($regexp) = (@args);

            while ($cfg->{inbuffer} =~ s/$regexp//) {
                if($1 ne '') {
                    my %copy = %event;
                    $copy{'data'} = $1;
                    $self->push_event(\%copy);
                }
            }
        
        } elsif($buffertype eq 'HTTP') {
            if(exists $cfg->{length}) {
               if(length $cfg->{inbuffer} >= $cfg->{length}) {
                    my %copy = %event;
                    $copy{data} = substr($cfg->{inbuffer}, 0, $cfg->{length});;
                    substr($cfg->{inbuffer}, 0, $cfg->{length}) = '';
                    $self->push_event(\%copy);
               }

            } else {
                my $idx = index($cfg->{inbuffer}, "\r\n\r\n");
            
                # Found what could be a header
                if($idx > 0) {
                    my $header = substr($cfg->{inbuffer}, 0, $idx + 4);;
                    if($header =~ /Content-Length:\s+(\d+)/) {
                        $cfg->{length} = $1 + $idx + 4;
                    } else {
                        my %copy = %event;
                        $copy{data} = $header;
                        substr($cfg->{inbuffer}, 0, $idx + 4) = '';
                        $self->push_event(\%copy);
                    }
                }
            }

        } elsif($buffertype eq 'Disconnect') {

        
        } elsif($buffertype eq 'None') {
            $event{'data'} = $cfg->{inbuffer};
            $cfg->{inbuffer} = '';
            $self->push_event(\%event);

        } else {
            die("Unknown Buffered type: $buffertype");
        }

        if ($self->{readprioritytype}[0] eq 'FairByEvent' 
                and int(@{$self->{events}}) > $eventcount) {
            last EVENT;
        }

        $eventcount = int(@{$self->{events}});
    }

    if ($cfg->{max_read_size}
            and length $cfg->{inbuffer} >= $cfg->{max_read_size}) {
        $self->push_event({ type => 'error', fh => $fh, 
                error => "Buffer size exceeded"});
        $cfg->{return_last} = 0; # last chunk is incomplete
        $disconnected = 1;
    }

    if($disconnected or $self->{fhs}{$fh}{disconnecting}) {
        # Return the last bit of buffer to the user when we get a disconnect.
        if(length($cfg->{inbuffer}) > 0) {
            if($cfg->{return_last}) {
                $self->push_event({ type => 'read', fh => $fh, 
                        data => $cfg->{inbuffer}});
            } else {
                $self->push_event({ type => 'read_last', fh => $fh, 
                        data => $cfg->{inbuffer}});
            }
            $cfg->{inbuffer} = '';
        }

        if($disconnected) {
            $self->push_event({ type => 'closing', fh => $fh });

            # wait with the close so a valid file handle can be returned
            push @{$self->{actionq}}, sub {
                $self->kill($fh);
            };
        }
    }
}

1;

=head1 AUTHOR

Jonas Jensen <jonas@infopro.dk>, Troels Liebe Bentsen <troels@infopro.dk>

=head1 COPYRIGHT AND LICENCE

Copyright 2006-2007: Troels Liebe Bentsen, Jonas Jensen

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

