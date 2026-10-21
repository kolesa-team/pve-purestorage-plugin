#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;
use PluginLoader;

my $plugin = PluginLoader::load();
my $remove = $plugin->can( 'multipath_remove_map' ) // BAIL_OUT( "$plugin has no multipath_remove_map" );

# `multipathd remove map` refuses at once while something holds the map (on the stand: a reader of the device for a
# few seconds, a partition map of the volume), and the deactivation used to fail on the first refusal. The removal
# is retried until a timeout, so a map that is released within seconds is removed and one that stays held is an error.
my @calls;
my $failures;
{
  no warnings 'redefine';

  # the real exec_command stands between the code and this stub: its return values are part of what is tested
  *PVE::Storage::Custom::PureStoragePlugin::run_command = sub {
    my ( $command, %param ) = @_;
    push @calls, [@$command];
    die "refused\n" if $failures-- > 0;
    return 0;
  };
}

sub run_remove {
  ( $failures, @calls ) = ( shift, () );
  my $ok = eval { $remove->( '3624a93708476f68c18374e7700016a63', 2 ); 1 };
  return ( $ok, $@ );
}

my $stderr = '';
open( my $capture, '>', \$stderr ) or die $!;
my ( $ok ) = do { local *STDERR = $capture; run_remove( 3 ) };
unlike( $stderr, qr/Cannot execute/, 'the refusals of a retried call are not logged one by one' );

( $ok ) = run_remove( 0 );
ok( $ok, 'a map that is not held is removed at once' );
is( scalar @calls, 1, 'one call' );
is_deeply(
  [ map { s{^.*/}{}r } @{ $calls[0] }[0], @{ $calls[0] }[ 1 .. $#{ $calls[0] } ] ],
  [qw( multipathd remove map 3624a93708476f68c18374e7700016a63 )],
  'the map of the volume is removed'
);

( $ok ) = run_remove( 3 );
ok( $ok, 'a map that is held for a moment is retried until it is removed' );
is( scalar @calls, 4, 'three refusals and the successful call' );

my $error;
( $ok, $error ) = run_remove( 1000 );
ok( !$ok, 'a map that stays held is an error' );
like( $error, qr/Timeout while waiting for multipath map "3624a93708476f68c18374e7700016a63" to be released/, 'the error names the map' );

done_testing;
