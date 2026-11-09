package JSON; # test stub: JSON (libjson-perl) is present on PVE, not necessarily here
use strict; use warnings; use JSON::PP ();
use Exporter 'import'; our @EXPORT_OK = qw(to_json from_json);
sub _codec { my ($o) = @_; my $j = JSON::PP->new; $j->canonical(1) if $o->{canonical}; $j->utf8(1) if $o->{utf8}; $j }
sub to_json { my ($d, $o) = @_; _codec($o // {})->encode($d) }
sub from_json { my ($d, $o) = @_; _codec($o // {})->decode($d) }
1;
