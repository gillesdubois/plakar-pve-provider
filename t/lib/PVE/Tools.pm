package PVE::Tools; # test stub: same semantics as PVE::File (tmp + rename)
use strict; use warnings; use Exporter 'import';
our @EXPORT_OK = qw(file_get_contents file_set_contents run_command);
sub file_set_contents { my ($f, $d, $p) = @_; my $t = "$f.tmp.$$";
  open(my $fh, '>', $t) or die "open $t: $!\n"; chmod($p // 0644, $t); print $fh $d; close $fh; rename($t, $f) or die "rename: $!\n" }
sub file_get_contents { my ($f) = @_; open(my $fh, '<', $f) or die "open $f: $!\n"; local $/; <$fh> }
sub run_command { my ($cmd) = @_; system(@$cmd) == 0 or die "command '@$cmd' failed: exit code " . ($? >> 8) . "\n" }
1;
