#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;
use File::Copy     qw( copy );
use File::Spec     ();
use File::Temp     qw( tempdir );
use HTTP::Response ();
use PluginLoader;

my $plugin = PluginLoader::load();
my %fn;
$fn{ $_ } = $plugin->can( $_ ) // BAIL_OUT( "$plugin has no $_" ) for qw( plugin_user_agent purestorage_api_call );

# FlashArray integrations identify themselves as pure/<client name>/<client version>[;<optional text>].
# The release build stamps the tag version into $PLUGIN_VERSION; any other copy has none.
sub agent_for {
  my ( $version ) = @_;
  no strict 'refs';
  local ${ "${plugin}::PLUGIN_VERSION" } = $version;
  return $fn{ plugin_user_agent }->();
}

is( agent_for( '1.4.2' ), 'pure/ProxmoxVEPlugin/1.4.2', 'the stamped version follows the client name' );
is( agent_for( '' ),      'pure/ProxmoxVEPlugin/',      'an unstamped copy keeps the name, which ends with a slash, and sends no version' );
unlike( agent_for( '1.4.2' ), qr{[\s;]}, 'no spaces and no optional text' );

# The version never comes from the host: no command is run to find it.
{
  no strict 'refs';
  no warnings 'redefine';
  my $calls = 0;
  local *{ "${plugin}::run_command" } = sub { $calls++; return 0 };
  agent_for( '' );
  is( $calls, 0, 'no command is run to look the version up' );
}

# The release stamp replaces the one line that has this form; the source has to keep it.
{
  open( my $fh, '<', "$FindBin::Bin/../../PureStoragePlugin.pm" ) or BAIL_OUT( "cannot read the plugin: $!" );
  my @lines = grep { /^our \$PLUGIN_VERSION = .*;/ } <$fh>;
  close $fh;
  is( scalar @lines, 1, 'one line for the build to stamp' );
  like( $lines[0] // '', qr/^our \$PLUGIN_VERSION = '';/, 'the source carries no version of its own' );
}

# The release workflow stamps the tag version with scripts/stamp_version.sh.
{
  my $script = "$FindBin::Bin/../../scripts/stamp_version.sh";
  my $dir    = tempdir( CLEANUP => 1 );
  my $copy   = "$dir/PureStoragePlugin.pm";
  my $source = "$FindBin::Bin/../../PureStoragePlugin.pm";

  sub stamp {
    my ( $version, $file ) = @_;
    open( my $out, '>&', \*STDOUT )            or BAIL_OUT( $! );
    open( my $err, '>&', \*STDERR )            or BAIL_OUT( $! );
    open( STDOUT,  '>',  File::Spec->devnull ) or BAIL_OUT( $! );
    open( STDERR,  '>',  File::Spec->devnull ) or BAIL_OUT( $! );
    my $status = system( $script, $version, $file );    # a list: the version reaches the script as it is
    open( STDOUT, '>&', $out ) or BAIL_OUT( $! );
    open( STDERR, '>&', $err ) or BAIL_OUT( $! );
    return $status == 0;
  }

  sub read_file {
    my ( $file ) = @_;
    open( my $fh, '<', $file ) or BAIL_OUT( "cannot read $file: $!" );
    local $/;
    return scalar <$fh>;
  }

  copy( $source, $copy ) or BAIL_OUT( "cannot copy the plugin: $!" );
  ok( stamp( '1.2.3', $copy ), 'a release version is stamped' );
  my $stamped = read_file( $copy );
  like( $stamped, qr/^our \$PLUGIN_VERSION = '1\.2\.3';/m, 'the version is in the file' );
  ( my $unstamped = $stamped ) =~ s/'1\.2\.3'/''/;
  is( $unstamped, read_file( $source ), 'and nothing else changed' );

  copy( $source, $copy );
  ok( stamp( '1.2.3-rc.1', $copy ), 'a release candidate version is stamped' );
  like( read_file( $copy ), qr/^our \$PLUGIN_VERSION = '1\.2\.3-rc\.1';/m, 'with its suffix' );

  for my $bad ( '', 'v1.2.3', '1.2', "1.2.3'; system('x')", '1.2.3 ', 'main' ) {
    copy( $source, $copy );
    ok( !stamp( $bad, $copy ), "not a release version, refused: '$bad'" );
    is( read_file( $copy ), read_file( $source ), '  and the file is left alone' );
  }

  open( my $fh, '>', $copy ) or BAIL_OUT( $! );
  print { $fh } "package Nothing;\n1;\n";
  close $fh;
  ok( !stamp( '1.2.3', $copy ), 'a file without the line to stamp is an error, not a silent blank version' );
}

# Every request to the array carries it.
{
  no strict 'refs';
  no warnings qw( redefine once );
  local ${ "${plugin}::PLUGIN_VERSION" } = '3.1.4';
  my @seen;
  local *LWP::UserAgent::request = sub {
    my ( $self, $request ) = @_;
    push @seen, $self->agent;
    my $response =
      HTTP::Response->new( 200, 'OK', [ 'Content-Type' => 'application/json', 'x-auth-token' => 'session', 'x-request-id' => 'r1' ], '{"items":[]}' );
    $response->request( $request );
    return $response;
  };
  local *{ "${plugin}::save_token_to_cache" } = sub { };
  local *{ "${plugin}::load_auth_token" }     = sub { return ( undef, undef, undef, 3600 ) };
  my $scfg = { address => 'https://array.invalid', token => 'api-token', check_ssl => 1 };
  $fn{ purestorage_api_call }->( $scfg, { type => 'login', method => 'POST' }, 0, 'store' );
  ok( scalar @seen, 'the call reached the HTTP client' );
  is( $seen[0], 'pure/ProxmoxVEPlugin/3.1.4', 'the User-Agent of the request to the array' );
}

done_testing;
