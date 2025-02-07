package PVE::Storage::Custom::PureStoragePlugin;

use strict;
use warnings;

use Data::Dumper qw( Dumper );    # DEBUG

use IO::File   ();
use Net::IP    ();
use File::Path ();

use PVE::JSONSchema      ();
use PVE::Network         ();
use PVE::Tools           qw( run_command );
use PVE::INotify         ();
use PVE::Storage::Plugin ();

use JSON::XS       qw( decode_json encode_json );
use LWP::UserAgent ();
use HTTP::Headers  ();
use HTTP::Request  ();
use URI::Escape    qw( uri_escape );
use File::Basename qw( basename );
use Time::HiRes    qw( gettimeofday sleep );
use Cwd            qw( abs_path );

use base qw(PVE::Storage::Plugin);

push @PVE::Storage::Plugin::SHARED_STORAGE, 'purestorage';
$Data::Dumper::Terse  = 1;    # Removes `$VAR1 =` in output
$Data::Dumper::Indent = 1;    # Outputs everything in one line
$Data::Dumper::Useqq  = 1;    # Uses quotes for strings

my $purestorage_wwn_prefix = "624a9370";
my $default_hgsuffix       = "";

my $DEBUG = 0;

my $cmd = {
  iscsiadm  => '/usr/bin/iscsiadm',
  multipath => '/sbin/multipath',
  blockdev  => '/usr/sbin/blockdev'
};

### BLOCK: Configuration
sub api {

# PVE 5:   APIVER  2
# PVE 6:   APIVER  3
# PVE 6:   APIVER  4 e6f4eed43581de9b9706cc2263c9631ea2abfc1a / volume_has_feature
# PVE 6:   APIVER  5 a97d3ee49f21a61d3df10d196140c95dde45ec27 / allow rename
# PVE 6:   APIVER  6 8f26b3910d7e5149bfa495c3df9c44242af989d5 / prune_backups (fine, we don't support that content type)
# PVE 6:   APIVER  7 2c036838ed1747dabee1d2c79621c7d398d24c50 / volume_snapshot_needs_fsfreeze (guess we are fine, upstream only implemented it for RDBPlugin; we are not that different to let's say LVM in this regard)
# PVE 6:   APIVER  8 343ca2570c3972f0fa1086b020bc9ab731f27b11 / prune_backups (fine again, see APIVER 6)
# PVE 7:   APIVER  9 3cc29a0487b5c11592bf8b16e96134b5cb613237 / resets APIAGE! changes volume_import/volume_import_formats
# PVE 7.1: APIVER 10 a799f7529b9c4430fee13e5b939fe3723b650766 / rm/add volume_snapshot_{list,info} (not used); blockers to volume_rollback_is_possible (not used)

  my $apiver = 10;

  return $apiver;
}

sub type {
  return "purestorage";
}

sub plugindata {
  return {
    content => [ { images => 1, none => 1 }, { images => 1 } ],
    format  => [ { raw    => 1 },            "raw" ],
  };
}

sub properties {
  return {
    hgsuffix => {
      description => "Host group suffx.",
      type        => "string",
      default     => $default_hgsuffix
    },
    address => {
      description => "PureStorage Management IP address or DNS name.",
      type        => "string"
    },
    token => {
      description => "Storage API token.",
      type        => "string"
    },
    podname => {
      description => 'PureStorage pod name',
      type        => 'string'
    },
    vnprefix => {
      description => 'Prefix to add to volume name before sending it to PureStorage array',
      type        => 'string'
    },
    check_ssl => {
      description => "Verify the server's TLS certificate",
      type        => "boolean",
      default     => "no"
    },
  };
}

sub options {
  return {
    address => { fixed => 1 },
    token   => { fixed => 1 },

    hgsuffix  => { optional => 1 },
    vgname    => { optional => 1 },
    podname   => { optional => 1 },
    vnprefix  => { optional => 1 },
    check_ssl => { optional => 1 },
    nodes     => { optional => 1 },
    disable   => { optional => 1 },
    content   => { optional => 1 },
    format    => { optional => 1 },
  };
}

### BLOCK: Supporting functions

sub exec_command {
  my ( $command, $die, %param ) = @_;

  print "Debug :: execute '" . join( ' ', @$command ) . "'\n" if $DEBUG >= 2;
  eval { run_command( $command, %param ) };
  if ( $@ ) {
    my $error = " :: Cannot execute '" . join( ' ', @$command ) . "'. Error :: $@\n";
    die 'Error' . $error if $die;

    warn 'Warning' . $error;
  }
}

