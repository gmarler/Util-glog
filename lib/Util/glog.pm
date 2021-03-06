use strict;
use warnings;

package Util::glog;

# ABSTRACT: Generic logging utility
# VERSION
#
use Moose;
use Moose::Util::TypeConstraints;
with 'MooseX::Log::Log4perl';
use namespace::autoclean;

use Log::Log4perl               qw(:easy);
use File::Basename              qw();
use IO::Handle                  qw();
use IO::Dir                     qw();
use File::Spec                  qw();
use DateTime                    qw();
use DateTime::Format::Duration  qw();
use POSIX::RT::Timer            qw();
use IO::Compress::Bzip2         qw($Bzip2Error);
use Socket                      qw(PF_UNSPEC SOCK_STREAM AF_UNIX);
use POSIX;
use Carp;

# The absolute output path for the logfile in question
has output_path  => ( is => 'ro', isa => 'Str', );
# The directory for the logfile in question
has logdir       => ( is => 'ro', isa => 'Str', builder => '_build_logdir',
                                                lazy => 1);
# The basename of the logfile in question
has logfile_base => ( is => 'ro', isa => 'Str', builder => '_build_logfile_base',
                                                lazy => 1);
# The actual absolute pathname (with datestamp appended) for the logfile
has logfile      => ( is => 'rw', isa => 'Str', );
# The filehandle matching the 'logfile' attribute
has logfile_fh   => ( is => 'rw', isa => 'IO::File', );

# If true, this actually indicates line buffered, rather than absolutely
# no buffering, as in each character is a separate write() syscall.
has unbuffered   => ( is => 'ro', isa => 'Bool', default  => 0, );
# Is the log file compressed as it is written?  If not, it will be compressed
# only after the file is closed
has compress     => ( is => 'ro', isa => 'Bool', default  => 1, );
# Max number of logfiles to retain
has max          => ( is => 'ro', isa => 'Num',  default  => 7, );

# Received rotate "signal"/command
has received_rotate => ( is => 'rw', isa => 'Bool', default  => 0, );
has received_signal => ( is => 'rw', isa => 'Bool', default  => 0, );
has _expiration     => ( is => 'rw', isa => 'Num',
                         default   =>
                         sub {
                           my ($self) = shift;
                           $self->_refresh_expiration();
                         }  );
has _worker_pid     => ( is => 'rw', isa => 'Num' );
has _Parent         => ( is => 'rw', isa => 'IO::Handle' );
has _Worker         => ( is => 'rw', isa => 'IO::Handle' );

# Statistics
has _bytes_in       => ( is => 'rw', isa => 'Num', default => 0, );
has _bytes_comp     => ( is => 'rw', isa => 'Num', default => 0, );

=for Pod::Coverage AF_UNIX BUILD DEMOLISH PF_UNSPEC

=head2 METHODS

=cut

sub BUILD {
  my ($self) = shift;

  $self->_setup_signal_handlers();
  # TODO: Set the logfile name, and create the actual file handle, thus
  # initializing logfile and logfile_fh
  $self->set_logfile();
}

sub _build_logdir {
  my ($self) = shift;

  my $output_path = $self->output_path;
  my $dir         = File::Basename::dirname($output_path);
}

sub _build_logfile_base {
  my ($self) = shift;

  my $output_path = $self->output_path;
  my $basename    = File::Basename::basename($output_path);
}

=head2 set_logfile

This method determines the file log name, depending on whether things like
compression are enabled, stores that attribute, and also opens the logfile
filehandle and squirrels that away as well.

=cut

# We don't use a builder for the logfile attribute because it can change at any
# time.  We do however need a method to do the building because we always need
# to append a datestamp to it before it gets created.
sub set_logfile {
  my ($self) = shift;
  my ($log)  = $self->logger;
  my ($suffix,$ts,$fh,$fname);

  #if ($self->logfile) {
  #  $log->debug("Abandoning logfile: " . $self->logfile);
  #}

  # Always close the filehandle, if it's open
  if ($fh = $self->logfile_fh) {
    $fh->close;
  }

  # Get the timestamp to append to the name, make sure it's in the current TZ
  # for the host this is running on.
  $ts = $self->_generic_ts();

  if ($self->compress) {
    $suffix = "-${ts}.bz2";
  } else {
    $suffix = "-${ts}";
  }
  $fname = File::Spec->catfile($self->logdir,$self->logfile_base . ${suffix});

  $self->logfile($fname);

  $fh = IO::File->new("$fname",">>") or 
    $log->logdie("Unable to open $fname");

  # NOTE: Move into forked worker PID when we go back to that model
  if ($self->compress) {
    my $zh = IO::Compress::Bzip2->new($fh, Append => 1, AutoClose => 1,
                                           BlockSize100K => 9, );
    $self->logfile_fh($zh);
  } else {
    $self->logfile_fh($fh);
  }
}

