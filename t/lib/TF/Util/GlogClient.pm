package TF::Util::GlogClient;

use Log::Log4perl     qw();
use Util::GlogServer  qw();

use Test::Class::Moose;
with 'Test::Class::Moose::Role::AutoUse';

has 'gserver' => ( is => 'rw', isa => 'Util::GlogServer' );

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
  my $gserver = Util::GlogServer->new();
  $test->gserver( $gserver );
}

sub test_shutdown {
  my $test = shift;
  # more teardown
  $test->next::method;
  # Shut Down the GlogServer
  # $test->gserver->shutdown();
}

# TODOs:
# - Test when GlogServer isn't running - should fail properly with informative message
# - Handle starting up more than one session that tries to end up at the same file
# - Test binary file type (mpstat -o .. for instance)
# - Binary file type transition at midnight
# - Text file type transition at midnight

sub test_server_is_ok {
  my $test = shift;

  isa_ok($test->gserver, 'Util::GlogServer');
}

1;


