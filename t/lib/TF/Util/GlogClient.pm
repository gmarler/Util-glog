package TF::Util::GlogClient;

use Log::Log4perl     qw();
use Util::GlogServer  qw();
use Child             qw();

use Test::Class::Moose;
with 'Test::Class::Moose::Role::AutoUse';

# The GlogServer instance
has 'gserver'  => ( is => 'rw', isa => 'Util::GlogServer', );
# The test Unix Socket path the server and client will use
has 'sockpath' => (is => 'rw', isa => 'Str', default => '/tmp/gclient_tdd.sock', );

has 'serverchildren' => (is => 'rw', isa => 'ArrayRef', default => sub { return []; }, );

has 'clientchildren' => (is => 'rw', isa => 'ArrayRef', default => sub { return []; }, );

sub test_startup {
  my ($test) = shift;
  $test->next::method;
  # more startup

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

  # Create a GlogServer instance to test against, sitting on a test socket path
  #my $gserver = Util::GlogServer->new( sockpath => $test->sockpath );
  #$test->gserver( $gserver );

  # fork() off the test GlogServer
  my $child =
    Child->new(
      sub {
        my ($parent) = @_;
        my $gserver = Util::GlogServer->new( sockpath => $test->sockpath );
        my $future = $gserver->run();

        $future->loop->run();
      }
    );
  my $proc = $child->start();
  diag( "PROC is: " . $proc );
  push @{$test->serverchildren}, $proc;
}

sub test_shutdown {
  my $test = shift;
  # more teardown
  $test->next::method;
  # Shut Down the GlogServer
  my $proc = shift @{$test->serverchildren};
  $proc->kill(1);
}

# TODOs:
# - Test when GlogServer isn't running - should fail properly with informative message
# - Handle starting up more than one session that tries to end up at the same file
# - Test binary file type (mpstat -o .. for instance)
# - Binary file type transition at midnight
# - Text file type transition at midnight

sub test_server_is_ok {
  my $test = shift;

  #isa_ok($test->gserver, 'Util::GlogServer');
  # It'll take a second or two before the socket is created
  sleep(1);
  is( -S $test->sockpath, 1, "Test Unix socket " . $test->sockpath . " exists" );
}

1;