sub prepare_api_params {
  my ( $parms ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::prepare_api_params\n" if $DEBUG;

  return $parms unless ref( $parms ) eq 'HASH';

  my @temp;
  my $ref;
  my @ands;
  my $or;
  while ( my ( $key, $value ) = each( %$parms ) ) {
    $ref = ref $value;
    if ( $ref eq 'HASH' ) {
      @temp = ();
      while ( my ( $fname, $fvalue ) = each( %$value ) ) {
        $ref = ref $fvalue;
        if ( $ref eq '' ) {
          $fvalue = [ split( ',', $fvalue ) ];
        } else {
          die "Error :: Unsupported condition type: $ref" if $ref ne 'ARRAY';
        }
        $or     = $#$fvalue > 0;
        $fvalue = join( ' or ', map { "$fname='$_'" } @$fvalue );
        $fvalue = '(' . $fvalue . ')' if $or;
        push @temp, $fvalue;
      }
      $value = join( ' and ', @temp );
    } else {
      $value = join( ',', @$value ) if $ref eq 'ARRAY';
    }
    push @ands, uri_escape( $key ) . '=' . uri_escape( $value );
  }

  return join( '&', @ands );
}

sub purestorage_name_prefix {
  my ( $scfg ) = @_;

  my $ckey   = '_vnprefix';
  my $prefix = $scfg->{ $ckey };
  if ( !defined( $prefix ) ) {
    my %parms = (
      vgname  => '/',
      podname => '::'
    );
    my $value;
    my $pkey = '';
    while ( my ( $key, $suffix ) = each( %parms ) ) {
      $value = $scfg->{ $key };
      if ( defined( $value ) ) {
        die "Error :: Cannot have both \"$pkey\" and \"$key\" provided at the same time\n" if $pkey ne '';
        die "Error :: Invalid \"$key\" parameter value \"$value\"\n"                       if $value !~ m/^\w([\w-]*\w)?$/;
        $prefix = $value . $suffix;
        $pkey   = $key;
      }
    }
    $prefix = '' if $pkey eq '';    # allow no prefix

    $pkey  = 'vnprefix';
    $value = $scfg->{ $pkey };
    if ( defined( $value ) ) {
      $prefix .= $value;
      die "Error :: Invalid \"$pkey\" parameter value \"$value\"\n" if $prefix !~ m/^\w([\w-]*\w)?((\/|::)(\w[\w-]*)?)?$/;
    }

    $scfg->{ $ckey } = $prefix;
  }

  return $prefix;
}

sub purestorage_name {
  my ( $scfg, $volname, $snapname ) = @_;

  my $name = length( $volname ) ? purestorage_name_prefix( $scfg ) . $volname : '';
  if ( length( $snapname ) ) {
    my $snap = $snapname;
    $snap =~ s/^(veeam_)/veeam-/;    # s/_/-/g;
    $snap = 'snap-' . $snap unless defined $1;
    $name .= '.' if $name ne '';
    $name .= $snap;
  }

  print 'Debug :: purestorage_name ::',
    ( defined( $volname ) ? ' name="' . $volname . '"' : '' ), ( defined( $snapname ) ? ' snap="' . $snapname . '"' : '' ), ' => "' . $name . '"', "\n"
    if $DEBUG >= 2;

  return $name;
}

### BLOCK: Local multipath => PVE::Storage::Custom::PureStoragePlugin::sub::s

my $psfa_api = "2.26";

sub purestorage_api_request {
  my ( $scfg, $action ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_api_request\n" if $DEBUG;

  my $url = $scfg->{ address } or die "Error :: Pure Storage host address is not defined.\n";

  my $type = $action->{ type };
  $url .= '/api/' . $psfa_api . '/' . $type;

  my $params = prepare_api_params( $action->{ params } );
  $url .= "?$params" if length( $params );

  my $ua = LWP::UserAgent->new;
  $ua->ssl_opts(
    verify_hostname => 0,
    SSL_verify_mode => 0x00
  ) unless $scfg->{ check_ssl };

  my $body    = $action->{ body } ? encode_json( $action->{ body } ) : undef;
  my $headers = HTTP::Headers->new( 'Content-Type' => 'application/json' );

  my $token_status;
  if ( $type eq 'login' ) {
    $token_status = 0;    # login request
    $headers->header( 'api-token' => $scfg->{ token } );
  } elsif ( $scfg->{ x_auth_token } ) {
    $token_status = 1;    # have cached token
  } else {
    $token_status = 2;    # need token
  }

  my $success;
  my $response;
  while ( 1 ) {
    if ( $token_status > 0 ) {
      if ( $token_status == 1 ) {
        print "Debug :: Using existing session token\n" if $DEBUG;
      } else {
        print "Debug :: Requesting new session token\n" if $DEBUG;
        purestorage_api_request( $scfg, { name => 'Authentication', type => 'login', method => 'POST' } );
      }
      $headers->header( 'x-auth-token' => $scfg->{ x_auth_token } );
    }
    $headers->header( 'X-Request-ID' => $scfg->{ x_request_id } ) if $scfg->{ x_request_id };

    my $request = HTTP::Request->new( $action->{ method }, $url, $headers, $body );
    $response = $ua->request( $request );

    $success = $response->is_success;
    if ( !$success && $token_status == 1 && $response->code == 401 ) {
      print "Debug :: Session token expired\n";
      $token_status = 2;
      next;
    }

    last;
  }

  my $content_type = $response->header( "Content-Type" );
  my $content =
    defined $content_type && $content_type =~ /application\/json/ && $response->content ne ''
    ? decode_json( $response->content )
    : $response->decoded_content;

  $content = {} if $content eq '';

  if ( $success ) {
    if ( $token_status == 0 ) {
      $headers                = $response->headers;
      $scfg->{ x_auth_token } = $headers->header( 'x-auth-token' ) or die "Error :: Header 'x-auth-token' is missing.\n";
      $scfg->{ x_request_id } = $headers->header( 'x-request-id' );
    }
  } else {
    my $ignore_errors = $action->{ ignore };
    if ( defined( $ignore_errors ) ) {
      $ignore_errors = [$ignore_errors] if ref( $ignore_errors ) eq '';
      my $first = $content->{ errors }->[0]->{ message };
      $success = 1 if grep { $_ eq $first } @$ignore_errors;
    }

    if ( !$success ) {
      my $message = $action->{ name } || "Action '$type' (method '" . $action->{ method } . "')";
      $message = substr( $message, 0, 1 ) eq uc( substr( $message, 0, 1 ) ) ? $message . ' failed' : 'Failed to ' . $message;
      die "Error :: PureStorage API :: $message.\n"
        . "=> Trace:\n"
        . "==> Code: "
        . $response->code . "\n"
        . ( $content ? "==> Message: " . Dumper( $content ) : '' );
    }
  }

  return $content;
}

sub purestorage_list_volumes {
  my ( $class, $scfg, $vmid, $storeid, $destroyed ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_list_volumes\n" if $DEBUG;

  $vmid = '*' unless defined( $vmid );
  my $names = "vm-$vmid-disk-*,vm-$vmid-cloudinit,vm-$vmid-state-*";

  return $class->purestorage_get_volumes( $scfg, $names, $storeid, $destroyed );
}

sub purestorage_get_volumes {
  my ( $class, $scfg, $names, $storeid, $destroyed ) = @_;

  my $filter = { name => [ map { purestorage_name( $scfg, $_ ) } split( ',', $names ) ] };
  $filter->{ destroyed } = $destroyed ? 'true' : 'false' if defined $destroyed;

  my $action = {
    name   => $names =~ m/[*,]/ ? 'list volumes' : 'get volume information',
    type   => 'volumes',
    method => 'GET',
    params => { filter => $filter }
  };

  my $response = purestorage_api_request( $scfg, $action );

  my $pref_len = length( purestorage_name_prefix( $scfg ) );
  my @volumes  = map {
    my $volname = substr( $_->{ name }, $pref_len );

    my ( undef, undef, $volvm ) = $class->parse_volname( $volname );

    my $ctime = int( $_->{ created } / 1000 );
    {
      name   => $volname,
      vmid   => $volvm,
      serial => $_->{ serial },
      size   => $_->{ provisioned }           || 0,
      used   => $_->{ space }->{ total_used } || 0,
      ctime  => $ctime,
      volid  => $storeid ? "$storeid:$volname" : $volname,
      format => 'raw'
    }
  } @{ $response->{ items } };

  return \@volumes;
}

sub purestorage_get_volume_info {
  my ( $class, $scfg, $volname, $storeid, $destroyed ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_get_volume_info\n" if $DEBUG;

  my $volumes = $class->purestorage_get_volumes( $scfg, $volname, $storeid, $destroyed );
  foreach my $volume ( @$volumes ) {
    return $volume;
  }

  return undef;
}

sub purestorage_get_existing_volume_info {
  my ( $class, $scfg, $volname, $storeid ) = @_;

  return $class->purestorage_get_volume_info( $scfg, $volname, $storeid, 0 );
}

sub purestorage_get_wwn {
  my ( $class, $scfg, $volname ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_get_wwn\n" if $DEBUG;

  my $volume = $class->purestorage_get_existing_volume_info( $scfg, $volname );
  if ( $volume ) {

    # Construct the WWN path
    my $path = lc( "/dev/disk/by-id/wwn-0x" . $purestorage_wwn_prefix . $volume->{ serial } );
    my $wwn  = lc( "3" . $purestorage_wwn_prefix . $volume->{ serial } );
    return ( $path, $wwn );
  }
  return ( '', '' );
}

sub purestorage_unmap_disk {
  my ( $class, $disk_name ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_unmap_disk\n" if $DEBUG;

  if ( $disk_name =~ m|^(sd[a-z]+)$| ) {
    $disk_name = $1;    # untaint;
    my $sysfs_path = "/sys/block/$disk_name";
    my $disk_path  = "/dev/$disk_name";

    if ( -e $disk_path ) {
      exec_command( [ $cmd->{ blockdev }, '--flushbufs', $disk_path ] );
    }

    my $fh;
    open( $fh, ">", $sysfs_path . "/device/state" ) or die "Could not open file \"$sysfs_path/device/state\" for writing.\n";
    print $fh "offline";
    close( $fh );

    open( $fh, ">", $sysfs_path . "/device/delete" ) or die "Could not open file \"$sysfs_path/device/delete\" for writing.\n";
    print $fh "1";
    close( $fh );
  }
  return 1;
}

sub purestorage_cleanup_diskmap {
  my ( $class ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_cleanup_diskmap\n" if $DEBUG;

  my @disks = `lsblk -o NAME,TYPE,SIZE -nr`;

  foreach my $disk_name ( @disks ) {
    my ( $name, $type, $size ) = split( /\s+/, $disk_name );

    if ( $type eq 'disk' && $size eq '0B' ) {
      $class->purestorage_unmap_disk( $name );
    }
  }

  return 1;
}

sub purestorage_volume_connection {
  my ( $class, $scfg, $volname, $mode ) = @_;

  my $method = $mode ? 'POST' : 'DELETE';
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_volume_connection :: $method\n" if $DEBUG;

  my $hname    = PVE::INotify::nodename();
  my $hgsuffix = $scfg->{ hgsuffix } // $default_hgsuffix;
  $hname .= "-" . $hgsuffix if $hgsuffix ne "";

  my $name;
  my $ignore;
  if ( $mode ) {
    $name   = 'create volume connection';
    $ignore = 'Connection already exists.';
  } else {
    $name   = 'delete volume connection';
    $ignore = [ 'Volume has been destroyed.', 'Connection does not exist.' ];
  }

  my $action = {
    name   => $name,
    type   => 'connections',
    method => $method,
    ignore => $ignore,
    params => {
      host_names   => $hname,
      volume_names => purestorage_name( $scfg, $volname )
    }
  };

  my $response = purestorage_api_request( $scfg, $action );

  my $message = ( $response->{ errors } ? 'already ' : '' ) . ( $mode ? 'connected to' : 'disconnected from' );
  print "Info :: Volume \"$volname\" is $message host \"$hname\".\n";
  return 1;
}

sub purestorage_create_volume {
  my ( $class, $scfg, $volname, $size, $storeid ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_create_volume\n" if $DEBUG;

  my $action = {
    name   => 'create volume',
    type   => 'volumes',
    method => 'POST',
    params => { names       => purestorage_name( $scfg, $volname ) },
    body   => { provisioned => $size }
  };

  my $response = purestorage_api_request( $scfg, $action );

  my $serial = $response->{ items }->[0]->{ serial } or die "Error :: Failed to retrieve volume serial";
  print "Info :: Volume \"$volname\" is created (serial=$serial).\n";

  return 1;
}

sub purestorage_remove_volume {
  my ( $class, $scfg, $volname, $storeid, $eradicate ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_remove_volume\n" if $DEBUG;

  if ( $volname =~ /^vm-(\d+)-(cloudinit|state-.+)/ ) {
    $eradicate = 1;
  } else {
    $eradicate //= 0;
  }

  my $params = { names => purestorage_name( $scfg, $volname ) };
  my $action = {
    name   => 'destroy volume',
    type   => 'volumes',
    method => 'PATCH',
    ignore => 'Volume has been deleted.',
    params => $params,
    body   => { destroyed => \1 }
  };

  my $response = purestorage_api_request( $scfg, $action );

  my $message = ( $response->{ errors } ? 'already ' : '' ) . 'destroyed';
  print "Info :: Volume \"$volname\" is $message.\n";

  if ( $eradicate ) {
    $action = {
      name   => 'eradicate volume',
      type   => 'volumes',
      method => 'DELETE',
      params => $params,
    };

    purestorage_api_request( $scfg, $action );

    print "Info :: Volume \"$volname\" is eradicated.\n";
  }

  return 1;
}

sub purestorage_get_device_size {
  my ( $class, $path ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_get_device_size\n" if $DEBUG;
  my $size = 0;

  exec_command(
    [ $cmd->{ blockdev }, '--getsize64', $path ],
    1,
    outfunc => sub {
      $size = $_[0];
      chomp $size;
    }
  );

  print "Debug :: Detected size: $size\n" if $DEBUG;
  return $size;
}

sub purestorage_resize_volume {
  my ( $class, $scfg, $volname, $size ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_resize_volume\n" if $DEBUG;

  my $action = {
    name   => 'resize volume',
    type   => 'volumes',
    method => 'PATCH',
    params => { names       => purestorage_name( $scfg, $volname ) },
    body   => { provisioned => $size }
  };

  purestorage_api_request( $scfg, $action );

  print "Info :: Volume \"$volname\" is resized.\n";

  my ( $path, $wwid ) = $class->purestorage_get_wwn( $scfg, $volname );

  exec_command( [ $cmd->{ iscsiadm }, '--mode', 'node', '--rescan' ], 1 );

  # FIXME: wwid is probably ignored
  exec_command( [ $cmd->{ multipath }, '-r', $wwid ], 1 );

  # Wait for the device size to update
  my $iteration    = 0;
  my $max_attempts = 15;    # Max iter count
  my $interval     = 1;     # Interval for checking in seconds
  my $new_size     = 0;

  print "Debug :: Expected size = $size\n" if $DEBUG;

  while ( $iteration < $max_attempts ) {
    print "Info :: Waiting (" . $iteration . "s) for size update for volume \"$volname\"...\n";

    $new_size = $class->purestorage_get_device_size( $path );
    if ( $new_size >= $size ) {
      print "Info :: New size detected for volume \"$volname\": $new_size bytes.\n";
      return $new_size;
    }

    sleep $interval;
    ++$iteration;
  }

  die "Error :: Timeout while waiting for updated size of volume \"$volname\".\n";
}

sub purestorage_rename_volume {
  my ( $class, $scfg, $source_volname, $target_volname ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_rename_volume\n" if $DEBUG;

  my $action = {
    name   => 'rename volume',
    type   => 'volumes',
    method => 'PATCH',
    params => { names => purestorage_name( $scfg, $source_volname ) },
    body   => { name  => purestorage_name( $scfg, $target_volname ) }
  };

  purestorage_api_request( $scfg, $action );

  print "Info :: Volume \"$source_volname\" is renamed to \"$target_volname\".\n";

  return 1;
}

sub purestorage_snap_volume_create {
  my ( $class, $scfg, $snap_name, $volname ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_snap_volume_create\n" if $DEBUG;

  my $action = {
    name   => 'create volume snapshot',
    type   => 'volume-snapshots',
    method => 'POST',
    params => {
      source_names => purestorage_name( $scfg, $volname ),
      suffix       => purestorage_name( $scfg, undef, $snap_name )
    }
  };

  purestorage_api_request( $scfg, $action );

  print "Info :: Volume \"$volname\" snapshot \"$snap_name\" is created.\n";
  return 1;
}

sub purestorage_volume_restore {
  my ( $class, $scfg, $volname, $svolname, $snap, $overwrite ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_volume_restore\n" if $DEBUG;

  my $params = { names => purestorage_name( $scfg, $volname ) };
  $params->{ overwrite } = $overwrite ? 'true' : 'false' if defined $overwrite;

  my $action = {
    name   => 'restore volume',
    type   => 'volumes',
    method => 'POST',
    params => $params,
    body   => {
      source => {
        name => purestorage_name( $scfg, $svolname, $snap )
      }
    }
  };

  purestorage_api_request( $scfg, $action );

  my $source = length( $snap ) ? 'snapshot "' . $snap . '"' : '';
  if ( $volname ne $svolname ) {
    $source .= ' of ' if $source ne '';
    $source .= 'volume "' . $svolname . '"';
  }
  $source = ' from ' . $source if $source ne '';

  print "Info :: Volume \"$volname\" is restored$source.\n";
}

sub purestorage_snap_volume_delete {
  my ( $class, $scfg, $snap_name, $volname ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_snap_volume_delete\n" if $DEBUG;

  my $params = { names => purestorage_name( $scfg, $volname, $snap_name ) };
  my $action = {
    name   => 'destroy volume snapshot',
    type   => 'volume-snapshots',
    method => 'PATCH',
    ignore =>
      [ 'Volume snapshot has been destroyed. It can be recovered by purevol recover and eradicated by purevol eradicate.', 'No such volume or snapshot.' ],
    params => $params,
    body   => { destroyed => \1 }
  };
  my $response = purestorage_api_request( $scfg, $action );

  my $message = ( $response->{ errors } ? 'already ' : '' ) . 'destroyed';
  print "Info :: Volume \"$volname\" snapshot \"$snap_name\" is $message.\n";

  #FIXME: Pure FA API states that replication_snapshot is query (not body) parameter
  $action = {
    name   => 'eradicate volume snapshot',
    type   => 'volume-snapshots',
    method => 'DELETE',
    ignore => 'No such volume or snapshot.',
    params => $params,
    body   => { replication_snapshot => \1 }
  };
  $response = purestorage_api_request( $scfg, $action );

  $message = ( $response->{ errors } ? 'already ' : '' ) . 'eradicated';
  print "Info :: Volume \"$volname\" snapshot \"$snap_name\" is $message.\n";
  return 1;
}

### BLOCK: Storage implementation

sub parse_volname {
  my ( $class, $volname ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::parse_volname\n" if $DEBUG;

  if ( $volname =~ m/^(vm|base)-(\d+)-(\S+)$/ ) {
    my $vtype = ( $1 eq "vm" ) ? "images" : "base";    # Determine volume type
    my $vmid  = $2;                                    # Extract VMID
    my $name  = $3;                                    # Remaining part of the volume name

    # ($vtype, $name, $vmid, $basename, $basevmid, $isBase, $format)
    return ( $vtype, $name, $vmid, undef, undef, undef, 'raw' );
  }

  die "Error :: Invalid volume name ($volname).\n";
  return 0;
}

sub filesystem_path {
  my ( $class, $scfg, $volname, $snapname ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::filesystem_path\n" if $DEBUG;

  # do we even need this?
  my ( $vtype, undef, $vmid ) = $class->parse_volname( $volname );

  my ( $path, $wwid ) = $class->purestorage_get_wwn( $scfg, $volname );

  if ( !defined( $path ) || !defined( $vmid ) || !defined( $vtype ) ) {
    return wantarray ? ( "", "", "", "" ) : "";
  }

  return wantarray ? ( $path, $vmid, $vtype, $wwid ) : $path;
}

sub create_base {
  my ( $class, $storeid, $scfg, $volname ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::create_base\n" if $DEBUG;
  die "Error :: Creating base image is currently unimplemented.\n";
}

sub clone_image {
  my ( $class, $scfg, $storeid, $volname, $vmid, $snap ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::clone_image\n" if $DEBUG;

  my $name = $class->find_free_diskname( $storeid, $scfg, $vmid );

  $class->purestorage_volume_restore( $scfg, $name, $volname, $snap );

  return $name;
}

sub find_free_diskname {
  my ( $class, $storeid, $scfg, $vmid, $fmt, $add_fmt_suffix ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::find_free_diskname\n" if $DEBUG;

  my $volumes   = $class->purestorage_list_volumes( $scfg, $vmid, $storeid );
  my @disk_list = map { $_->{ name } } @$volumes;

  return PVE::Storage::Plugin::get_next_vm_diskname( \@disk_list, $storeid, $vmid, undef, $scfg );
}

sub alloc_image {
  my ( $class, $storeid, $scfg, $vmid, $fmt, $name, $size ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::alloc_image\n" if $DEBUG;

  # Check for supported format (only 'raw' is allowed)
  die "Error :: Unsupported format ($fmt).\n" if $fmt ne 'raw';

  # Validate the name format, should start with 'vm-$vmid-disk'
  if ( defined( $name ) ) {
    die "Error :: Illegal name \"$name\" - should be \"vm-$vmid-(disk-*|cloudinit|state-*)\".\n" if $name !~ m/^vm-$vmid-(disk-|cloudinit|state-)/;
  } else {
    $name = $class->find_free_diskname( $storeid, $scfg, $vmid );
  }

  # Check size (must be between 1MB and 4PB)
  if ( $size < 1024 ) {
    print "Info :: Size is too small ($size kb), adjusting to 1024 kb\n";
    $size = 1024;
  }

  # Convert size from KB to bytes
  my $sizeB = $size * 1024;    # KB => B

  if ( !$class->purestorage_create_volume( $scfg, $name, $sizeB, $storeid ) ) {
    die "Error :: Failed to create volume \"$name\".\n";
  }

  return $name;
}

sub free_image {
  my ( $class, $storeid, $scfg, $volname, $isBase ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::free_image\n" if $DEBUG;

  $class->deactivate_volume( $storeid, $scfg, $volname );

  $class->purestorage_remove_volume( $scfg, $volname, $storeid );

  return undef;
}

sub list_images {
  my ( $class, $storeid, $scfg, $vmid, $vollist, $cache ) = @_;

  my $key = type() . ':' . $storeid;
  if ( $cache->{ $key } ) {
    print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::list_images::cached\n" if $DEBUG;
  } else {
    print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::list_images\n" if $DEBUG;
    $cache->{ $key } = $class->purestorage_list_volumes( $scfg, $vmid, $storeid, 0 );
  }

  return $cache->{ $key };
}

sub status {
  my ( $class, $storeid, $scfg, $cache ) = @_;

  $cache = $cache->{ type() . ':' . $storeid } //= {};
  $cache->{ last_update } //= 0;

  my $current_time = gettimeofday();
  if ( $current_time - $cache->{ last_update } >= 60 ) {
    print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::status\n" if $DEBUG;

    my $response = purestorage_api_request( $scfg, { name => 'get array space', type => 'arrays/space', method => 'GET' } );

    # Get storage capacity and used space from the response
    $cache->{ total } = $response->{ items }->[0]->{ capacity };
    $cache->{ used }  = $response->{ items }->[0]->{ space }->{ total_physical };

    # $cache->{ used } = $response->{ items }->[0]->{ space }->{ total_used }; # Do not know what is correct

    $cache->{ last_update } = $current_time;
  } else {
    print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::status::cached\n" if $DEBUG;
  }

  # Calculate free space
  my $free = $cache->{ total } - $cache->{ used };

  # Mark storage as active
  my $active = 1;

  # Return total, free, used space and the active status
  return ( $cache->{ total }, $free, $cache->{ used }, $active );
}

sub activate_storage {
  my ( $class, $storeid, $scfg, $cache ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::activate_storage\n" if $DEBUG;

  #FIXME: Why is this needed?
  $class->purestorage_cleanup_diskmap();

  return 1;
}

sub deactivate_storage {
  my ( $class, $storeid, $scfg, $cache ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::deactivate_storage\n" if $DEBUG;

  return 1;
}

sub volume_size_info {
  my ( $class, $scfg, $storeid, $volname, $timeout ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::volume_size_info\n" if $DEBUG;

  my $volume = $class->purestorage_get_existing_volume_info( $scfg, $volname );

  #TODO: Consider moving this inside of purestorage_get_existing_volume_info()
  die "Error :: PureStorage API :: No volume data found for \"$volname\".\n" unless $volume;

  print "Debug :: Provisioned: " . $volume->{ size } . ", Used: " . $volume->{ used } . "\n" if $DEBUG;

  return wantarray ? ( $volume->{ size }, 'raw', $volume->{ used }, undef ) : $volume->{ size };
}

sub map_volume {
  my ( $class, $storeid, $scfg, $volname, $snapname ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::map_volume\n" if $DEBUG;
  my ( $path, $wwid ) = $class->purestorage_get_wwn( $scfg, $volname );

  print "Debug :: Mapping volume \"$volname\" with WWN: " . uc( $wwid ) . ".\n" if $DEBUG;

  exec_command( [ $cmd->{ multipath }, '-a', $wwid ], 1 );

  exec_command( [ $cmd->{ iscsiadm }, '--mode', 'session', '--rescan' ], 1 );

  # Wait for the device to apear
  my $iteration    = 0;
  my $max_attempts = 15;
  my $interval     = 1;

  while ( $iteration < $max_attempts ) {
    print "Info :: Waiting (" . $iteration . "s) for map volume \"$volname\"...\n";
    $iteration++;
    if ( -e $path ) {
      return $path;
    }
    sleep $interval;
  }

  die "Error :: Local path \"$path\" does not exist.\n";
}

sub unmap_volume {
  my ( $class, $storeid, $scfg, $volname, $snapname ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::unmap_volume\n" if $DEBUG;

  my ( $path, undef, undef, $wwid ) = $class->filesystem_path( $scfg, $volname );

  if ( $path && -b $path ) {
    my $device_path = abs_path( $path );
    if ( defined( $device_path ) ) {
      print "Info :: Device path resolved to \"$device_path\".\n";
    } else {
      die "Error :: unable to get device path for $path - $!.\n";
    }

    exec_command( [ $cmd->{ blockdev }, '--flushbufs', $path ] );

    my $iteration = 0;
    my $max_attempts = 30;
    my $interval = 1;
    my $in_use = 1;
    my $safe_device_path = $device_path =~ m/^([\/a-zA-Z0-9_\-\.]+)$/;

    while ( $iteration < $max_attempts ) {
      
      eval {run_command( [ $cmd->{ fuser }, "$safe_device_path" ], quiet => 1)};
      if ($@) {
        $in_use = 0;
        last;
      }

      print qq{Warning :: Device "$volname" in use. Waiting (duration $iteration sec)\n};
      $iteration++;
      sleep $interval;
    } 
    die qq{Error :: device "$device_path" is still in use!.\n} unless(!$in_use);

    my $device_name = basename( $device_path );
    my $slaves_path = "/sys/block/$device_name/slaves";

    my @slaves = ();
    if ( -d $slaves_path ) {
      opendir( my $dh, $slaves_path ) or die "Cannot open directory: $!";
      @slaves = grep { !/^\.\.?$/ } readdir( $dh );
      closedir( $dh );
      print "Info :: Disk \"$device_name\" slaves: " . join( ', ', @slaves ) . "\n" if $DEBUG;
    } elsif ( $device_name =~ m|^(sd[a-z]+)$| ) {
      warn "Warning :: Disk \"$device_name\" has no slaves.\n";
      push @slaves, $1;
    }

    my $multipath_check = `$cmd->{ "multipath" } -l $wwid`;
    if ( $multipath_check ) {
      print "Info :: Device \"$device_path\" is a multipath device. Proceeding with multipath removal.\n";
      exec_command( [ $cmd->{ multipath }, '-w', $wwid ] );

      # remove the link
      exec_command( [ $cmd->{ multipath }, '-f', $wwid ] );
    } else {
      print "Info :: Device \"$wwid\" is not a multipath device. Skipping multipath removal.\n";
    }

    # Iterate through slaves and delete each device
    foreach my $slave_name ( @slaves ) {
      print "Info :: Remove slave: $slave_name\n" if $DEBUG;
      if ( $slave_name =~ m|^(sd[a-z]+)$| ) {
        $slave_name = $1;    # untaint;
        $class->purestorage_unmap_disk( $slave_name );
      } else {
        die "Error :: Invalid disk name \"$slave_name\".";
      }
    }

    print "Info :: Device \"$device_name\" removed from system.\n";
    return 1;
  }

  return 0;
}

sub activate_volume {
  my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::activate_volume\n" if $DEBUG;

  $class->purestorage_volume_connection( $scfg, $volname, 1 );

  $class->map_volume( $storeid, $scfg, $volname, $snapname );
  return 1;
}

sub deactivate_volume {
  my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::deactivate_volume\n" if $DEBUG;

  $class->unmap_volume( $storeid, $scfg, $volname, $snapname );

  $class->purestorage_volume_connection( $scfg, $volname, 0 );

  print "Info :: Volume \"$volname\" is deactivated.\n";

  return 1;
}

sub volume_resize {
  my ( $class, $scfg, $storeid, $volname, $size, $running ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::volume_resize\n" if $DEBUG;
  warn "Debug :: New Size: $size\n"                                              if $DEBUG;

  return $class->purestorage_resize_volume( $scfg, $volname, $size );
}

sub rename_volume {
  my ( $class, $scfg, $storeid, $source_volname, $target_vmid, $target_volname ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::rename_volume\n" if $DEBUG;

  die "Error :: not implemented in storage plugin \"$class\".\n" if $class->can( 'api' ) && $class->api() < 10;

  if ( length( $target_volname ) ) {

    # See RBDPlugin.pm (note, currently PVE does not supply $target_volname parameter)
    my $volume = $class->purestorage_get_volume_info( $scfg, $target_volname, $storeid );
    die "target volume '$target_volname' already exists\n" if $volume;
  } else {
    $target_volname = $class->find_free_diskname( $storeid, $scfg, $target_vmid );
  }

  # we need to unmap source volume (see RBDPlugin.pm)
  $class->unmap_volume( $storeid, $scfg, $source_volname );

  $class->purestorage_rename_volume( $scfg, $source_volname, $target_volname );

  return "$storeid:$target_volname";
}

sub volume_import {
  my ( $class, $scfg, $storeid, $fh, $volname, $format, $snapshot, $base_snapshot, $with_snapshots, $allow_rename ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::volume_import\n" if $DEBUG;
  die "=> PVE::Storage::Custom::PureStoragePlugin::sub::volume_import not implemented!";

  return 1;
}

sub volume_snapshot {
  my ( $class, $scfg, $storeid, $volname, $snap ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::volume_snapshot\n" if $DEBUG;

  $class->purestorage_snap_volume_create( $scfg, $snap, $volname );

  return 1;
}

sub volume_snapshot_rollback {
  my ( $class, $scfg, $storeid, $volname, $snap ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::volume_snapshot_rollback\n" if $DEBUG;

  $class->purestorage_volume_restore( $scfg, $volname, $volname, $snap, 1 );

  return 1;
}

sub volume_snapshot_delete {
  my ( $class, $scfg, $storeid, $volname, $snap ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::volume_snapshot_delete\n" if $DEBUG;

  $class->purestorage_snap_volume_delete( $scfg, $snap, $volname );

  return 1;
}

sub volume_has_feature {
  my ( $class, $scfg, $feature, $storeid, $volname, $snapname, $running ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::volume_has_feature\n" if $DEBUG;

  my $features = {
    copy       => { current => 1, snap => 1 },    # full clone is possible
    clone      => { current => 1, snap => 1 },    # linked clone is possible
    snapshot   => { current => 1 },               # taking a snapshot is possible
                                                  # template => { current => 1 }, # conversion to base image is possible
    sparseinit => { current => 1 },               # thin provisioning is supported
    rename     => { current => 1 },               # renaming volumes is possible
  };
  my ( $vtype, $name, $vmid, $basename, $basevmid, $isBase ) = $class->parse_volname( $volname );
  my $key;
  if ( $snapname ) {
    $key = "snap";
  } else {
    $key = $isBase ? "base" : "current";
  }
  return 1 if $features->{ $feature }->{ $key };
  return undef;
}
1;
