package Util::GlogServer;

use feature ':5.18';
use feature qw(say);
use feature qw(switch);

use Moose;
with 'MooseX::Getopt';
with 'MooseX::Log::Log4perl';
use IO::Async::Loop;
use IO::Async::Timer::Countdown;
use IO::File;
use IO::Compress::Bzip2;
use DateTime;
use DateTime::Format::Duration;
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

has 'server_logfile' => (is => 'ro', isa => 'Str',
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
      # TODO: This is the point to check whether there is a global timer present
      #       to count down till the next midnight.  If not, we should create
      #       one here.
      #       Only one will ever be needed to rotate all of the extant log file
      #       streams.

      # TODO: This might need to be broken out into another object/role
      my $stream_data = {};

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
            # TODO: Use _create_fh method here instead
            # my $fh =
            # $self->_create_fh(logfile => $logfile, buffered => $buffered,
            #                   buffer_size => buffer_size,
            #                   compress => $compress,
            #                   compress_level => $compress_level);
            #
            if (my $fh = IO::File->new($logfile,">>")) {
              # TODO: Send Acceptance message back to client after we've
              #       proven we can open the destination log file

              if ( not $buffered ) {
                $log->debug("Disabling buffering");
                $fh->autoflush(1);
              }

              # Set up log data for this client
              $stream_data->{fh}           = $fh;
              $stream_data->{lines_read}   = 0;
              $stream_data->{lines_logged} = 0;
              $stream_data->{logfile}      = $logfile;

              $log_table->{$logfile}       = $stream_data;
              $stream_table->{$stream_obj} = $stream_data;

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
            my $logfile      = $stream_table->{$stream_obj}->{logfile};

            delete $stream_table->{$stream_obj};
            delete $log_table->{$logfile};

            $self->_log_table($log_table);
            $self->_stream_table($stream_table);

            $stream_obj->close;
          } elsif ( $$buffref =~ s/^(.*)\n// ) {
            my $stream_table = $self->_stream_table;
            my $out_fh       = $stream_table->{$stream_obj}->{fh};
            #$log->info( "$1" );
            $out_fh->write("$1\n");
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

# TODO: Turn these into Pod::Weaver directives

=head2 _create_fh

Create filehandle, the type of which is based on parameters passed in from each
client invocation.

This appends the -YYYYMMDD suffix to the file too.

=cut

sub _create_fh {
  my ($self, %args) = @_;


}

sub _add_midnight_timer {
  my ($self) = shift;
}

sub _refresh_expiration {
  my ($self) = shift;
  my ($l) = $self->logger;

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

  #  $self->_expiration($secs_till_midnight);

  return $secs_till_midnight;
}



1;
