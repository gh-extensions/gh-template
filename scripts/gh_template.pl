#!/usr/bin/env perl
# Apply (from, to) string substitutions to a file in place.
#
# Designed to be invoked as:
#   PAIRS_FILE=/tmp/pairs.tsv perl -i -p scripts/gh_template.pl <file>
#
# Reads tab-separated (from, to) pairs from the file named by the
# environment variable PAIRS_FILE in the BEGIN block (once per perl
# invocation), then -p wraps the body so each substitution runs against
# every line of the target file. -i rewrites the file in place.
#
# Substitutions are applied in the order they appear in PAIRS_FILE, which
# is sorted by descending length of <from> so longer placeholders match
# before shorter overlapping ones.

use strict;
use warnings;

our @PAIRS;

BEGIN {
    my $path = $ENV{PAIRS_FILE}
        or die "gh_template.pl: PAIRS_FILE env var not set\n";
    open my $fh, "<", $path
        or die "gh_template.pl: open $path: $!\n";
    while (my $line = <$fh>) {
        chomp $line;
        my ($from, $to) = split /\t/, $line, 2;
        push @PAIRS, [ $from, $to ];
    }
    close $fh;
}

for my $p (@PAIRS) {
    s/\Q$p->[0]\E/$p->[1]/g;
}
