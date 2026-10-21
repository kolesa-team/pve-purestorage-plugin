#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;
use PluginLoader;

my $plugin = PluginLoader::load();

# The version of the storage API the plugin reports to PVE: what the host runs inside the tested range, the
# newest tested one while the host still accepts it (APIVER - APIAGE), the oldest supported one otherwise.
sub reported {
  my ( $apiver, $apiage ) = @_;
  no warnings 'redefine';
  local *PVE::Storage::APIVER = sub { $apiver };
  local *PVE::Storage::APIAGE = sub { $apiage };
  return $plugin->api();
}

is( reported( 11, 2 ), 11, 'PVE 8.4 (APIVER 11): the host version' );
is( reported( 15, 7 ), 15, 'APIVER 15: the host version' );
is( reported( 16, 7 ), 16, 'PVE 9.2 (APIVER 16): the host version, no "older storage API" warning' );
is( reported( 17, 7 ), 16, 'a newer host that still accepts the tested version gets the tested one' );
is( reported( 40, 7 ), 10, 'a host that no longer accepts the tested version gets the oldest supported one' );

done_testing;
