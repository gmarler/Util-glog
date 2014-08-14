package TF::Util::glog;

use Test::MockTime           qw( :all );
use DateTime                 qw();;
use File::Temp               qw();
use File::Spec               qw();
use File::Basename           qw();
use IO::Dir                  qw();
use IO::Handle               qw();
use Digest::SHA1             qw();
use IPC::Run                 qw();
use POSIX::RT::Timer         qw();
use File::MMagic             qw();
use POSIX;
use Socket;
use Carp;

use Test::Class::Moose;
with 'Test::Class::Moose::Role::AutoUse';

# Test Util object we'll be passing around
has 'test_glog' => ( is => 'rw', isa => 'Util::glog' );

sub test_startup {
  my ($test) = shift;
  $test->next::method;

  # Log::Log4perl Configuration in a string ...
  my $conf = q(
    #log4perl.rootLogger          = DEBUG, Logfile, Screen
    log4perl.rootLogger          = DEBUG, Screen
  
    #log4perl.appender.Logfile          = Log::Log4perl::Appender::File
    #log4perl.appender.Logfile.filename = test.log
    #log4perl.appender.Logfile.layout   = Log::Log4perl::Layout::PatternLayout
    #log4perl.appender.Logfile.layout.ConversionPattern = [%r] %F %L %m%n
  
    log4perl.appender.Screen         = Log::Log4perl::Appender::Screen
    log4perl.appender.Screen.stderr  = 0
    log4perl.appender.Screen.layout = Log::Log4perl::Layout::SimpleLayout
  );

  # ... passed as a reference to init()
  Log::Log4perl::init( \$conf );

  # Exract live data tests if LIVE_TEST_DATA env variable exists and is set to a
  # 'truthy' value
  #if ( exists($ENV{'LIVE_TEST_DATA'}) and $ENV{'LIVE_TEST_DATA'} ) {
  #  # TODO: Only proceed if we're running on Solaris 11 or later
  #  diag "LIVE_TEST_DATA is set: testing with live data";
  #} else {
  #  diag "Testing with canned data";
  #  diag "If you want to test with live data, set envvar LIVE_TEST_DATA=1";
  #}
  #$test->test_glog( $test->class_name->new() );
}



#sub test_constructor {
#  my ($test) = shift;
#
#  ok my $glog = $test->test_glog, 'We should have a test object';
#
#  isa_ok($glog, $test->class_name);
##  my $mdb = new_ok("Solaris::mdb" => [],
##                   "Object constructed correctly");
#}

sub test_setup {
  my ($test) = shift;

  # SKIP tests that aren't ready for prime time yet
  my $test_method = $test->test_report->current_method;
  if ( 'test_logfile_rotation_nocompress' eq $test_method->name ) {
    $test->test_skip("Need to complete test implementation");
  }

  my ($l)    = Log::Log4perl->get_logger();

  # Create a temporary directory to store the test logs in
  my $dh = File::Temp->newdir( TEMPLATE => 'glogXXXXX',
                               DIR      => '/tmp',
                             );

  $l->debug("created temp dir " . $dh->dirname);

  $test->{temp_dir} = $dh;
  $test->{logger}   =  $l;
}

sub test_logdir {
  my ($test) = shift;
  my $dh = $test->{temp_dir};

  isa_ok($dh,'File::Temp::Dir');

  # Create a glog object
  my $glog = Util::glog->new( 
               output_path => File::Spec->catfile($dh->dirname, "test.out"),
             );
  isa_ok($glog, $test->class_name());

  # Make sure the logdir attribute came out as expected
  cmp_ok($glog->logdir, 'eq', $dh->dirname, 'logdir attribute set as expected');
  $glog->DESTROY();
}

