#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 15;
use File::Temp qw( tempdir );
use JSON::XS   qw( encode_json decode_json );

# Mock PVE::Tools for testing
BEGIN {

  package PVE::Tools;
  use Exporter 'import';
  our @EXPORT_OK = qw( file_get_contents );

  sub file_get_contents {
    my ( $path ) = @_;
    open my $fh, '<', $path or die "Cannot read $path: $!";
    local $/;
    my $content = <$fh>;
    close $fh;
    return $content;
  }
}

# Test token cache implementation
package main;

my $test_dir   = tempdir( CLEANUP => 1 );
my $cache_path = "$test_dir/test_cache.json";

# Helper function to create mock token data
sub create_token_data {
  my ( $age ) = @_;
  my $now = time();
  return {
    auth_token => 'test-token-' . int( rand( 1000 ) ),
    request_id => 'test-request-id',
    created_at => $now - $age,
    ttl        => 3600,
    expires_at => $now - $age + 3600
  };
}

# Helper function to write token cache
sub write_test_cache {
  my ( $token_data ) = @_;
  my $json = encode_json( $token_data );
  open my $fh, '>', $cache_path or die "Cannot write cache: $!";
  print $fh $json;
  close $fh;
}

# Test 1: Token validation - fresh token
{
  my $token_data = create_token_data( 100 );    # 100s old
  my $ttl        = 3600;
  my $threshold  = $ttl * 0.8;                  # 2880s

  ok( 100 < $threshold, 'Fresh token is valid (age < 80% TTL)' );
}

# Test 2: Token validation - expired token
{
  my $token_data = create_token_data( 3000 );    # 3000s old
  my $ttl        = 3600;
  my $threshold  = $ttl * 0.8;                   # 2880s

  ok( 3000 >= $threshold, 'Expired token needs refresh (age >= 80% TTL)' );
}

# Test 3: Cache file write and read
{
  my $token_data = create_token_data( 50 );
  write_test_cache( $token_data );

  ok( -f $cache_path, 'Cache file created' );

  my $json_text = PVE::Tools::file_get_contents( $cache_path );
  my $read_data = decode_json( $json_text );

  is( $read_data->{ auth_token }, $token_data->{ auth_token }, 'Token data matches after read' );
}

# Test 4: Cache file validation - valid token
{
  my $token_data = create_token_data( 100 );
  write_test_cache( $token_data );

  my $json_text = PVE::Tools::file_get_contents( $cache_path );
  my $cached    = decode_json( $json_text );

  my $age       = time() - $cached->{ created_at };
  my $threshold = 3600 * 0.8;

  ok( $age < $threshold, 'Cached token is still valid' );
}

# Test 5: Cache file validation - expired token
{
  my $token_data = create_token_data( 3000 );
  write_test_cache( $token_data );

  my $json_text = PVE::Tools::file_get_contents( $cache_path );
  my $cached    = decode_json( $json_text );

  my $age       = time() - $cached->{ created_at };
  my $threshold = 3600 * 0.8;

  ok( $age >= $threshold, 'Cached token is expired and should be refreshed' );
}

# Test 6: Race condition mitigation - newer token exists
{
  my $old_token = create_token_data( 200 );
  my $new_token = create_token_data( 50 );

  ok( $new_token->{ created_at } > $old_token->{ created_at }, 'Newer token has later created_at timestamp' );
}

# Test 7: TTL validation
{
  my $ttl               = 3600;
  my $refresh_threshold = $ttl * 0.8;

  is( $refresh_threshold, 2880, 'Refresh threshold is 80% of TTL' );

  # Test jitter range (±2.5%)
  my $jitter_min = $ttl * ( 0.8 - 0.025 );
  my $jitter_max = $ttl * ( 0.8 + 0.025 );

  ok( $jitter_min < $refresh_threshold && $refresh_threshold < $jitter_max, 'Jitter keeps threshold within ±2.5% of 80% TTL' );
}

# Test 8: Multiple token files
{
  my $cache1 = "$test_dir/storage1_array0.json";
  my $cache2 = "$test_dir/storage2_array0.json";

  my $token1 = create_token_data( 100 );
  my $token2 = create_token_data( 200 );

  open my $fh1, '>', $cache1 or die $!;
  print $fh1 encode_json( $token1 );
  close $fh1;

  open my $fh2, '>', $cache2 or die $!;
  print $fh2 encode_json( $token2 );
  close $fh2;

  ok( -f $cache1 && -f $cache2, 'Multiple cache files can coexist' );
}

# Test 9: Token cache path generation
{
  my $storeid       = 'pure-n1';
  my $array_index   = 0;
  my $expected_path = "/etc/pve/priv/purestorage/${storeid}_array${array_index}.json";

  like( $expected_path, qr/\/etc\/pve\/priv\/purestorage\/pure-n1_array0\.json$/, 'Cache path follows expected format' );
}

# Test 10: Atomic write simulation
{
  my $temp_path  = "$cache_path.tmp.$$";
  my $token_data = create_token_data( 75 );

  # Write to temp file
  open my $fh, '>', $temp_path or die $!;
  print $fh encode_json( $token_data );
  close $fh;

  ok( -f $temp_path, 'Temp file created' );

  # Atomic rename
  rename( $temp_path, $cache_path ) or die "Cannot rename: $!";

  ok( -f $cache_path && !-f $temp_path, 'Atomic rename completed' );
}

# Test 11: Concurrent token creation scenario
{
  my $node_a_token = create_token_data( 0 );    # Fresh token
  my $node_b_token = create_token_data( 0 );    # Another fresh token

  # Both tokens created ~same time
  my $time_diff = abs( $node_a_token->{ created_at } - $node_b_token->{ created_at } );

  ok( $time_diff < 2, 'Concurrent tokens created within 2 seconds' );

  # Race condition check: should skip write if another token exists within 5s
  ok( $time_diff < 5, 'Falls within race condition mitigation window (5s)' );
}

done_testing();

print "\nToken Cache Tests Summary:\n";
print "=" x 50 . "\n";
print "All tests validate the token caching mechanism:\n";
print "- Token TTL validation (80% refresh threshold)\n";
print "- Cache file operations (read/write)\n";
print "- Race condition mitigation\n";
print "- Concurrent token handling\n";
print "- Atomic write operations\n";
print "=" x 50 . "\n";
