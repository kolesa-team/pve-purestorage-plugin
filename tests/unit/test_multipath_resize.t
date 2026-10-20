#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;
use PluginLoader;

my $plugin = PluginLoader::load();
my $resize = $plugin->can( 'multipath_resize_map' ) // BAIL_OUT( "$plugin has no multipath_resize_map" );

# `qm resize` of a stopped VM activates the volume first and resizes it at once, before multipathd has the
# map: `multipathd resize map` fails for a moment and must be retried, not fatal.
my @calls;
my $failures;
{
  no warnings 'redefine';

  # the real exec_command stands between the code and this stub: its return values are part of what is tested
  *PVE::Storage::Custom::PureStoragePlugin::run_command = sub {
    my ( $command, %param ) = @_;
    push @calls, [@$command];
    die "refused
" if $failures-- > 0;
    return 0;
  };
}

sub run_resize {
  ( $failures, @calls ) = ( shift, () );
  my $ok = eval { $resize->( '3624a93708476f68c18374e7700016a63', 2 ); 1 };
  return ( $ok, $@ );
}

my ( $ok ) = run_resize( 0 );
ok( $ok, 'a map that accepts the resize at once is fine' );
is( scalar @calls, 1, 'one call' );
is_deeply(
  [ map { s{^.*/}{}r } @{ $calls[0] }[0], @{ $calls[0] }[ 1 .. $#{ $calls[0] } ] ],
  [qw( multipathd resize map 3624a93708476f68c18374e7700016a63 )],
  'the map of the volume is resized'
);

( $ok ) = run_resize( 3 );
ok( $ok, 'a map that is not ready for a moment is retried until it accepts the resize' );
is( scalar @calls, 4, 'three refusals and the successful call' );

my $error;
( $ok, $error ) = run_resize( 1000 );
ok( !$ok, 'a map that never accepts the resize is an error' );
like( $error, qr/Timeout while waiting for multipath map "3624a93708476f68c18374e7700016a63"/, 'the error names the map' );

done_testing;