sub test_logfile_base {
  my ($test) = shift;
  my $dh = $test->{temp_dir};

  isa_ok($dh,'File::Temp::Dir');
  my ($output_path) = File::Spec->catfile($dh->dirname, "test.out");

  # Create a glog object
  my $glog = Util::glog->new( 
               output_path => $output_path,
             );
  isa_ok($glog, $test->class_name());

  # Make sure the logfile_base attribute came out as expected
  cmp_ok($glog->logfile_base, 'eq',
         File::Basename::basename($output_path),
         'logfile_base attribute set as expected');
}

sub test_logfile_creation {
  my ($test) = shift;
  my $dh = $test->{temp_dir};

  isa_ok($dh,'File::Temp::Dir');
  my ($output_path) = File::Spec->catfile($dh->dirname, "test.out");

  # Create a glog object
  my $glog = Util::glog->new( 
               output_path => $output_path,
             );
  isa_ok($glog, $test->class_name());

  # Make sure the logfile attribute came out as expected
  my (@ts) = localtime(time);
  my $dstamp = sprintf("%4d%02d%02d",$ts[5]+1900,$ts[4]+1,$ts[3]);
  my $fname_expected = File::Spec->catfile($dh->dirname,"test.out-" . $dstamp);
  if ($glog->compress) {
    $fname_expected .= ".bz2";
  }
  cmp_ok($glog->logfile, 'eq', $fname_expected, 'logfile attribute set as expected');
  # Make sure the logfile_fh attribute has been set
  isa_ok($glog->logfile_fh, 'IO::File');
}

sub test_logfile_rotation_nocompress {
  my ($test) = shift;
  my $dh = $test->{temp_dir};
  my ($fname_base) = "test.out";
  my (@expected_logfiles, @actual_logfiles);
  my ($tempdir_dh);

  isa_ok($dh,'File::Temp::Dir');
  my ($output_path) = File::Spec->catfile($dh->dirname, $fname_base);
}

sub test_logfile_rotation {
  my ($test) = shift;
  my $dh = $test->{temp_dir};
  my ($fname_base) = "test.out";
  my (@expected_logfiles, @actual_logfiles);
  my ($tempdir_dh);

  isa_ok($dh,'File::Temp::Dir');
  my ($output_path) = File::Spec->catfile($dh->dirname, $fname_base);

  # 1. use Test::MockTime to rotate through one day to make sure file
  #    rotation happens correctly.
  set_absolute_time( "07/15/2014 00:00:00 -0400", "%m/%d/%Y %H:%M:%S %z" );
  # Create the glog object
  my $glog = Util::glog->new( output_path => $output_path,);
  isa_ok($glog, $test->class_name());

  @expected_logfiles =
    map { my $fname = $fname_base . "-$_";
          $fname = $glog->compress ? $fname .= ".bz2" : $fname;
          $fname; }
    qw( 20140715 20140716 20140717 20140718 20140719 );

  # Move ahead a day and rotate the log a few times
  set_absolute_time( "07/16/2014 00:00:00 -0400", "%m/%d/%Y %H:%M:%S %z" );
  $glog->rotate_log();
  set_absolute_time( "07/17/2014 00:00:00 -0400", "%m/%d/%Y %H:%M:%S %z" );
  $glog->rotate_log();
  set_absolute_time( "07/18/2014 00:00:00 -0400", "%m/%d/%Y %H:%M:%S %z" );
  $glog->rotate_log();
  set_absolute_time( "07/19/2014 00:00:00 -0400", "%m/%d/%Y %H:%M:%S %z" );
  $glog->rotate_log();
  # Make sure all of the files exist still
  $tempdir_dh = IO::Dir->new($dh->dirname);
  while (defined(my $f_found = $tempdir_dh->read)) {
    $f_found =~ /^(\.|\.\.)$/ and next;
    push @actual_logfiles, $f_found;
  }
  $tempdir_dh->close;
  eq_or_diff(\@actual_logfiles,\@expected_logfiles,'rotation without deletion');

  # 2. use Test::MockTime to rotate through 8 or more days to make sure file
  #    rotation and elimination work correctly.
  # Does the object have a 'max' attribute?
  can_ok($glog,'max');
  # Confirm that the default max files to retain is 7 (because we didn't specify
  # differently when we created the glog object)
  cmp_ok($glog->max, '==', 7, 'default max files to retain is 7');
  # Rotate a couple more for a total of 8 logs to have been rotated through
  set_absolute_time( "07/20/2014 00:00:00 -0400", "%m/%d/%Y %H:%M:%S %z" );
  $glog->rotate_log();
  set_absolute_time( "07/21/2014 00:00:00 -0400", "%m/%d/%Y %H:%M:%S %z" );
  $glog->rotate_log();
  set_absolute_time( "07/22/2014 00:00:00 -0400", "%m/%d/%Y %H:%M:%S %z" );
  $glog->rotate_log();
  # Now there should only be the most recent 7 still in existence
  @actual_logfiles = ();
  @expected_logfiles =
    map { my $fname = $fname_base . "-$_";
          $fname = $glog->compress ? $fname .= ".bz2" : $fname;
          $fname; }
    qw( 20140716 20140717 20140718 20140719 20140720 20140721 20140722 );
  $tempdir_dh = IO::Dir->new($dh->dirname);
  while (defined(my $f_found = $tempdir_dh->read)) {
    $f_found =~ /^(\.|\.\.)$/ and next;
    push @actual_logfiles, $f_found;
  }
  $tempdir_dh->close;
  eq_or_diff(\@actual_logfiles,\@expected_logfiles,'rotation with deletion');

  restore_time();
}

