use strict;
use warnings;

package Util::glog;

use Moose;
use Moose::Util::TypeConstraints;
with 'MooseX::Log::Log4perl';
use namespace::autoclean;

use Log::Log4perl               qw(:easy);
use File::Basename              qw();
use IO::Dir                     qw();
use File::Spec                  qw();
use DateTime                    qw();
use DateTime::Format::Duration  qw();
use POSIX::RT::Timer            qw();
use IO::Compress::Bzip2         qw($Bzip2Error);
use POSIX;

use threads;
use Thread::Queue;

# Command queue to worker thread
my $command_q  = Thread::Queue->new();
# Completion queue being reported back to parent thread
my $complete_q = Thread::Queue->new();

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
has _my_thread      => ( is => 'rw', isa => 'Any' );



sub BUILD {
  my ($self) = shift;

  $self->_setup_signal_handlers();
  # TODO: Set the logfile name, and create the actual file handle, thus
  # initializing logfile and logfile_fh
  $self->set_logfile();
  $self->_setup_worker_thread();
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
  $ts = $self->generic_ts();

  if ($self->compress) {
    $suffix = "-${ts}.bz2";
  } else {
    $suffix = "-${ts}";
  }
  $fname = File::Spec->catfile($self->logdir,$self->logfile_base . ${suffix});
  #$log->debug("Going to set logfile attribute to: $fname");
 
  $self->logfile($fname);

  $fh = IO::File->new("$fname",">>") or 
    $log->logdie("Unable to open $fname");

  if ($self->compress) {
    my $zh = IO::Compress::Bzip2->new($fh, Append => 1, AutoClose => 1,
                                           BlockSize100K => 9, );
    $self->logfile_fh($zh);
  } else {
    $self->logfile_fh($fh);
  }
}

sub generic_ts {
  my ($self) = @_;

  my (@ts) = localtime(time);
  return sprintf("%4d%02d%02d",$ts[5]+1900,$ts[4]+1,$ts[3]);
}

sub process_stdin {
  my ($self) = @_;

  my $thr = $self->_my_thread();

  my ($l)  = $self->logger;
  my $fh   = $self->logfile_fh();

  # One shot timer till the first rotation
  my $t = POSIX::RT::Timer->new( value => $self->_expiration, interval => 0, signal => SIGRTMIN   );

  # Start the logging...
  while (my $line = <STDIN>) {
    $fh->print("$line");
    # Handle signal indicating to rotate log files when received
    if ($self->received_rotate) {
      $self->received_rotate(0);
      # Sometimes, there is clock drift in the timer - we may need to wait a few
      # secs (+1 to be safe) before the actual rotation
      my $secs_to_delay = $self->_refresh_expiration();

      $l->info("Rotating Log");

      # Wait $secs_to_delay, then rotate the log
      if ($secs_to_delay) {
        $l->debug("Sleeping $secs_to_delay before log rotation, due to timer drift");
        sleep($secs_to_delay);
      }

      # TODO: convert from calling rotate_log directly to sending command to
      #       worker thread
      $self->rotate_log(); 

      $command_q->enqueue( { command => 'ROTATELOG' } );

      # Set up the next expiration of the rotation timer
      $l->info("Expiration refreshed to " . $self->_expiration . " seconds");
      POSIX::RT::Timer->new( value => $self->_expiration, interval => 0, signal => SIGRTMIN   );
    }
    # Handle signal indicating termination is needed
    if ($self->received_signal) {
      $l->info("Received a termination signal of some kind");
      $self->received_signal(0);
      # finish with the log file we're currently working on
      $command_q->enqueue( { command => 'QUIT' } );
      # Join with the now finished compression thread
      $l->debug("Waiting to 'join' the worker thread");
      my @ReturnData = $thr->join();
      last;
    }
  }

  # Appears to be needed for Bzip2 compressed files
  # TODO: Move to worker thread
  $self->logfile_fh->flush();
  $self->logfile_fh->close();
}

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
  @logfiles_to_delete = map { $_ = File::Spec->catfile($self->logdir, $_); }
                         @logfiles_to_delete;
  #$log->debug("Absolute Logfiles to delete:\n" . join "\n", @logfiles_to_delete);
  foreach my $file (@logfiles_to_delete) {
    if ( -e $file ) {
      unlink($file) or $log->logdie("Unable to remove $file");
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

  # Since we might have a bit of clock drift, make sure we return any seconds
  # till midnight if they're greater than 0 and < 60
  if ($secs_till_midnight < 60) {
    return $secs_till_midnight;
  } else {
    return 0;
  }
}

=head2 _worker_thread

Supported commands:

=over 4

=item CREATELOG

=item WRITELOG

=item ROTATELOG

=item CLOSELOG

=item COMPRESSLOG

=item QUIT

=back

=cut

sub _worker_thread {
  my ($self) = @_;
  my ($l)    = $self->logger;

  # Clear my_thread, as we won't be using it here, only in the parent thread,
  # and we don't want our DEMOLISH to be trying to join a non-existent thread,
  # or OURSELVES!
  $self->_my_thread(undef);

  $l->debug("Worker thread started");

  # TODO: Print information about the glog object we've just received by
  #       creating this thread - to make sure the attributes are set as we expect
  $l->debug("Current child thread object attributes:");
  $l->debug("OUTPUT PATH:  " . $self->output_path );
  $l->debug("LOGDIR:       " . $self->logdir );
  $l->debug("LOGFILE_BASE: " . $self->logfile_base );
  $l->debug("LOGFILE:      " . $self->logfile );
  $l->debug("LOGFILE_FH:   " . $self->logfile_fh );
  $l->debug("UNBUFFERED:   " . $self->unbuffered );
  $l->debug("COMPRESS:     " . $self->compress );
  $l->debug("MAX:          " . $self->max );

  # Wait for commands to come in
  while (defined(my $item = $command_q->dequeue())) {
    my $cmd = $item->{command};
    if ($cmd eq 'QUIT') {
      # TODO: close up file and exit thread
      $l->debug("Worker thread received $cmd command");
      $l->debug("Worker thread exiting");
      return 1;
    } elsif ($cmd eq 'ROTATELOG') {
      $l->debug("Worker thread received $cmd command");
    }
  }
}

sub _setup_worker_thread {
  my ($self) = @_;
  my ($l)    = $self->logger;

  $l->debug("Setting up for WORKER THREAD");

  my $thr = threads->create(\&_worker_thread,$self);
#my $thr = threads->create(\&_worker_thread);

  $self->_my_thread($thr);
}


sub DEMOLISH {
  my $self = shift;
  my ($l)    = $self->logger;

  my ($thr) = $self->_my_thread();

  if (defined($thr) && $thr->is_running()) {
    $l->warn("DEMOLISH: Thread is still running");
    # finish with the log file we're currently working on to prevent corruption
    $command_q->enqueue( { command => 'QUIT' } );
    while ($thr->is_running()) {
      sleep(1);
    }
    if ($thr->is_joinable()) {
      # Join with the now finished compression thread
      $l->debug("Waiting to 'join' the worker thread");
      my @ReturnData = $thr->join();
      $l->debug(@ReturnData);
      if (my $err = $thr->error()) {
        $l->error("Thread error: $err");
      }
    } else {
      $l->error("Unable to join worker thread");
    }
  }
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;

