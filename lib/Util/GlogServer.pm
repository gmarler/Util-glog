package Util::GlogServer;

use feature ':5.18';
use feature qw(say);

use Moose;
with 'MooseX::Getopt';
use IO::Async::Loop;

use namespace::autoclean;


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
  my $sockpath = "/tmp/glogserver2.sock";

  my $loop = $self->_loop();

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
    },
    on_listen_error => sub {
      print STDERR "Cannot listen\n";
    },
  );

  $loop->run;
  unlink $sockpath;
}

1;
