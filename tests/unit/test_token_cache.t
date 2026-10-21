#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;
use File::Temp qw( tempdir );
use PluginLoader;

my $plugin = PluginLoader::load();
my %fn;
$fn{ $_ } = $plugin->can( $_ ) // BAIL_OUT( "$plugin has no $_" ) for qw( write_token_cache read_token_cache is_token_valid cleanup_expired_cache );

my $dir  = tempdir( CLEANUP => 1 );
my $path = "$dir/pure_array0.json";
my $ttl  = 3600;

sub token {
  my ( %over ) = @_;
  return { auth_token => 'test-token-12345', request_id => 'req-67890', created_at => time(), ttl => $ttl, expires_at => time() + $ttl, %over };
}

# --- write and read ---
$fn{ write_token_cache }->( $path, token() );
ok( -f $path, 'token cache file created' );
is( ( stat $path )[2] & 0777, 0600, 'cache file has permissions 600' );
my $data = $fn{ read_token_cache }->( $path );
is( $data->{ auth_token }, 'test-token-12345', 'auth token round-trips' );
is( $data->{ request_id }, 'req-67890',        'request id round-trips' );
is_deeply( [ glob "$dir/*.tmp.*" ], [], 'no temp file is left after the atomic write' );

# --- validity (the plugin refreshes at 80% of the ttl, +-2.5% jitter, so test away from the edge) ---
ok( $fn{ is_token_valid }->( token(), $ttl ), 'fresh token is valid' );
ok( $fn{ is_token_valid }->( token( created_at => time() - $ttl * 0.7 ),  $ttl ), 'token at 70% of the ttl is valid' );
ok( !$fn{ is_token_valid }->( token( created_at => time() - $ttl * 0.9 ), $ttl ), 'token at 90% of the ttl needs a refresh' );
ok( !$fn{ is_token_valid }->( undef, $ttl ), 'undefined token data is invalid' );
for my $missing ( qw( auth_token created_at ttl ) ) {
  my $incomplete = token();
  delete $incomplete->{ $missing };
  ok( !$fn{ is_token_valid }->( $incomplete, $ttl ), "token data without $missing is invalid" );
}

# --- cleanup of expired caches ---
$fn{ write_token_cache }->( $path, token( created_at => time() - 4000, expires_at => time() - 400 ) );
$fn{ cleanup_expired_cache }->( $path, $ttl );
ok( !-f $path, 'expired cache file is removed' );
$fn{ write_token_cache }->( $path, token() );
$fn{ cleanup_expired_cache }->( $path, $ttl );
ok( -f $path, 'cache file that has not expired stays' );

# --- bad input ---
is( $fn{ read_token_cache }->( "$dir/nonexistent.json" ), undef, 'non-existent cache returns undef' );
is( $fn{ read_token_cache }->( undef ),                   undef, 'undefined path returns undef' );
my $corrupt = "$dir/corrupt.json";
open( my $fh, '>', $corrupt ) or die $!;
print { $fh } '{ invalid json }';
close $fh;
is( $fn{ read_token_cache }->( $corrupt ), undef, 'corrupt cache returns undef' );
ok( !-e $corrupt,                                                                  'corrupt cache file is deleted' );
ok( !eval { $fn{ write_token_cache }->( "$dir/missing-dir/x.json", token() ); 1 }, 'writing into a missing directory dies' );

done_testing;
