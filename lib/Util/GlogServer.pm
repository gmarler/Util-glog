package Util::GlogServer;

use feature ':5.18';
use feature qw(say);

use Moose;
with 'MooseX::Getopt';
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

sub _build_loop {
  my $self = shift;

  my $loop = IO::Async::Loop->new;
  return $loop;
}

sub run {
  my $self = shift;
  my $sockpath = $self->sockpath;

  my $loop = $self->_loop();
  my $id = $loop->attach_signal(
            'INT',
            sub {
              say "Received SIGINT";
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

          my $stream_table = $self->_stream_table;

          if ( $$buffref =~ s/^(.*)\n// ) {
            say "Client requested log file: $1";
            my $logfile = $1;
            # Reject if already in list of files we're managing
            if ( exists( $log_table->{$logfile} ) ) {
              say "Log file $logfile already being written to!\n";
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

                say Data::Dumper->Dump([ $log_table ]);
              } else {
                # TODO: Send reject message and close connection
                say "Unable to open file $logfile";
                $stream->close;
              }
            }
          }

          if ($eof) {
            say "WEIRD: Got an eof at the beginning of a connection";
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
            say "Cleaning up after: $stream_obj";
            my $stream_table = $self->_stream_table;
            my $log_table    = $self->_log_table;
            my $logfile      = $stream_table->{$stream_obj};

            delete $stream_table->{$stream_obj};
            delete $log_table->{$logfile};

            $self->_log_table($log_table);
            $self->_stream_table($stream_table);

            $stream_obj->close;
          } elsif ( $$buffref =~ s/^(.*)\n// ) {
            say "$1";
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
