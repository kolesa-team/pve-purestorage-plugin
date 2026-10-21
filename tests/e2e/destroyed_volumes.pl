#!/usr/bin/perl
# Runs on a node: lists the destroyed volumes of a storage, or erases the given ones, through the plugin's API calls.
#   perl destroyed_volumes.pl list <storeid>
#   perl destroyed_volumes.pl eradicate <storeid> <volname>...
use strict;
use warnings;
use PVE::Storage;

my ( $mode, $storeid, @volumes ) = @ARGV;
my $scfg   = PVE::Storage::storage_config( PVE::Storage::config(), $storeid );
my $plugin = PVE::Storage::Plugin->lookup( $scfg->{ type } );

if ( $mode eq 'list' ) {
  print "$_->{name}\n" for @{ $plugin->purestorage_list_volumes( $scfg, undef, $storeid, 1 ) };
} elsif ( $mode eq 'eradicate' ) {
  my $pkg = 'PVE::Storage::Custom::PureStoragePlugin';
  for my $volume ( @volumes ) {
    my $action = {
      name   => 'eradicate volume',
      type   => 'volumes',
      method => 'DELETE',
      ignore => 'Eradication is disabled.',
      params => { names => $pkg->can( 'purestorage_name' )->( $scfg, $volume ) },
    };
    if ( eval { $pkg->can( 'purestorage_api_call' )->( $scfg, $action, 1, $storeid ); 1 } ) {
      print "eradicated $volume\n";
    } else {
      print "failed $volume: $@";
    }
  }
} else {
  die "usage: $0 list|eradicate <storeid> [<volname>...]\n";
}
