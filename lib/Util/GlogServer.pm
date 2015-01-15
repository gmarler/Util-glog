package Util::GlogServer;

use feature ':5.18';
use feature qw(say);
use feature qw(switch);

use Moose;
with 'MooseX::Getopt';
with 'MooseX::Log::Log4perl';
use IO::Async::Loop;
use IO::File;
use Data::Dumper;

use namespace::autoclean;


has 'sockpath'      => ( is => 'rw', isa => 'Str',
                         default => "/tmp/glogserver2.sock" );

has '_loop'         => (is => 'rw', isa => 'IO::Async::Loop',
                        lazy => 1, builder => '_build_loop',
                       );

has '_log_table'    => (is => 'rw', isa => 'HashRef',
                        default => sub { return {}; },
                       );

has '_stream_table' => (is => 'rw', isa => 'HashRef',
                        default => sub { return {}; },
                       );

has '_server_logfile' => (is => 'ro', isa => 'Str',
                          default => '/tmp/glogserver2.log',
                         );

sub _build_loop {
  my $self = shift;

  my $loop = IO::Async::Loop->new;
  return $loop;
}

sub run {
  my $self = shift;
  my $sockpath = $self->sockpath;
  my $log      = $self->logger;

  my $loop = $self->_loop();
  my $id = $loop->attach_signal(
            'INT',
            sub {
              $log->warn( "Received SIGINT" );
              $self->_loop->stop;
              unlink $sockpath;
            });

  $loop->listen(
    addr => {
      family    => "unix",
      socktype  => "stream",
      path      => $sockpath,
    },

    # TODO: on_stream is vaguely deprecated
    #       Use IO::Async::Listener::on_accept instead
    on_stream => sub {
      my ( $stream ) = @_;

      my $log_table = $self->_log_table;
      my $logdata = {};
      # PROTOCOL:
      #
      # CLIENT: Send desired log pathname
      # TODO:   And buffer size
      #         And compression level
      #
      # SERVER: Check that log pathname is acceptable, open filehandle to it,
      #         and store it.
      #         Send back success and continue, OR
      #         send back rejection and disconnect
      #
      # CLIENT: Start sending data
      #
      # SERVER: Redirect data to proper filehandle
      #
      $stream->push_on_read(
        sub {
          my ($stream_obj, $buffref, $eof) = @_;

          my ($logfile, $buffered, $buffer_size, $compress, $compress_level);

          my $stream_table = $self->_stream_table;

          while ( $$buffref =~ s/^(?<directive>
                                   (?:LOGFILE|
                                      BUFFERED|
                                      BUFFER_SIZE|
                                      COMPRESS|
                                      COMPRESS_LEVEL
                                   )
                                  ): \s+
                                   (?<dirval>\S+)\n//x )
          {
            given ($+{directive}) {
              my %client_args = %+;
              when (/^LOGFILE$/) {
                $logfile = $client_args{dirval};
                $log->debug( "Client requested log file: $logfile" );
              }
              when (/^BUFFERED$/) {
                $buffered = $client_args{dirval};
                $log->debug( "Client requested buffering: $buffered" );
              }
              when (/^BUFFER_SIZE$/) {
                $buffer_size = $client_args{dirval};
                $log->debug( "Client requested buffer size: $buffer_size" );
              }
              when (/^COMPRESS$/) {
                $compress = $client_args{dirval};
                $log->debug( "Client requested bzip2 compression: $compress" );
              }
              when (/^COMPRESS_LEVEL$/) {
                $compress_level = $client_args{dirval};
                $log->debug( "Client requested bzip2 compression level: $compress_level" );
              }
            }
          }

          # Reject if already in list of files we're managing
          if ( exists( $log_table->{$logfile} ) ) {
            $log->error( "Log file $logfile already being written to!" );
            # TODO: Send reject message and close message
            $stream->close;
          } else {
            if (my $fh = IO::File->new($logfile,">")) {
              # TODO: Send Acceptance message

              # Set up log data for this client
              $logdata->{fh}           = $fh;
              $logdata->{lines_read}   = 0;
              $logdata->{lines_logged} = 0;

              $log_table->{$logfile} = $logdata;
              $stream_table->{$stream_obj} = $logfile;

              $self->_log_table($log_table);

              $log->debug( Data::Dumper->Dump([ $log_table ]) );
            } else {
              # TODO: Send reject message and close connection
              $log->error( "Unable to open file $logfile" );
              $stream->close;
            }
          }

          if ($eof) {
            $log->warn( "WEIRD: Got an eof at the beginning of a connection" );
          }

          # Ok, we've finished talking to the client, now restore the default
          # reader routine, so we can start receiving real data!
          return undef;
        }
      );

      $stream->configure(
        on_read => sub {
          my ( $stream_obj, $buffref, $eof ) = @_;

          if ($eof) {
            # TODO: flush the output log and clean up
            # TODO: Close outgoing filehandle
            $log->debug( "Cleaning up after: $stream_obj" );
            my $stream_table = $self->_stream_table;
            my $log_table    = $self->_log_table;
            my $logfile      = $stream_table->{$stream_obj};

            delete $stream_table->{$stream_obj};
            delete $log_table->{$logfile};

            $self->_log_table($log_table);
            $self->_stream_table($stream_table);

            $stream_obj->close;
          } elsif ( $$buffref =~ s/^(.*)\n// ) {
            $log->info( "$1" );
            return 1;
          }
        }
      );

      # Start watching the stream we've just configured
      $loop->add( $stream );
    },

    on_listen_error => sub {
      print STDERR "Cannot listen - do you need to remove the socket?\n";
      exit(1);
    },
  );

  $loop->run;
}

1;
