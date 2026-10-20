package PVE::Tools;
use strict;
use warnings;
use Exporter qw( import );

# Stub for unit tests on machines without Proxmox VE.
our @EXPORT_OK = qw( file_read_firstline file_get_contents run_command );

sub file_read_firstline {
  my ( $path ) = @_;
  open( my $fh, '<', $path ) or return undef;
  my $line = <$fh>;
  chomp $line if defined $line;
  return $line;
}

sub file_get_contents {
  my ( $path ) = @_;
  open( my $fh, '<', $path ) or die "unable to open file '$path' - $!\n";
  local $/;
  return scalar <$fh>;
}
sub run_command { return 0 }

1;