sub _generic_ts {
  my ($self) = @_;

  my (@ts) = localtime(time);
  return sprintf("%4d%02d%02d",$ts[5]+1900,$ts[4]+1,$ts[3]);
}

=head2 process_stdin

Once called, this method will read STDIN and log it to a file as specified by
the object's configuration.  Several situation will cause execution to fall out
of this method, and they all end up closing the log file.

=cut

sub process_stdin {
  my ($self) = @_;

  my ($l)    = $self->logger;
  my $stdin_fh = IO::Handle->new();
  if ($stdin_fh->fdopen(fileno(STDIN),"r")) {
    $l->debug("Converted STDIN into an IO::Handle");
  } else {
    $l->logdie("Unable to convert STDIN into an IO::Handle");
  }
  my $log_fh = $self->logfile_fh();

  # $self->_setup_worker_pid();

  # my $Parent   = $self->_Parent();
  # Set reading from Worker to be non-blocking
  # $Parent->blocking( 0 ) or carp("Unable to set non-blocking");

  # One shot timer till the first rotation
  $l->debug("Setting timer to rotate log for " . $self->_expiration .
            " seconds from now");
  my $t = POSIX::RT::Timer->new( value => $self->_expiration,
                                 interval => 0, signal => SIGRTMIN   );

  # Start the logging...
  while (my $line = $stdin_fh->getline()) {
    #my $cbuf;                   # Compressed buffer read from worker
    #my $bytes_before_compress =
    #   length($line);           # Bytes before compression
    #my $bytes_after_compress;   # Bytes after  compression
    #$Parent->print("$line");    # Into Worker

    $log_fh->print($line);

    # Handle signal indicating to rotate log files when received
    if ($self->received_rotate) {

      $self->received_rotate(0);

      # Sometimes, there is clock drift in the timer - we may need to wait a few
      # secs (+1 to be safe) before the actual rotation
      my $secs_till_midnight = $self->_refresh_expiration() + 1;
      my $secs_to_delay;

      # Since we might have a bit of clock drift, we might have crossed
      # over into the next day, and thus we're getting the number of seconds until
      # the *NEXT* midnight.
      # So, if $secs_till_midnight is > 30, then we need to say that there are
      # 0 seconds left, so we don't wait on the midnight that has just passed
      # to arrive
      # Otherwise, we need to wait for midnight to arrive, which should only
      # be a few seconds
      if ($secs_till_midnight > 30) {
        $secs_to_delay = 0;
      } else {
        $secs_to_delay = $secs_till_midnight;
      }

      $l->info("Rotating Log");

      # Wait $secs_to_delay, then rotate the log (and re-refresh the expiration)
      if ($secs_to_delay) {
        $l->debug("Sleeping $secs_to_delay before log rotation, due to timer drift");
        sleep($secs_to_delay);
      }

      # Rotate Log in parent process
      $self->rotate_log();

      # Now that we have a new filehandle open, refresh the cached copy we have
      $log_fh = $self->logfile_fh();

      # Re-refresh the expiration time, just to make sure we're timing to the
      # *next* midnight
      $secs_till_midnight = $self->_refresh_expiration();

      # Set up the next expiration of the rotation timer
      $l->info("Expiration refreshed to " . $self->_expiration . " seconds");
      # TODO: $t must be in scope or the Timer won't fire???
      $t = POSIX::RT::Timer->new( value => $self->_expiration,
                                  interval => 0, signal => SIGRTMIN   );
    }
    # Handle signal indicating termination is needed
    if ($self->received_signal) {
      $l->info("Received a termination signal of some kind");
      $self->received_signal(0);

###      # Send Termination signal to child
###      my $child_pid = $self->_worker_pid();
###      $l->debug("Sending 'TERM' signal to child $child_pid");
###      kill 'TERM', $child_pid;
###      while ($bytes_after_compress = $Parent->read($cbuf,1024)) {
###        $self->_bytes_comp( $self->_bytes_comp() + $bytes_after_compress );
###        $log_fh->print($cbuf);
###      }
###      # Wait for child
###      $l->debug("Waiting for child");
###      my $kid = waitpid($child_pid, 0);
###      if ($kid == $child_pid) {
###        $l->debug("Wait for child SUCCESSFUL");
###        $self->_worker_pid(0);
###      }
      # $Parent->autoflush(1);
      last;
    }
  }

  # If we fell out of the loop above, we now need to:
  # 1. Close the pipe from the incoming data flow
  $stdin_fh->close();
  # 2. Shutdown writing to worker process by sending EOF.
  #    Then read the last from the worker process.
  #    It will exit, so make sure to also reap its exit value
  # TODO: Make sure it's still alive first, if not, don't bother with this
  ### my ($final_cbuf);
  ### shutdown($Parent,1);  # No more writing
  ### # Set reading from Worker back to blocking
  ### $Parent->blocking( 1 ) or carp("Unable to set back to blocking");
  ### while ($Parent->read($final_cbuf,1024)) {
  ###   $log_fh->print($final_cbuf);
  ### }
  ### $l->debug("Waiting for WORKER PID to finish");
  ### my $wp_pid = waitpid($self->_worker_pid(), 0);
  ### if ($wp_pid == $self->_worker_pid()) {
  ###   $l->debug("Worker PID $wp_pid exited with status: " . $?);
  ###   $self->_worker_pid(0);  # For the benefit of DEMOLISH()
  ### } else {
  ###   $l->warn("waitpid on Worker PID returned $wp_pid");
  ### }
  ### # Do the final close on the Unix Domain Socket
  ### shutdown($Parent,0);  # No more reading
  ### $Parent->close();
  # 3. Flush and close the final log file
  $log_fh->flush();
  $log_fh->close();
}

