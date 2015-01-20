package Util::GlogServer::Stream;

use feature ':5.18';

use Moose;
with 'MooseX::Log::Log4perl';
use IO::Async::Loop;
use IO::Async::Timer::Countdown;
use IO::File;
use IO::Compress::Bzip2;
use Data::Dumper;
use Moose::Util::TypeConstraints;

use namespace::autoclean;

# Define these, so we can use them in type unions below as needed
class_type 'IO::File';
class_type 'IO::All::File';
class_type 'IO::Uncompress::Bunzip2';


has 'logfile_base' => ( is => 'rw', isa => 'Str',
                        required => 1, );

has 'logfile_full' => ( is => 'rw', isa => 'Str',
                        default => "" );

has 'fh'           => ( is => 'rw',
                        isa => 'IO::File | IO::All::File | IO::Uncompress::Bunzip2',
                        default => undef );

has 'lines_read'   => ( is => 'rw', isa => 'Int',
                        default => 0 );

has 'lines_logged' => ( is => 'rw', isa => 'Int',
                        default => 0 );

# TODO: Mark file as text (newline delimited) or binary (no delimiters - like
#       for Solaris mpstat raw data)



1;
