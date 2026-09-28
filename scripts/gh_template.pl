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
#
# KEEP_FILE, when set, names a file of literal strings, one per line, that
# no substitution may touch: each is masked before the substitutions run
# and restored after, so `template` is replaced but `sqlc-gen-template`
# is not. A kept string counts only as a whole word -- not directly after
# or before a letter, digit or underscore -- so keeping `gh template` does
# not shield the `template-api` in `through template-api`. The masks are
# control characters, which no placeholder holds.
#
# With REPORT set, the script is run as `perl -n` instead: it rewrites
# nothing, and prints each (from, to) pair that would change the file,
# once, in PAIRS_FILE order -- what --dry-run shows.

use strict;
use warnings;

our @PAIRS;
our @KEEP;
our %MATCHED;

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

    if (my $keep_path = $ENV{KEEP_FILE}) {
        open my $kh, "<", $keep_path
            or die "gh_template.pl: open $keep_path: $!\n";
        while (my $line = <$kh>) {
            chomp $line;
            push @KEEP, $line if length $line;
        }
        close $kh;
        # Longest first, so a kept string is never split by a shorter one.
        @KEEP = sort { length($b) <=> length($a) } @KEEP;
    }
}

my @held;
for my $k (@KEEP) {
    s/(?<![A-Za-z0-9_])\Q$k\E(?![A-Za-z0-9_])/push @held, $k; "\x00" . ("\x01" x scalar @held) . "\x00"/ge;
}

for my $i (0 .. $#PAIRS) {
    my $p = $PAIRS[$i];
    $MATCHED{$i} = 1 if s/\Q$p->[0]\E/$p->[1]/g;
}

s/\x00(\x01+)\x00/$held[length($1) - 1]/g;

END {
    if ($ENV{REPORT}) {
        for my $i (sort { $a <=> $b } keys %MATCHED) {
            print "$PAIRS[$i][0]\t$PAIRS[$i][1]\n";
        }
    }
}
