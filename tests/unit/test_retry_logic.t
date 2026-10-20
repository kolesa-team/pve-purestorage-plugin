#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;
use HTTP::Response;
use JSON::XS qw( encode_json );
use PluginLoader;

my $plugin  = PluginLoader::load();
my $request = $plugin->can( 'purestorage_http_request' ) // BAIL_OUT( "$plugin has no purestorage_http_request" );
my ( $SUCCESS, $API_ERROR, $NETWORK_ERROR ) = map { $plugin->can( $_ )->() } qw( ERROR_SUCCESS ERROR_API_ERROR ERROR_NETWORK_ERROR );

# A user agent that answers from a script and records the requests it got.
package ScriptedUA {
  sub new { my ( $class, @responses ) = @_; return bless { responses => [@responses], seen => [] }, $class }

  sub request {
    my ( $self, $req ) = @_;
    push @{ $self->{ seen } }, $req;
    return shift @{ $self->{ responses } } // die "no scripted response left for " . $req->method . ' ' . $req->uri . "\n";
  }
  sub seen { @{ $_[0]{ seen } } }
}

sub json_response {
  my ( $code, $body, %headers ) = @_;
  my $r = HTTP::Response->new( $code );
  $r->header( 'Content-Type' => 'application/json', %headers );
  $r->content( encode_json( $body ) );
  return $r;
}

sub config {
  my ( $ua, %over ) = @_;
  return { ua => $ua, url => 'https://array.test', token => 'api-token-1', auth_token => 'session-old', ttl => 3600, %over };
}

# --- success on the first try: no login, no retry ---
{
  my $ua = ScriptedUA->new( json_response( 200, { items => [ { name => 'v1' } ] } ) );
  my ( $error, $content ) = $request->( config( $ua ), 'volumes', 'GET', 0 );
  is( $error,                                     $SUCCESS,      'success on the first request' );
  is( scalar $ua->seen,                           1,             'one request, no retry' );
  is( ( $ua->seen )[0]->header( 'x-auth-token' ), 'session-old', 'the cached session token is sent' );
  is( $content->{ items }[0]{ name },             'v1',          'JSON body is decoded' );
}

# --- 401 on a cached token: log in again, retry once, succeed ---
{
  my $ua = ScriptedUA->new(
    json_response( 401, { errors => [ { message => 'expired' } ] } ),
    json_response( 200, {}, 'x-auth-token' => 'session-new' ),
    json_response( 200, { items => [] } ),
  );
  my $config    = config( $ua );
  my ( $error ) = $request->( $config, 'volumes', 'GET', 0 );
  my @seen      = $ua->seen;
  is( $error,       $SUCCESS, 'success after one re-login' );
  is( scalar @seen, 3,        'request, login, retried request' );
  like( $seen[1]->uri, qr{/login$}, 'the second request is the login' );
  is( $seen[1]->header( 'api-token' ),    'api-token-1', 'the login sends the array API token' );
  is( $seen[2]->header( 'x-auth-token' ), 'session-new', 'the retry carries the new session token' );
  is( $config->{ auth_token },            'session-new', 'the config holds the new session token' );
}

# --- 401 again after the retry: give up, never loop ---
{
  my $ua = ScriptedUA->new(
    json_response( 401, { errors => [ { message => 'expired' } ] } ),
    json_response( 200, {}, 'x-auth-token' => 'session-new' ),
    json_response( 401, { errors => [ { message => 'still expired' } ] } ),
  );
  my ( $error, $content ) = $request->( config( $ua ), 'volumes', 'GET', 0 );
  is( $error,                             $API_ERROR,      'a second 401 is returned as an API error' );
  is( scalar $ua->seen,                   3,               'exactly one retry: three requests in total' );
  is( $content->{ errors }[0]{ message }, 'still expired', 'the last error body is returned' );
}

# --- other errors are not retried ---
{
  my $ua = ScriptedUA->new( json_response( 500, { errors => [ { message => 'boom' } ] } ) );
  my ( $error ) = $request->( config( $ua ), 'volumes', 'GET', 0 );
  is( $error,           $API_ERROR, 'a 500 is an API error' );
  is( scalar $ua->seen, 1,          'a 500 is not retried' );
}

# --- a non-JSON answer is a network error ---
{
  my $html = HTTP::Response->new( 502 );
  $html->header( 'Content-Type' => 'text/html' );
  $html->content( '<html>Bad Gateway</html>' );
  my ( $error, $content ) = $request->( config( ScriptedUA->new( $html ) ), 'volumes', 'GET', 0 );
  is( $error, $NETWORK_ERROR, 'a non-JSON error answer is a network error' );
  like( $content->{ response }, qr/Bad Gateway/, 'the raw body is kept' );
}

# --- pagination token from the x-next-token header ---
{
  my $ua = ScriptedUA->new( json_response( 200, { items => [] }, 'x-next-token' => 'abc123' ) );
  my ( undef, $content ) = $request->( config( $ua ), 'volumes', 'GET', 0 );
  is( $content->{ continuation_token }, 'abc123', 'x-next-token fills continuation_token' );

  $ua = ScriptedUA->new( json_response( 200, { items => [], continuation_token => 'from-body' }, 'x-next-token' => 'abc123' ) );
  ( undef, $content ) = $request->( config( $ua ), 'volumes', 'GET', 0 );
  is( $content->{ continuation_token }, 'from-body', 'a continuation_token in the body wins over the header' );
}

done_testing;
