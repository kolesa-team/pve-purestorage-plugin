#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 16;
use File::Temp qw(tempdir);
use File::Path qw(make_path remove_tree);
use JSON;

# Create temporary cache directory
my $cache_dir = tempdir( CLEANUP => 1 );

# Mock functions from plugin
sub get_token_cache_path {
  my ( $storeid, $array_index ) = @_;
  my $dir = "$cache_dir/purestorage";
  make_path($dir) unless -d $dir;
  chmod 0700, $dir;
  return "$dir/${storeid}_array${array_index}.json";
}

sub write_token_cache {
  my ( $cache_path, $token_data ) = @_;

  my $temp_path = "$cache_path.tmp.$$";
  open my $fh, '>', $temp_path or die "Cannot write to $temp_path: $!";
  print $fh encode_json($token_data);
  close $fh;

  chmod 0600, $temp_path;
  rename $temp_path, $cache_path or die "Cannot rename $temp_path to $cache_path: $!";
}

sub read_token_cache {
  my ( $cache_path ) = @_;

  return undef unless -f $cache_path;

  open my $fh, '<', $cache_path or return undef;
  my $content = do { local $/; <$fh> };
  close $fh;

  return undef unless $content;

  my $data = eval { decode_json($content) };
  return undef if $@;

  return $data;
}

sub is_token_valid {
  my ( $token_data, $ttl ) = @_;

  return 0 unless defined $token_data;
  return 0 unless defined $token_data->{auth_token};
  return 0 unless defined $token_data->{created_at};

  my $now = time();
  my $age = $now - $token_data->{created_at};
  my $refresh_threshold = $ttl * 0.8;

  return $age < $refresh_threshold;
}

sub cleanup_expired_cache {
  my ( $cache_path, $ttl ) = @_;

  my $token_data = read_token_cache($cache_path);
  return unless $token_data;

  my $now = time();
  if ( $now > $token_data->{expires_at} ) {
    unlink $cache_path;
  }
}

# Test 1: Cache directory creation
my $cache_path = get_token_cache_path('pure', 0);
ok( -d "$cache_dir/purestorage", 'Cache directory created' );

# Test 2: Cache directory permissions
my $mode = (stat("$cache_dir/purestorage"))[2] & 0777;
is( $mode, 0700, 'Cache directory has correct permissions (700)' );

# Test 3: Write token cache
my $token_data = {
  auth_token => 'test-token-12345',
  request_id => 'req-67890',
  created_at => time(),
  ttl        => 3600,
  expires_at => time() + 3600
};

write_token_cache($cache_path, $token_data);
ok( -f $cache_path, 'Token cache file created' );

# Test 4: Cache file permissions
$mode = (stat($cache_path))[2] & 0777;
is( $mode, 0600, 'Cache file has correct permissions (600)' );

# Test 5: Read token cache
my $read_data = read_token_cache($cache_path);
ok( defined $read_data, 'Token cache read successfully' );

# Test 6: Verify token data
is( $read_data->{auth_token}, 'test-token-12345', 'Auth token matches' );
is( $read_data->{request_id}, 'req-67890', 'Request ID matches' );

# Test 7: Valid token (fresh)
ok( is_token_valid($read_data, 3600), 'Fresh token is valid' );

# Test 8: Valid token at 79% of TTL
$token_data->{created_at} = time() - (3600 * 0.79);
write_token_cache($cache_path, $token_data);
$read_data = read_token_cache($cache_path);
ok( is_token_valid($read_data, 3600), 'Token at 79% TTL is still valid' );

# Test 9: Invalid token at 81% of TTL
$token_data->{created_at} = time() - (3600 * 0.81);
write_token_cache($cache_path, $token_data);
$read_data = read_token_cache($cache_path);
ok( !is_token_valid($read_data, 3600), 'Token at 81% TTL is invalid' );

# Test 10: Multiple array caches
my $cache_path_1 = get_token_cache_path('pure', 1);
write_token_cache($cache_path_1, $token_data);
ok( -f $cache_path_1, 'Second array cache created' );
isnt( $cache_path, $cache_path_1, 'Different cache files for different arrays' );

# Test 11: Cleanup expired cache
$token_data->{created_at} = time() - 4000;
$token_data->{expires_at} = time() - 400;  # Expired
write_token_cache($cache_path, $token_data);
cleanup_expired_cache($cache_path, 3600);
ok( !-f $cache_path, 'Expired cache file removed' );

# Test 12: Read non-existent cache
my $missing_cache = read_token_cache("$cache_dir/nonexistent.json");
is( $missing_cache, undef, 'Non-existent cache returns undef' );

# Test 13: Invalid JSON in cache
my $corrupt_cache = "$cache_dir/purestorage/corrupt.json";
open my $fh, '>', $corrupt_cache;
print $fh "{ invalid json }";
close $fh;
my $corrupt_data = read_token_cache($corrupt_cache);
is( $corrupt_data, undef, 'Corrupt cache returns undef' );

# Test 14: Missing required fields
my $incomplete_data = { auth_token => 'test' };  # Missing created_at
ok( !is_token_valid($incomplete_data, 3600), 'Incomplete token data is invalid' );

done_testing();
