use strict;
use warnings;

use IO::Socket::INET;
use IO::Select;
use Socket;
use Data::Dumper;
use Fcntl qw(:mode);

# http://svn.linuxvirtualserver.org/repos/tcpsp/

# TODO: Use in IO::EventMux
# S_IFREG S_IFDIR S_IFLNK S_IFBLK S_IFCHR S_IFIFO S_IFSOCK S_IFWHT S_ENFMT

use POSIX qw(uname);
use Config;

our $SYS_splice;
our $SYS_tee;
our $SYS_vmsplice;

our $SYS_SPLICE_F_MOVE     = 0x01;
our $SYS_SPLICE_F_NONBLOCK = 0x02;
our $SYS_SPLICE_F_MORE     = 0x04;
our $SYS_SPLICE_F_GIFT     = 0x08;
our $SYS_SPLICE_F_UNMAP    = 0x10;

our $SYS_SPLICE_SIZE       = (64*1024);

# Syscall list: linux-2.6/arch/x86/kernel/syscall_table_32.S

if($^O eq 'linux') {
    my ($sysname, $nodename, $release, $version, $machine) = 
        POSIX::uname();
    
    # if we're running on an x86_64 kernel, but a 32-bit process,
    # we need to use the i386 syscall numbers.
    if ($machine eq "x86_64" && $Config{ptrsize} == 4) {
        $machine = "i386";
    }

    if ($machine =~ m/^i[3456]86$/) {
        $SYS_splice = 313;
        $SYS_tee = 315;
        $SYS_vmsplice = 316;
    
    } elsif ($machine eq "x86_64") {
        $SYS_splice = 275;
        $SYS_tee = 276;
        $SYS_vmsplice = 278;
    
    } elsif ($machine eq "ppc") {
        $SYS_splice = 283;
        $SYS_tee = 284;
        $SYS_vmsplice = 285;

    } elsif ($machine eq "ia64") {
        $SYS_splice = 1297;
        $SYS_tee = 1301;
        $SYS_vmsplice = 1302;
    
    } else {
        die "Unsupported arch";
    }
}

=item sys_splice($fd_in, $off_in, $fd_out, $off_out, $len, $flags)

Direct wrapper for splice system call

=cut

sub sys_splice {
    my ($fd_in, $off_in, $fd_out, $off_out, $len, $flags) = @_;
    syscall($SYS_splice, $fd_in, $off_in, $fd_out, $off_out, $len, $flags);
}


=item sys_tee($fd_in, $fd_out, $len, $flags)

Direct wrapper for tee system call

=cut

sub sys_tee {
    my ($fd_in, $fd_out, $len, $flags) = @_;
    syscall($SYS_tee, $fd_in, $fd_out, $len, $flags);
}

=item sys_vmsplice($fd, $iov, $nr_segs, $flags)

Direct wrapper for vmsplice system call

=cut

sub sys_vmsplice {
    my ($fd, $iov, $nr_segs, $flags) = @_;
    syscall($SYS_vmsplice, $fd, $iov, $nr_segs, $flags);
}

sub vmsplice_buffers {
    my ($fh, @bufs) = @_;
  
    my $vecs;
    foreach my $buf (@bufs) {
       $vecs .= pack('P L', $buf, length($buf));
    }
    dump_hex($vecs);
    use IO::Poll qw(POLLOUT);
    my $poll = new IO::Poll;
    $poll->mask($fh => POLLOUT);
   
    my $nr_segs = int @bufs; 
    # Wait until there is room in output
    $poll->poll();
    #substr($vecs, 0, 4) = 'troels';

    my $written = sys_vmsplice(fileno($fh), $vecs, $nr_segs, 0);
    if($written < 0) {
        die "Could vmsplice: $!";
    }
}


#open my $fh_out, ">", "README.write" or die("Could not open README.write: $!");
#pipe my $pipe_out, my $pipe_in or die ("Could not make pipe: $!");
#vmsplice_buffers($pipe_in, "A0A1A2A3A4A5\n", "A6A7A8A9B0B1\n");

=item splice_cp($fh_in, $fh_out)

Copy the content of one file to another by using the splice syscall

=cut

sub splice_cp {
    my ($fh_in, $fh_out) = @_;
    my @fh_stat = stat $fh_in;
    
    pipe my $pipe_out, my $pipe_in or die ("Could not make pipe: $!");

    while($fh_stat[7]) {
        my $ret = sys_splice(fileno($fh_in), 0, fileno($pipe_in), 0, 
            min($SYS_SPLICE_SIZE, $fh_stat[7]), $SYS_SPLICE_F_MOVE);
       
        if($ret < 0) {
            die "$!";
    
        } elsif(!$ret) {
            last;
        }
    
        while($ret) {
            my $written = sys_splice(fileno($pipe_out), 0, fileno($fh_out), 
                0, $ret, $SYS_SPLICE_F_MOVE);
            if($written < 0) {
                die "$!";
            }
    		$ret -= $written;
        }
    }
}

sub min {
    $_[0] < $_[1] ? $_[0] : $_[1];
}

sub dump_hex {
    my ($str) = @_;
    for(my $i=0; $i < length($str); $i++) {
        my $char = substr($str, $i, 1);
        print(sprintf("%02d: x0%02x(%03d)", 
            $i, ord($char), ord($char))."\n");
    }
}


exit;
#open my $fh_in, "<", "README" or die("Could not open README: $!");
#open my $fh_out, ">", "README.write" or die("Could not open README.write: $!");

#splice_cp($fh_in, $fh_out);

# START

#my $fh = IO::Socket::INET->new(
#    LocalPort    => 10045,
#    LocalAddr    => "127.0.0.1",
#    Proto        => 'tcp',
#    Blocking     => 1,
#    ReuseAddr    => 1,
#    Listen       => 1020, 
#) or die "Could not open socket on (127.0.0.1:10045): $!\n";
#
#my $pid = fork;
#if($pid == 0) {
#    close $fh;
#    my $fh = IO::Socket::INET->new(
#        PeerAddr => '127.0.0.1',
#        PeerPort => 10045,
#        Proto    => 'tcp',
#        Blocking => 1,
#    ) or die "Could not connect to socket on 127.0.0.1:10045 : $!\n";
#    
#    my $buf = ("x" x (1024 * 1024)); # 1MB
#    #my $buf;
#    for(1..1000) {
#        #my $rv = $fh->read($buf, $SYS_SPLICE_SIZE);
#        #print "$buf\n";
#        my $rv = $fh->send($buf);
#        if(defined $rv and $rv > 0) {
#            print "send $rv\n";
#        } else {
#            die "error in send: $!";
#        }
#        #print "$buf\n";
#    }
#
#    exit;
#}
#
#my $newfh = $fh->accept() or die  "Could not accept: $!";
#
#pipe my $pipe_out, my $pipe_in or die ("Could not make pipe: $!");
#
#my $ret = sys_splice(fileno($newfh), 0, fileno($pipe_in), 0, 
#    $SYS_SPLICE_SIZE, 0);
#
#die "$!" if $ret < 0;
#
#
#open my $fh_out, ">", "README.write" or die("Could not open README.write: $!");
#
#$ret = sys_splice(fileno($pipe_out), 0, fileno($fh_out), 0, 
#    $SYS_SPLICE_SIZE, $SYS_SPLICE_F_MOVE);
#die "$!" if $ret < 0;
#
#shutdown $newfh, 2;
#close $newfh;
#
#waitpid($pid, 0);
