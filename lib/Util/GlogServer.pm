package Util::GlogServer;

use feature ':5.18';
use feature qw(say);

use Moose;
with 'MooseX::Getopt';
use IO::Async::Loop;

use namespace::autoclean;


has 'sockpath'    => ( is => 'rw', isa => 'Str',
                       default => "/tmp/glogserver2.sock" );
has '_loop'       => (is => 'rw', isa => 'IO::Async::Loop',
                      lazy => 1, builder => '_build_loop',
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

    on_stream => sub {
      my ( $stream ) = @_;

      $stream->configure(
        on_read => sub {
          my ( $self, $buffref, $eof ) = @_;
          say "Received $$buffref";
          return 0;
        }
      );

      # Start watching the stream we've just configured
      $loop->add( $stream );
    },

    on_listen_error => sub {
      print STDERR "Cannot listen\n";
    },
  );

  $loop->run;
}

1;
