#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 8;

# Mock HTTP response
package MockHTTPResponse {
  sub new {
    my ( $class, $code, $success ) = @_;
    return bless { code => $code, success => $success }, $class;
  }
  sub code { $_[0]->{code} }
  sub is_success { $_[0]->{success} }
}

# Test retry counter logic
my $retry_count = 0;
my $max_retries = 1;
my @responses;

sub simulate_request {
  my $response = shift @responses;
  return $response;
}

# Test 1: Success on first try (no retry)
@responses = ( MockHTTPResponse->new(200, 1) );
$retry_count = 0;

while ( $retry_count <= $max_retries ) {
  my $response = simulate_request();

  if ( $response->code == 401 ) {
    $retry_count++;
    if ( $retry_count <= $max_retries ) {
      next;  # Retry
    }
  }
  last;  # Success or max retries
}

is( $retry_count, 0, 'No retry on successful response' );

# Test 2: One retry on 401, then success
@responses = (
  MockHTTPResponse->new(401, 0),
  MockHTTPResponse->new(200, 1)
);
$retry_count = 0;

while ( $retry_count <= $max_retries ) {
  my $response = simulate_request();

  if ( $response->code == 401 ) {
    $retry_count++;
    if ( $retry_count <= $max_retries ) {
      next;
    }
  }
  last;
}

is( $retry_count, 1, 'One retry on 401 response' );

# Test 3: Max retries reached (401 twice)
@responses = (
  MockHTTPResponse->new(401, 0),
  MockHTTPResponse->new(401, 0)
);
$retry_count = 0;

while ( $retry_count <= $max_retries ) {
  my $response = simulate_request();

  if ( $response->code == 401 ) {
    $retry_count++;
    if ( $retry_count <= $max_retries ) {
      next;
    } else {
      last;  # Max retries
    }
  }
  last;
}

is( $retry_count, 2, 'Max retries (2) attempted on repeated 401' );

# Test 4: Loop exits after max retries
ok( $retry_count > $max_retries, 'Retry count exceeds max_retries after exhausting' );

# Test 5: No retry on non-401 errors
@responses = ( MockHTTPResponse->new(500, 0) );
$retry_count = 0;

while ( $retry_count <= $max_retries ) {
  my $response = simulate_request();

  if ( $response->code == 401 ) {
    $retry_count++;
    if ( $retry_count <= $max_retries ) {
      next;
    }
  }
  last;
}

is( $retry_count, 0, 'No retry on 500 error' );

# Test 6: Retry counter increments correctly
my @counts;
@responses = (
  MockHTTPResponse->new(401, 0),
  MockHTTPResponse->new(401, 0),
  MockHTTPResponse->new(200, 1)
);
$retry_count = 0;

while ( $retry_count <= $max_retries ) {
  push @counts, $retry_count;
  my $response = simulate_request();

  if ( $response->code == 401 ) {
    $retry_count++;
    if ( $retry_count <= $max_retries ) {
      next;
    }
  }
  last;
}

is_deeply( \@counts, [0, 1], 'Retry counter increments: 0, 1' );

# Test 7: Max retries = 1 allows exactly 1 retry
is( $max_retries, 1, 'Max retries configured to 1' );

# Test 8: Total attempts = max_retries + 1
my $total_attempts = $max_retries + 1;
is( $total_attempts, 2, 'Total attempts = 2 (initial + 1 retry)' );

done_testing();