sub test_process_stdin {
  my ($test) = shift;
  my $dh = $test->{temp_dir};
  my ($fname_base) = "process.out";

  isa_ok($dh,'File::Temp::Dir');
  #$dh->unlink_on_destroy( 0 );
  my ($output_path) = File::Spec->catfile($dh->dirname, $fname_base);

  set_absolute_time( "07/15/2014 23:59:57 -0400", "%m/%d/%Y %H:%M:%S %z" );

  # Create the glog object
  my $glog = Util::glog->new( output_path => $output_path,);
  isa_ok($glog, $test->class_name());

  can_ok($glog, 'process_stdin');

  # Launch an mpstat command and redirect its STDOUT to the STDIN of our
  # object, so we can validate the data is being passed through to the log file
  my $pid;
  my $newstdout    = IO::Handle->new();
  my $psideCapture = IO::Handle->new();
  socketpair($psideCapture, $newstdout, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or
    croak("socketpair: $!");

  {
    # We're going to futz with global STDIN here, so let's make sure we
    # only allow that to survive until after this block, then restore the "true"
    # value
    local *STDIN;

    if ($pid = fork()) {
      # parent
      $newstdout->close();
      my $fn = $psideCapture->fileno();
      open(STDIN, "<&=$fn") or croak("redirect stdin $!");
    } elsif (defined $pid) {
      #child
      $psideCapture->close();
      my $fn = $newstdout->fileno();
      open(STDOUT, ">&=$fn") or croak("redirect stdout: $!");
      exec("/bin/mpstat -Td 1 7") or croak("exec: $!");
      # We better never get here
      return;
    } else {
      croak("Can't fork: $!");
    }
    # TODO: Do we need to make process_stdin() return something meaningful?
    my $retval = $glog->process_stdin();
    diag "Return value from process_stdin() is: $retval";
  }

  # Wait on child PID to finish
  my $kid = waitpid($pid, 0);
  cmp_ok($kid, '==', $pid, "Waited on Child PID successful");

  restore_time();
}
#
#sub test_signals {
#  my ($test) = shift;
#  my $dh = $test->{temp_dir};
#  my ($fname_base) = "signal.out";
#
#  isa_ok($dh,'File::Temp::Dir');
#  # TODO: This should be cleaned up once this test is fully complete
#  # Don't delete the dir upon exit/undef
#  # $dh->unlink_on_destroy( 0 );
#  my ($output_path) = File::Spec->catfile($dh->dirname, $fname_base);
#
#  set_absolute_time( "07/15/2014 00:00:00 -0400", "%m/%d/%Y %H:%M:%S %z" );
#  # Create the glog object
#  my $glog = Util::glog->new( output_path => $output_path,);
#  isa_ok($glog, $test->class_name());
#
#  # Send SIGRTMIN signal, then check that it was recieved/processed
#  kill SIGRTMIN, $$;
#  cmp_ok($glog->received_rotate, '==', 1, 'SIGRTMIN processed correctly');
#  
#  # Fork external process, which we will then absorb data from, and rotate the
#  # file after a few secs, verifying the signal works
#  #set_absolute_time( "07/15/2014 23:59:57 -0400", "%m/%d/%Y %H:%M:%S %z" );
#  #$glog->process_stdin();
# 
#  #sleep 5;
#
#  #kill SIGRTMIN, $$;
#  #cmp_ok($glog->received_rotate, '==', 1, 'Fake Log Rotation');
#
#  #sleep 5;
#  restore_time();
#}

sub test_refresh_expiration {
  my ($test) = shift;
  my $dh = $test->{temp_dir};
  my ($fname_base) = "refresh.out";

  my ($output_path) = File::Spec->catfile($dh->dirname, $fname_base);

  set_absolute_time( "07/15/2014 00:00:00 -0400", "%m/%d/%Y %H:%M:%S %z" );

  # Create the glog object
  my $glog = Util::glog->new( output_path => $output_path,);
  isa_ok($glog, $test->class_name());

  $glog->_refresh_expiration();
  cmp_ok($glog->_expiration, '<=', 24*60*60, "Expiration <= a day");
  cmp_ok($glog->_expiration,  '>', 24*60*60 - 50, "Expiration > day - 10 secs");

  restore_time();
}

#sub test_inline_compress {
#  my ($test) = shift;
#  my $dh = $test->{temp_dir};
#  #$dh->unlink_on_destroy( 0 );
#  my ($fname_base) = "compress.out";
#  my $mm = File::MMagic->new();
#
#  my ($output_path) = File::Spec->catfile($dh->dirname, $fname_base);
#
#  # Create the glog object
#  my $glog = Util::glog->new( output_path => $output_path, compress => 1, );
#  isa_ok($glog, $test->class_name());
#
#  cmp_ok($glog->compress, '==', 1, "Inline compression is on");
#
#  # Launch an mpstat command and redirect its STDOUT to the STDIN of our
#  # object, so we can validate the data is being passed through to the log file
#  my $pid;
#  my $newstdout    = IO::Handle->new();
#  my $psideCapture = IO::Handle->new();
#  socketpair($psideCapture, $newstdout, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or
#    croak("socketpair: $!");
#
#  {
#    # We're going to futz with global STDIN here, so let's make sure we
#    # only allow that to survive until after this block, then restore the "true"
#    # value
#    local *STDIN;
#
#    if ($pid = fork()) {
#      # parent
#      $newstdout->close();
#      my $fn = $psideCapture->fileno();
#      open(STDIN, "<&=$fn") or croak("redirect stdin $!");
#    } elsif (defined $pid) {
#      #child
#      $psideCapture->close();
#      my $fn = $newstdout->fileno();
#      open(STDOUT, ">&=$fn") or croak("redirect stdout: $!");
#      exec("/bin/mpstat -Td 1 2") or croak("exec: $!");
#      # We better never get here
#      return;
#    } else {
#      croak("Can't fork: $!");
#    }
#    my $retval = $glog->process_stdin();
#  }
#
#  # Wait on child PID to finish
#  my $kid = waitpid($pid, 0);
#  cmp_ok($kid, '==', $pid, "Waited on Child PID successful");
#
#  # Have to write a little data to the file before it'll be recognized as the
#  # proper MIME type
#  cmp_ok($mm->checktype_filename($glog->logfile), 'eq',
#         'application/x-bzip2', 'Logfile is BZIP2 compressed');
#}
#
1;