=head2 rotate_log

Method which rotates the log file, and also expires/deletes log files that are
too high in count.

=cut

sub rotate_log {
  my ($self) = @_;
  my ($log)  = $self->logger;
  my ($logdir_dh,@all_logfiles,@found_logfiles,@logfiles_to_delete,
      @logfiles_to_retain);

  # Set new logfile
  $self->set_logfile();

  # Determine if oldest log files must be deleted or not
  # NOTE: This is a simple minded test, based on a few assumptions:
  # 1. The 'max' attribute determines how many of an individual file basename to
  #    keep around - any more than this simple count get discarded
  # 2. Since the datestamp is implicitly part of the filename, we can sort
  #    the list of files based on the datestamp alone, and discard only the ones
  #    after the index we're limiting the file count to
  #
  # It may turn out some day that we want to be more sophisticated than this,
  # and actually look at information in the file inodes, but I doubt it.
  #
  $logdir_dh = IO::Dir->new($self->logdir) or
    $log->logdie( "unable to open dir " . $self->logdir );

  while (defined(my $f_found = $logdir_dh->read)) {
    $f_found =~ /^(\.|\.\.)$/ and next;
    push @all_logfiles, $f_found;
  }
  $logdir_dh->close;

  # Match only files found that match our logfile names
  my $fname_to_match = $self->logfile_base . "-";
  my $lf_re = qr/${fname_to_match}\d{8}(?:\.bz2)?$/;
  @found_logfiles = grep { $_ =~ $lf_re; } @all_logfiles;
  #$log->debug(join "\n", @found_logfiles);

  @logfiles_to_delete = sort { (my $adate = $a) =~ m/-(\d{8}+)(?:\.bz2)?/;
                               (my $bdate = $b) =~ m/-(\d{8}+)(?:\.bz2)?/;
                               $bdate cmp $adate; } @found_logfiles;
  #$log->debug("Sorted before logfiles to delete:\n" . join "\n", @logfiles_to_delete);
  @logfiles_to_retain = splice @logfiles_to_delete, 0, $self->max;
  #$log->debug("Logfiles to keep\n" . join "\n", @logfiles_to_retain);
  #$log->debug("Logfiles to delete:\n" . join "\n", @logfiles_to_delete);
  @logfiles_to_delete = map { my $abs_logfile = File::Spec->catfile($self->logdir, $_);
                                 $abs_logfile; }
                         @logfiles_to_delete;
  #$log->debug("Absolute Logfiles to delete:\n" . join "\n", @logfiles_to_delete);
  if (@logfiles_to_delete) {
    $log->debug("LOG ROTATION: " . scalar(@logfiles_to_delete) .
                " logfiles to delete");
  } else {
    $log->debug("LOG ROTATION: No logfiles to delete");
  }
  foreach my $file (@logfiles_to_delete) {
    if ( -e $file ) {
      unlink($file) or $log->error("Unable to remove $file: $!");
    } else {
      $log->error( "$file doesn't seem to exist, so can't remove it" );
    }
  }
}

# Signal Handlers
# Capture RTMIN signal and rotate log files appropriately
sub _setup_signal_handlers {
  my ($self) = shift;

  eval {
    #$SIGRT{SIGRTMIN} = sub { print "SIGRTMIN!\n"; $self->received_rotate(1); };
    $SIGRT{SIGRTMIN} = sub {  $self->received_rotate(1); };
    # Setup signals that would normally cause immediate termination, and
    # corruption of bzip2 archives otherwise
    for my $sig (qw(TERM HUP INT QUIT PIPE)) {
      $SIG{$sig} = sub {  my $sig = shift; print "Received $sig\n";
                          $self->received_signal(1); };
    }
    $SIG{'USR1'} = sub {
      my $sig = shift; print "Received $sig\n";
      my $pct_reduced = (1.0 - ( $self->_bytes_comp() / $self->_bytes_in() )
                        ) * 100.0;
      my $stats = sprintf("STATISTICS\n" . "=" x 36 .
                          "\nBYTES RECEIVED: %20d\n" .
                          "COMPRESSED TO:  %20d\n" . 
                          "PERCENT REDUCED:              %6.2f\n",
                          $self->_bytes_in(), $self->_bytes_comp(),
                          $pct_reduced);
      print $stats;
    };
  }
}

