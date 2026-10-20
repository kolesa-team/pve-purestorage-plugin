package PVE::SafeSyslog;
use strict;
use warnings;
use Exporter qw( import );

# Stub for unit tests on machines without Proxmox VE.
our @EXPORT = qw( syslog );

sub syslog { return 1 }

1;
