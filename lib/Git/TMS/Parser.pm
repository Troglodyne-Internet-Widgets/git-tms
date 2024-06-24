package Git::TMS::Parser;

use strict;
use warnings;

use 5.006;
use v5.14.0;    # Before 5.006, v5.10.0 would not be understood.

# Figure out what sub-parser we need for this programming language
sub new {

}

# We need to transform raw test output + coverage tool output into the standard format of our notes.
sub parse {

}

# These are expected to be overridden by child modules
sub parse_output {
...
}

sub parse_coverage {
...
}

1;
