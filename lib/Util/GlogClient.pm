package Util::GlogClient;

use feature ':5.18';
use feature qw(say);

use Moose;
with 'MooseX::Getopt';
use IO::Async::Loop;
use IO::Async::Process;

use namespace::autoclean;


has 'logfile'     => (is => 'rw', isa => 'Str', required => 1,
                      documentation => 'path to logfile base name');
has 'command'     => (is => 'rw', isa => 'Str', required => 1,
                      documentation => 'Quoted command, with arguments, to log the STDOUT/STDERR of');
has 'buffer'      => (is => 'rw', isa => 'Bool', required => 0,
                      default => 1,
                      documentation => 'Buffer log output? (DEFAULT: TRUE)');
has 'bufsize'     => (is => 'rw', isa => 'Num', required => 0,
                      default => 65536,
                      documentation => 'Size of buffer to use to transfer to log server (DEFAULT: 64KB)');
has 'compress'    => (is => 'rw', isa => 'Bool', required => 0,
                      default => 1,
                      documentation => 'Compress log output? (DEFAULT: TRUE)');
has '_loop'       => (is => 'rw', isa => 'IO::Async::Loop', lazy => 1,
                      builder => '_build_loop',
                     );

sub BUILD {
  my $self = shift;
}

sub _build_loop {
  my $self = shift;

  my $loop = IO::Async::Loop->new;
  return $loop;
}

# Confirm server is up
# Negotiate with server about buffer size and logfile name, and whether there is a collision
# Start the command to capture the STDOUT/STDERR of

sub test {
  my $self = shift;

  my $loop = $self->_loop();

  my $process = IO::Async::Process->new(
    command => [ $self->command() ],
    stdout => { via => 'pipe_read' },
    stderr => { via => 'pipe_read' },
    on_finish => sub { print "The child process has finished\n";
                       $loop->stop;
                       exit(0);
                     },
  );

  # Get the Future object for the connection to the server
  my $server_socket =
  $loop->connect(
    addr => {
      family    => "unix",
      socktype  => "stream",
      path      => "/tmp/glogserver2.sock",
    },
    on_connected => sub {
      my ($handle) = shift;
      say "CONNECTED!";
      my $logfile = $self->logfile;
      say "Requesting log file: $logfile";
      $handle->write("$logfile\n");
      return 1;
    },
    on_connect_error => sub {
      print STDERR "Cannot connect - is the glog2-server down?\n";
      exit(1);
    }
  )->get;

  $process->stdout->configure(
    on_read => sub {
      my ( $stream, $buffref ) = @_;
      while ( $$buffref =~ s/^(.*)\n// ) {
        # TODO: Count lines read from STDOUT of child
        $server_socket->write("$1\n");
      }

      return 0;
    },
  );

  $process->stderr->configure(
    on_read => sub {
      my ( $stream, $buffref ) = @_;
      while ( $$buffref =~ s/^(.*)\n// ) {
        # TODO: Count lines read from STDERR of child
        $server_socket->write("$1\n");
      }

      return 0;
    },
  );

  $loop->add( $process );

  $loop->run;
}

1;
