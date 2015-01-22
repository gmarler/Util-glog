package TF::Util::GlogServer;

use Test::MockTime           qw( :all );

use Test::Class::Moose;
with 'Test::Class::Moose::Role::AutoUse';

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
}


sub test_midnight_timer {
  my ($test) = shift;

  set_absolute_time( "07/15/2014 23:59:58 -0400", "%m/%d/%Y %H:%M:%S %z" );

  # Create the glogserver object
  my $server = Util::GlogServer->new( sockpath => '/tmp/testglogserver.sock',
                                      server_logfile => '/tmp/testglogserver.log');
  isa_ok($server, $test->class_name());

  can_ok($server, '_add_midnight_timer');

  my $future = $server->run();
  my $timer_id =
  $future->loop->watch_time( after => 3,
                             code => sub {
                               $future->loop->stop();
                             });
  $future->loop->run();

  unlink '/tmp/testglogserver.sock';
}
