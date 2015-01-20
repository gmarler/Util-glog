package Util::GlogServer::Stream;

use feature ':5.18';

use Moose;
with 'MooseX::Log::Log4perl';
use IO::Async::Loop;
use IO::Async::Timer::Countdown;
use IO::File;
use IO::Compress::Bzip2;
use Data::Dumper;

use namespace::autoclean;

has 'logfile_base' => ( is => 'rw', isa => 'Str',
                        default => "" );

has 'logfile_full' => ( is => 'rw', isa => 'Str',
                        default => "" );

# TODO: Use Bzip2 file type as well, and IO::All, just in case
has 'fh'           => ( is => 'rw', isa => 'IO::File',
                        default => undef );

has 'lines_read'   => ( is => 'rw', isa => 'Int',
                        default => 0 );

has 'lines_logged' => ( is => 'rw', isa => 'Int',
                        default => 0 );

# TODO: Mark file as text (newline delimited) or binary (no delimiters - like
#       for Solaris mpstat raw data)



1;
