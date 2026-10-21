package PluginLoader;
use strict;
use warnings;
use File::Basename qw( dirname );
use File::Spec;

# Loads the real PureStoragePlugin.pm. Where Proxmox VE is installed its modules are used; elsewhere the
# stubs next to this file stand in for them (appended to @INC, so real modules win).
# Returns the plugin package name.
sub load {
  my $dir = File::Spec->rel2abs( dirname( __FILE__ ) );
  push @INC, $dir;
  require File::Spec->catfile( $dir, ( '..' ) x 3, 'PureStoragePlugin.pm' );
  return 'PVE::Storage::Custom::PureStoragePlugin';
}

1;
