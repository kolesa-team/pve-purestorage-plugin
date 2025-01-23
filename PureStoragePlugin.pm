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
    vgname    => { fixed    => 1 },
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

### BLOCK: Local multipath => PVE::Storage::Custom::PureStoragePlugin::sub::s

sub purestorage_request {
  my ( $class, $scfg, $type, $method, $params, $body, $attempt ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_request\n" if $DEBUG;

  my $api          = "2.26";
  my $url          = $scfg->{ address };
  my $check_ssl    = $scfg->{ check_ssl } ? 1 : 0;
  my $max_attempts = 5;
  my $interval     = 1;
  $attempt //= 1;    # Initialize the attempt counter to 1 if not provided

  $url .= "/api/$api/$type";
  $url .= "?$params" if $params;

  my $token =
      $type eq "login"
    ? $scfg->{ token }
    : $class->purestorage_get_auth_token( $scfg );

  my $headers = HTTP::Headers->new(
    ( $type eq "login" ? "api-token" : "x-auth-token" ) => $token,
    "Content-Type"                                      => "application/json"
  );

  if ( $scfg->{ x_request_id } ) {
    $headers->header( "X-Request-ID" => $scfg->{ x_request_id } );
  }

  my $ua = LWP::UserAgent->new;
  $ua->ssl_opts(
    verify_hostname => 0,
    SSL_verify_mode => 0x00
  ) if !$check_ssl;

  my $request  = HTTP::Request->new( $method, $url, $headers, $body ? encode_json( $body ) : undef );
  my $response = $ua->request( $request );

  my $content_type = $response->header( "Content-Type" );
  my $content =
    defined $content_type && $content_type =~ /application\/json/ && $response->content ne ""
    ? decode_json( $response->content )
    : $response->decoded_content;

  if ( !$response->is_success ) {
    if ( $response->code == 401 && $attempt < $max_attempts ) {
      $attempt++;
      print "Error :: Invalid session. Retrying... Attempt: " . ( $attempt ) . "\n";

      # Reset the token cache
      $scfg->{ x_auth_token } = 0;

      sleep $interval;

      # Recursively call the function with an incremented attempt counter
      return $class->purestorage_request( $scfg, $type, $method, $params, $body, $attempt );
    }
  }

  return {
    content => $content,
    headers => $response->headers,
    error   => $response->is_success ? undef : $response->code,
  };
}

sub purestorage_get_auth_token {
  my ( $class, $scfg ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_get_auth_token\n" if $DEBUG;

  if ( !$scfg->{ x_auth_token } ) {
    my $response = $class->purestorage_request( $scfg, "login", "POST" );

    if ( $response->{ error } ) {
      die "Error :: PureStorage API :: Authentication failed.\n" . "=> Trace:\n" . "==> Code: " . $response->{ error } . "\n" . $response->{ content }
        ? "==> Message: " . Dumper( $response->{ content } )
        : "";
    }

    $scfg->{ x_auth_token } = $response->{ headers }->header( "x-auth-token" ) || die "Header 'x-auth-token' missing.";
    if ( $response->{ headers }->header( "x-request-id" ) ) {
      $scfg->{ x_request_id } = $response->{ headers }->header( "x-request-id" );
    }
  } else {
    print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_get_auth_token::cached\n" if $DEBUG;
  }
  return $scfg->{ x_auth_token };
}

sub purestorage_volume_info {
  my ( $class, $scfg, $volname ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_volume_info\n" if $DEBUG;
  my $vgname = $scfg->{ vgname } || die "Error :: Volume group name is not defined.\n";

  $scfg->{ cache }                                                                  ||= {};
  $scfg->{ cache }->{ volume_info }                                                 ||= {};
  $scfg->{ cache }->{ volume_info }->{ "$vgname" }                                  ||= {};
  $scfg->{ cache }->{ volume_info }->{ "$vgname" }->{ "$volname" }                  ||= {};
  $scfg->{ cache }->{ volume_info }->{ "$vgname" }->{ "$volname" }->{ last_update } ||= 0;
  my $current_time = gettimeofday();

  if ( $current_time - $scfg->{ cache }->{ volume_info }->{ "$vgname" }->{ "$volname" }->{ last_update } >= 60 ) {

    my $filter   = "name='$vgname/$volname'";
    my $response = $class->purestorage_request( $scfg, "volumes", "GET", "filter=" . uri_escape( $filter ) );

    if ( $response->{ error } ) {
      die "Error :: PureStorage API :: Get volume \"$vgname/$volname\" info failed.\n"
        . "=> Trace:\n"
        . "==> Code: "
        . $response->{ error } . "\n"
        . ( $response->{ content } ? "==> Message: " . Dumper( $response->{ content } ) : "" );
    }

    my $volumes = $response->{ content }->{ items };
    unless ( ref( $volumes ) eq 'ARRAY' && @$volumes ) {
      die "Error :: PureStorage API :: No volume data found for \"$vgname/$volname\".\n";
    }

    my $volume = $volumes->[0];
    $scfg->{ cache }->{ volume_info }->{ "$vgname" }->{ "$volname" } = {
      size        => $volume->{ provisioned }           || 0,
      used        => $volume->{ space }->{ total_used } || 0,
      last_update => $current_time,
    };

    print "Debug :: curtime: " . $current_time . " " . $scfg->{ cache }->{ volume_info }->{ "$vgname" }->{ "$volname" }->{ last_update } . "\n";
    print "Debug :: Provisioned: "
      . $scfg->{ cache }->{ volume_info }->{ "$vgname" }->{ "$volname" }->{ size }
      . ", Used: "
      . $scfg->{ cache }->{ volume_info }->{ "$vgname" }->{ "$volname" }->{ used } . "\n"
      if $DEBUG;

    print "Debug :: Provisioned: " . $volume->{ provisioned } . ", Used: " . $volume->{ space }->{ total_used } . "\n"
      if $DEBUG;
  } else {
    print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_volume_info::cached\n" if $DEBUG;
  }

  return (
    $scfg->{ cache }->{ volume_info }->{ "$vgname" }->{ "$volname" }->{ size },
    $scfg->{ cache }->{ volume_info }->{ "$vgname" }->{ "$volname" }->{ used }
  );
}

sub purestorage_list_volumes {
  my ( $class, $scfg, $vmid, $storeid, $destroyed ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_list_volumes\n" if $DEBUG;

  my $names = defined( $vmid ) ? "vm-$vmid-disk-*,vm-$vmid-cloudinit,vm-$vmid-state-*" : "*";

  return $class->purestorage_get_volumes( $scfg, $names, $storeid, $destroyed );
}

sub purestorage_get_volumes {
  my ( $class, $scfg, $names, $storeid, $destroyed ) = @_;
  my $vgname = $scfg->{ vgname } || die "Error :: Volume group name is not defined.\n";

  my @names_list = map { "name='$vgname/$_'" } split( ',', $names );

  my $filter = join( ' or ', @names_list );

  if ( defined( $destroyed ) ) {
    $filter = '(' . $filter . ')' if $#names_list > 0;
    $filter .= " and destroyed='" . ( $destroyed ? "true" : "false" ) . "'";
  }

  my $response = $class->purestorage_request( $scfg, "volumes", "GET", "filter=" . uri_escape( $filter ) );
  if ( $response->{ error } ) {
    die "Error :: PureStorage API :: List volumes status failed.\n"
      . "=> Trace:\n"
      . "==> Code: "
      . $response->{ error } . "\n"
      . ( $response->{ content } ? "==> Message: " . Dumper( $response->{ content } ) : "" );
  }

  my @volumes = map {
    my $volname = $_->{ name };

    $volname =~ s/^$scfg->{vgname}\///;

    my ( undef, undef, $volvm ) = $class->parse_volname( $volname );

    my $ctime = int( $_->{ created } / 1000 );
    {
      name   => $volname,
      vmid   => $volvm,
      serial => $_->{ serial },
      size   => $_->{ provisioned },
      ctime  => $ctime,
      volid  => $storeid ? "$storeid:$volname" : $volname,
      format => 'raw'
    }
  } @{ $response->{ content }->{ items } };

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

  return 0;
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
  my ( $class, $scfg, $volname, $action ) = @_;

  $action //= 'POST';

  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_volume_connection :: $action\n" if $DEBUG;

  my $vgname = $scfg->{ vgname }  || die "Error :: Volume group name is not defined.\n";
  my $url    = $scfg->{ address } || die "Error :: Pure Storage host is not defined.\n";

  my $hname    = PVE::INotify::nodename();
  my $hgsuffix = $scfg->{ hgsuffix } // $default_hgsuffix;
  $hname .= "-" . $hgsuffix if $hgsuffix ne "";

  my $params = "host_names=$hname&volume_names=$vgname/$volname";

  my $response = $class->purestorage_request( $scfg, "connections", $action, $params );
  my $message;
  if ( $response->{ error } ) {
    $message = $response->{ content }->{ errors }->[0]->{ message } || '*';
    if ( $message eq "Connection already exists." ) {
      $message = '' if $action eq 'POST';
    } elsif ( $message eq "Volume has been destroyed." || $message eq "Connection does not exist." ) {
      $message = '' if $action eq 'DELETE';
    }
    if ( $message ne '' ) {
      $Data::Dumper::Indent = 0;
      die "Error :: PureStorage API :: Failed to modify connection.\n"
        . "=> Trace:\n"
        . "==> Code: "
        . $response->{ error } . "\n"
        . ( $response->{ content } ? "==> Message: " . Dumper( $response->{ content } ) : "" );
    }
    $message = 'was already';
  } else {
    $message = 'is';
  }

  $message .= ' ' . ( $action eq 'DELETE' ? 'removed from' : 'added to' );
  print "Info :: Volume \"$vgname/$volname\" $message host \"$hname\".\n";
  return 1;
}

sub purestorage_create_volume {
  my ( $class, $scfg, $volname, $size, $storeid ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_create_volume\n" if $DEBUG;

  my $vgname = $scfg->{ vgname }  || die "Error :: Volume group name is not defined.\n";
  my $url    = $scfg->{ address } || die "Error :: Pure Storage host is not defined.\n";

  my $params    = "names=$vgname/$volname";
  my $volparams = { "provisioned" => $size };

  my $response = $class->purestorage_request( $scfg, "volumes", "POST", $params, $volparams );
  if ( $response->{ error } ) {
    die "Error :: PureStorage API :: Create volume failed.\n"
      . "=> Trace:\n"
      . "==> Code: "
      . $response->{ error } . "\n"
      . ( $response->{ content } ? "==> Message: " . Dumper( $response->{ content } ) : "" );
  }

  my $serial = $response->{ content }->{ items }->[0]->{ serial } || die "Error :: Failed to retrieve volume serial";
  print "Info :: Volume \"$vgname/$volname\" created (serial=$serial).\n";

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

  my $vgname = $scfg->{ vgname }  || die "Error :: Volume group name is not defined.\n";
  my $url    = $scfg->{ address } || die "Error :: Pure Storage host is not defined.\n";

  my $params = "names=$vgname/$volname";
  my $body   = { destroyed => \1 };

  my $response = $class->purestorage_request( $scfg, "volumes", "PATCH", $params, $body );
  if ( $response->{ error } ) {
    if ( $response->{ content }->{ errors }->[0]->{ message } eq "Volume has been deleted." ) {
      warn "Warning :: PureStorage API :: Destroy volume failed :: Nothing to remove.\n"
        . "=> Trace:\n"
        . "==> Code: "
        . $response->{ error } . "\n"
        . ( $response->{ content } ? "==> Message: " . Dumper( $response->{ content } ) : "" );
    } else {
      $Data::Dumper::Indent = 0;
      die "Error :: PureStorage API :: Destroy volume \"$vgname/$volname\" failed.\n"
        . "=> Trace:\n"
        . "==> Code: "
        . $response->{ error } . "\n"
        . ( $response->{ content } ? "==> Message: " . Dumper( $response->{ content } ) : "" );
    }
  } else {
    print "Info :: Volume \"$vgname/$volname\" destroyed.\n";
  }

  if ( $eradicate ) {
    $response = $class->purestorage_request( $scfg, "volumes", "DELETE", $params );
    if ( $response->{ error } ) {
      $Data::Dumper::Indent = 0;
      die "Error :: PureStorage API :: Eradicate volume \"$vgname/$volname\" failed.\n"
        . "=> Trace:\n"
        . "==> Code: "
        . $response->{ error } . "\n"
        . ( $response->{ content } ? "==> Message: " . Dumper( $response->{ content } ) : "" );
    } else {
      print "Info :: Volume \"$vgname/$volname\" eradicated.\n";
    }
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

  my $vgname = $scfg->{ vgname }  || die "Error :: Volume group name is not defined.\n";
  my $url    = $scfg->{ address } || die "Error :: Pure Storage host is not defined.\n";

  $scfg->{ cache }                                 ||= {};
  $scfg->{ cache }->{ volume_info }                ||= {};
  $scfg->{ cache }->{ volume_info }->{ "$vgname" } ||= {};
  $scfg->{ cache }->{ volume_info }->{ "$vgname" }->{ "$volname" } = {};

  my $params    = "names=$vgname/$volname";
  my $volparams = { "provisioned" => $size };
  my $response  = $class->purestorage_request( $scfg, "volumes", "PATCH", $params, $volparams );
  if ( $response->{ error } ) {
    die "Error :: PureStorage API :: Resize volume failed.\n"
      . "=> Trace:\n"
      . "==> Code: "
      . $response->{ error } . "\n"
      . ( $response->{ content } ? "==> Message: " . Dumper( $response->{ content } ) : "" );
  }

  print "Info :: Volume \"$vgname/$volname\" resized.\n";

  my ( $path, undef, undef, $wwid ) = $class->filesystem_path( $scfg, $volname );

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
    print "Info :: Waiting (" . $iteration . "s) for size update for volume \"$vgname/$volname\"...\n";

    $new_size = $class->purestorage_get_device_size( $path );
    if ( $new_size >= $size ) {
      print "Info :: New size detected for volume \"$vgname/$volname\": $new_size bytes.\n";
      return $new_size;
    }

    sleep $interval;
    ++$iteration;
  }

  die "Error :: Timeout while waiting for updated size of volume \"$vgname/$volname\".\n";
}

sub purestorage_rename_volume {
  my ( $class, $scfg, $source_volname, $target_volname ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_rename_volume\n" if $DEBUG;

  my $vgname    = $scfg->{ vgname }  || die "Error :: Volume group name is not defined.\n";
  my $url       = $scfg->{ address } || die "Error :: Pure Storage host is not defined.\n";
  my $params    = "names=$vgname/$source_volname";
  my $volparams = { "name" => "$vgname/$target_volname" };
  my $response  = $class->purestorage_request( $scfg, "volumes", "PATCH", $params, $volparams );

  if ( $response->{ error } ) {
    die "Error :: PureStorage API :: Rename volume failed.\n"
      . "=> Trace:\n"
      . "==> Code: "
      . $response->{ error } . "\n"
      . ( $response->{ content } ? "==> Message: " . Dumper( $response->{ content } ) : "" );
  }

  print "Info :: Volume \"$vgname/$source_volname\" renamed to \"$vgname/$target_volname\".\n";

  return 1;
}

sub purestorage_snap_volume_create {
  my ( $class, $scfg, $snap_name, $volname ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_snap_volume_create\n" if $DEBUG;

  my $vgname = $scfg->{ vgname } || die "Error :: Volume group name is not defined.\n";
  my $params;
  my $response;

  $params = "source_names=$vgname/$volname&suffix=snap-$snap_name";

  $response = $class->purestorage_request( $scfg, "volume-snapshots", "POST", $params );

  if ( $response->{ error } ) {
    die "Error :: PureStorage API :: Snapshot volume failed.\n"
      . "=> Trace:\n"
      . "==> Code: "
      . $response->{ error } . "\n"
      . ( $response->{ content } ? "==> Message: " . Dumper( $response->{ content } ) : "" );
  }

  print "Info :: Volume \"$vgname/$volname\" snapshot \"$snap_name\" created.\n";
  return 1;
}

sub purestorage_snap_volume_rollback {
  my ( $class, $scfg, $snap_name, $volname ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_snap_volume_rollback\n" if $DEBUG;

  my $vgname = $scfg->{ vgname } || die "Error :: Volume group name is not defined.\n";
  my $params;
  my $response;
  my $body;

  $params = "names=$vgname/$volname&overwrite=true";
  $body   = {
    source => {
      name => "$vgname/$volname.snap-$snap_name"
    }
  };

  $response = $class->purestorage_request( $scfg, "volumes", "POST", $params, $body );

  if ( $response->{ error } ) {
    die "Error :: PureStorage API :: Restore volume snapshot failed.\n"
      . "=> Trace:\n"
      . "==> Code: "
      . $response->{ error } . "\n"
      . ( $response->{ content } ? "==> Message: " . Dumper( $response->{ content } ) : "" );
  }

  print "Info :: Volume \"$vgname/$volname\" snapshot \"$snap_name\" restored.\n";
  return $volname;
}

sub purestorage_snap_volume_delete {
  my ( $class, $scfg, $snap_name, $volname ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_snap_volume_delete\n" if $DEBUG;

  my $vgname = $scfg->{ vgname } || die "Error :: Volume group name is not defined.\n";
  my $params;

  my $response;
  my $body;

  $params = "names=$vgname/$volname.snap-$snap_name";
  $body   = { destroyed => \1 };

  $response = $class->purestorage_request( $scfg, "volume-snapshots", "PATCH", $params, $body );

  if ( $response->{ error } ) {
    my @valid_errors =
      ( "Volume snapshot has been destroyed. It can be recovered by purevol recover and eradicated by purevol eradicate.", "No such volume or snapshot." );
    if ( grep { $_ eq $response->{ content }->{ errors }->[0]->{ message } } @valid_errors ) {
      warn "Warning :: PureStorage API :: Destroy snapshot failed :: Nothing to destoy.\n"
        . "=> Trace:\n"
        . "==> Code: "
        . $response->{ error } . "\n"
        . ( $response->{ content } ? "==> Message: " . Dumper( $response->{ content } ) : "" );
    } else {
      $Data::Dumper::Indent = 0;
      die "Error :: PureStorage API :: Destroy volume snapshot failed.\n"
        . "=> Trace:\n"
        . "==> Code: "
        . $response->{ error } . "\n"
        . ( $response->{ content } ? "==> Message: " . Dumper( $response->{ content } ) : "" );
    }
  }

  print "Info :: Volume \"$vgname/$volname\" snapshot \"$snap_name\" destroyed.\n";

  $params = "names=$vgname/$volname.snap-$snap_name";
  $body   = { replication_snapshot => \1 };

  $response = $class->purestorage_request( $scfg, "volume-snapshots", "DELETE", $params, $body );

  if ( $response->{ error } ) {
    $Data::Dumper::Indent = 0;
    die "Error :: PureStorage API :: Eradicate volume \"$vgname/$volname\" snapshot \"$snap_name\" failed.\n"
      . "=> Trace:\n"
      . "==> Code: "
      . $response->{ error } . "\n"
      . ( $response->{ content } ? "==> Message: " . Dumper( $response->{ content } ) : "" );
  }

  print "Info :: Volume \"$vgname/$volname\" snapshot \"$snap_name\" eradicated.\n";
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
  die "Error :: Cloning image is currently unimplemented.\n";
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

  my $vgname = $scfg->{ vgname } || die "Error :: Volume group name is not defined.\n";

  # Check for supported format (only 'raw' is allowed)
  die "Error :: Unsupported format ($fmt).\n" if $fmt ne 'raw';

  # Validate the name format, should start with 'vm-$vmid-disk'
  die "Error :: Illegal name \"$name\" - should be \"vm-$vmid-(disk-*|cloudinit|state-*)\".\n" if $name && $name !~ m/^vm-$vmid-(disk-|cloudinit|state-)/;

  $name = $class->find_free_diskname( $storeid, $scfg, $vmid ) if !$name;

  # Check size (must be between 1MB and 4PB)
  if ( $size < 1024 ) {
    print "Info :: Size is too small ($size kb), adjusting to 1024 kb\n";
    $size = 1024;
  }

  # Convert size from KB to bytes
  my $sizeB = $size * 1024;    # KB => B

  if ( !$class->purestorage_create_volume( $scfg, $name, $sizeB, $storeid ) ) {
    die "Error :: Failed to create volume \"$vgname/$name\".\n";
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

    my $response = $class->purestorage_request( $scfg, "arrays/space", "GET" );

    # Get storage capacity and used space from the response
    $cache->{ total } = $response->{ content }->{ items }->[0]->{ capacity };
    $cache->{ used }  = $response->{ content }->{ items }->[0]->{ space }->{ total_physical };

    # $cache->{ used } = $response->{ content }->{ items }->[0]->{ space }->{ total_used }; # Do not know what is correct

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

  my ( $size, $used ) = $class->purestorage_volume_info( $scfg, $volname );

  return wantarray ? ( $size, "raw", $used, undef ) : $size;
}

sub map_volume {
  my ( $class, $storeid, $scfg, $volname, $snapname ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::map_volume\n" if $DEBUG;
  my ( $path, undef, undef, $wwid ) = $class->filesystem_path( $scfg, $volname );

  my $vgname = $scfg->{ vgname } || die "Error :: Volume group name is not defined.\n";

  print "Info :: Mapping volume \"$vgname/$volname\" with WWN: " . uc( $wwid ) . ".\n" if $DEBUG;

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
      return 1;
    }
    sleep $interval;
  }

  warn "Warning :: Local path \"$path\" does not exist.\n";
  return 0;
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

  $class->purestorage_volume_connection( $scfg, $volname );

  $class->map_volume( $storeid, $scfg, $volname, $snapname );
  return 1;
}

sub deactivate_volume {
  my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::deactivate_volume\n" if $DEBUG;

  my $vgname = $scfg->{ vgname } || die "Error :: Volume group name is not defined.\n";

  $class->unmap_volume( $storeid, $scfg, $volname, $snapname );

  $class->purestorage_volume_connection( $scfg, $volname, 'DELETE' );

  print "Info :: Volume \"$vgname/$volname\" deactivated.\n";

  return 1;
}

sub volume_resize {
  my ( $class, $scfg, $storeid, $volname, $size, $running ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::volume_resize\n" if $DEBUG;
  warn "Debug :: New Size: $size\n"                                              if $DEBUG;

  my $vgname = $scfg->{ vgname } || die "Error :: Volume group name is not defined.\n";

  my $new_size = $class->purestorage_resize_volume( $scfg, $volname, $size ) or die "Error :: Failed to resize volume \"$vgname/$volname\".\n";

  return $new_size;
}

sub rename_volume {
  my ( $class, $scfg, $storeid, $source_volname, $target_vmid, $target_volname ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::rename_volume\n" if $DEBUG;

  die "Error :: not implemented in storage plugin \"$class\".\n" if $class->can( 'api' ) && $class->api() < 10;

  if ( $target_volname ) {

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

  my $vgname = $scfg->{ vgname } || die "Error :: Volume group name is not defined.\n";

  if ( !$class->purestorage_snap_volume_create( $scfg, $snap, $volname ) ) {
    die "Error :: Failed to snapshot volume \"$vgname/$volname\".\n";
  }
  return 1;
}

sub volume_snapshot_rollback {
  my ( $class, $scfg, $storeid, $volname, $snap ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::volume_snapshot_rollback\n" if $DEBUG;

  my $vgname = $scfg->{ vgname } || die "Error :: Volume group name is not defined.\n";

  if ( !$class->purestorage_snap_volume_rollback( $scfg, $snap, $volname ) ) {
    die "Error :: Failed to rollback snapshot volume \"$vgname/$volname\".\n";
  }
  return 1;
}

sub volume_snapshot_delete {
  my ( $class, $scfg, $storeid, $volname, $snap ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::volume_snapshot_delete\n" if $DEBUG;

  my $vgname = $scfg->{ vgname } || die "Error :: Volume group name is not defined.\n";

  if ( !$class->purestorage_snap_volume_delete( $scfg, $snap, $volname ) ) {
    die "Error :: Failed to snapshot volume \"$vgname/$volname\".\n";
  }
  return 1;
}

sub volume_has_feature {
  my ( $class, $scfg, $feature, $storeid, $volname, $snapname, $running ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::volume_has_feature\n" if $DEBUG;

  my $features = {
    copy     => { base    => 1, current => 1, snap => 1 },    # full clone is possible
    clone    => { snap    => 1 },                             # linked clone is possible
    snapshot => { current => 1 },                             # taking a snapshot is possible
                                                              # template => { current => 1 }, # conversion to base image is possible
                                                              # sparseinit => { base => 1, current => 1 }, # volume is sparsely initialized (thin provisioning)
    rename   => { current => 1 },                             # renaming volumes is possible
  };
  my ( $vtype, $name, $vmid, $basename, $basevmid, $isBase ) = $class->parse_volname( $volname );
  my $key = undef;
  if ( $snapname ) {
    $key = "snap";
  } else {
    $key = $isBase ? "base" : "current";
  }
  return 1 if $features->{ $feature }->{ $key };
  return undef;
}
1;