sub _refresh_expiration {
  my ($self) = shift;
  my ($l) = $self->logger;

  #$l->debug("Now in _refresh_expiration");

  # Have to use local time zone, or the midnight calculations won't come out as
  # we expect.  In particular don't use the floating or GMT time zones, unless
  # you want all hosts to think of midnight as offset from GMT.
  my $localTZ = DateTime::TimeZone->new( name => 'local' );
  #$l->debug("Time Zone is: " . $localTZ->name() );

  # Get current time, truncate to seconds because we don't care about nanosecs
  # in this case
  my $now = DateTime->now( time_zone => $localTZ )
                    ->truncate( to => 'second' );
  $l->debug("Now: " . $now->strftime("%D %T") );

  # Get next day
  my $tomorrow = $now->clone->add( days => 1 );
  $l->debug("TOMORROW: " . $tomorrow->strftime("%D %T") );
  # Now set to midnight of that day
  my $midnight = $tomorrow->clone()->set( hour   => 0,
                                          minute => 0,
                                          second => 0,
                                        );

  $l->debug("MIDNIGHT " . $midnight->strftime("%D %T") );

  # Get the duration from now till midnight
  my $dur = $midnight->subtract_datetime_absolute($now);

  # Print the Duration in seconds
  my $fmt_secs = DateTime::Format::Duration->new( pattern => '%S' );
  my $fmt_full = DateTime::Format::Duration->new( pattern   => '%e days, %r',
                                                  normalize => 1,
                                                );

  my $secs_till_midnight = $fmt_secs->format_duration( $dur );
  my $time_till_midnight = $fmt_full->format_duration( $dur );

  $l->debug("SECONDS till midnight: $secs_till_midnight");
  $l->debug("NORMALIZED TIME till midnight: $time_till_midnight");

  $self->_expiration($secs_till_midnight);

  return $secs_till_midnight;
}

=head2 _worker_pid_task

=cut

sub _worker_pid_task {
  my ($self) = @_;
  my ($l)    = Log::Log4perl->get_logger();
  my ($buf);

  $l->debug("Worker child PID started");
  my $Worker = $self->_Worker();

  # TODO: Treat EOF at the end of a day (log rotation event) differently than
  #       the termination of the parent and this child

  # Read socket for data from parent, and filter through
  # IO::Compress::Bzip2
  my $zh = IO::Compress::Bzip2->new($Worker, BlockSize100K => 9, );

  while (my $byte_count = $Worker->read($buf,1024)) {
    if ($Worker->eof()) {
      $l->debug("WORKER sees EOF");
    }
    $zh->print($buf);
  }
  # If we get here, we've been terminated
  $zh->flush();
  $zh->close();
  $Worker->flush();
  #$Worker->close();
  shutdown($Worker, 1); # No more writing
  exit(0);
}


sub _setup_worker_pid {
  my ($self) = @_;
  my ($l)    = $self->logger;
  my $pid;
  # Parent side of socket
  my $Parent = IO::Handle->new();
  # Worker side of socket
  my $Worker = IO::Handle->new();

  $l->debug("Setting up for WORKER PID");

  socketpair($Parent, $Worker, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or
    croak("socketpair: $!");

  $self->_Parent($Parent);
  $self->_Worker($Worker);

  if ($pid = fork()) {
    # parent
    $Worker->close();
    $self->_worker_pid($pid);
    return 1;
  } elsif (defined $pid) {
    #child
    eval {
      # Setup signals that would normally cause immediate termination, and
      # corruption of bzip2 archives otherwise
      for my $sig (qw(TERM)) {
        $SIG{$sig} = sub {  my $sig = shift; print "WORKER PID Received $sig\n";
                            $self->received_signal(1); };
      }
      for my $sig (qw(HUP PIPE INT)) {
        $SIG{$sig} = sub {  my $sig = shift; print "WORKER PID Received $sig\n";
                            exit(0); };
      }
    };
    $Parent->close();
    $self->_worker_pid_task();
    # We better never get here
    return;
  } else {
    croak("Can't fork: $!");
  }
}


sub DEMOLISH {
  my $self = shift;

  my ($worker_pid) = $self->_worker_pid();

  # Only do this for the parent PID
  if ($worker_pid) {
    #my ($l)  = $self->logger;
    #$l->warn("DEMOLISH: Worker PID is still running");
    carp("DEMOLISH: Worker PID is still running");
  }
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;
