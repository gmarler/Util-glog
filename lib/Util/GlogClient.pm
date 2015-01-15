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
has 'buffered'    => (is => 'rw', isa => 'Bool', required => 0,
                      default => 1,
                      documentation => 'Buffer log output? (DEFAULT: TRUE)');
has 'buffer_size' => (is => 'rw', isa => 'Num', required => 0,
                      default => 8192,
                      documentation => 'Size of buffer to use to transfer to log server (DEFAULT: 8KB)');
has 'compress'    => (is => 'rw', isa => 'Bool', required => 0,
                      default => 1,
                      documentation => 'Compress log output with bzip2? (DEFAULT: TRUE)');
# TODO: Ensure the range is 1 - 9, and test for it!
has 'compress_level' => (is => 'rw', isa => 'Num', required => 0,
                         default => 9,
                         documentation => 'Bzip2 compression level? (DEFAULT: 9)');

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
      # TODO:
      # Client Protocol
      # LOGFILE:        The logfile we're requesting the server create
      # BUFFERED:       0 | 1   Whether the log will be buffered or not
      #                 DEFAULT: 1
      # BUFFER_SIZE:    <bytes> Buffer size
      #                 DEFAULT: 8192
      # COMPRESS:       0 | 1   Whether the log will be bzip2 compressed or not
      #                 DEFAULT: 1
      # COMPRESS_LEVEL: 1-9  Level of bzip2 compression
      #                 DEFAULT: 9
      my $logfile     = $self->logfile;
      my $buffered    = $self->buffered;
      my $buffer_size = $self->buffer_size;
      my $compress    = $self->compress;
      my $compress_level = $self->compress_level;

      if ( not $buffered ) {
        $handle->autoflush(1);
      }

      say "Requesting log file: $logfile";
      $handle->write("LOGFILE: $logfile\n");
      $handle->write("BUFFERED: $buffered\n");
      $handle->write("BUFFER_SIZE: $buffer_size\n");
      $handle->write("COMPRESS: $compress\n");
      $handle->write("COMPRESS_LEVEL: $compress_level\n");
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
