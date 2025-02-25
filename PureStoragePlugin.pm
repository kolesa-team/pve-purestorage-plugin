package PVE::Storage::Custom::PureStoragePlugin;

use strict;
use warnings;

use Data::Dumper qw( Dumper );    # DEBUG

use IO::File   ();
use Net::IP    ();
use File::Path ();

use PVE::JSONSchema      ();
use PVE::Network         ();
use PVE::Tools           qw( file_read_firstline run_command );
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

my $PSFA_API               = '2.26';
my $purestorage_wwn_prefix = '3624a9370';
my $default_hgsuffix       = "";
my $default_protocol       = 'iscsi';

my $DEBUG = 0;

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
      type        => 'string',
      default     => $default_hgsuffix
    },
    address => {
      description => "PureStorage Management IP address or DNS name.",
      type        => 'string'
    },
    token => {
      description => "Storage API token.",
      type        => 'string'
    },
    podname => {
      description => "PureStorage pod name",
      type        => 'string'
    },
    vnprefix => {
      description => "Prefix to add to volume name before sending it to PureStorage array",
      type        => 'string'
    },
    check_ssl => {
      description => "Verify the server's TLS certificate",
      type        => 'boolean',
      default     => 'no'
    },
    protocol => {
      description => "Set storage protocol ( iscsi | fc | nvme )",
      type        => 'string',
      default     => $default_protocol
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
    protocol  => { optional => 1 },
    nodes     => { optional => 1 },
    disable   => { optional => 1 },
    content   => { optional => 1 },
    format    => { optional => 1 },
  };
}

### BLOCK: Supporting functions

my $cmd = {

  #  fuser      => '/usr/bin/fuser',
  multipathd => '/sbin/multipathd',
  blockdev   => '/usr/sbin/blockdev'
};

sub exec_command {
  my ( $command, $dm, %param ) = @_;

  $dm //= 1;

  my $fc = $cmd->{ $command->[0] };
  $command->[0] = $fc if defined $fc;

  print "Debug :: execute '" . join( ' ', @$command ) . "'\n" if $DEBUG >= 2;

  if ( $DEBUG < 3 ) {
    $param{ 'quiet' } = 1 unless exists $param{ 'quiet' };
  }

  eval { run_command( $command, %param ) };
  if ( $@ ) {
    my $error = " :: Cannot execute '" . join( ' ', @$command ) . "'\n  ==> Error :: $@\n";
    die 'Error' . $error if $dm > 0;

    warn 'Warning' . $error unless $dm < 0;
    return $dm < 0;
  }

  return $dm >= 0;
}

sub scsi_scan_new {
  my ( $protocol ) = @_;

  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::scsi_scan_new\n" if $DEBUG;

  my $path = '/sys/class/' . $protocol . '_host';
  opendir( my $dh, $path ) or die "Cannot open directory: $!";
  my @hosts = grep { !/^\.\.?$/ } readdir( $dh );
  closedir( $dh );

  my $count = 0;
  foreach my $host ( @hosts ) {
    next unless $host =~ /^(\w+)$/;
    $path = '/sys/class/scsi_host/' . $1;    # untaint
    if ( -d $path ) {
      device_op( $path, 'scan', '- - -' );
      ++$count;
    } else {
      warn "Warning :: SCSI host path $path does not exist.\n";
    }
  }

  die "Error :: Did not find hosts to scan.\n" unless $count > 0;

  print "Debug :: Scanned $count host" . ( $count > 1 ? 's' : '' ) . " for new devices\n" if $DEBUG;
}

sub multipath_check {
  my ( $wwid ) = @_;

  my $output = `$cmd->{ "multipathd" } show map $wwid format %w`;
  chomp($output);
  
  return $output eq $wwid;
}

sub wait_for {
  my ( $success, $message, $timeout, $delay ) = @_;

  my $debug = 'Debug :: Waiting for ' . $message;

  $timeout //= 5;
  $delay   //= 0.1;

  # Wait for the device size to update
  my $time = 0;
  while ( $time < $timeout ) {
    if ( &$success() ) {
      if ( $DEBUG && $time > 0 ) {
        print $debug if $DEBUG >= 2;
        print ": done in $time sec\n";
      }
      return 1;
    }

    if ( $DEBUG && $time == 0 ) {
      print $debug;
      print "\n" if $DEBUG >= 2;
    }

    select( undef, undef, undef, $delay );

    $time += $delay;
  }

  print $debug                        if $DEBUG >= 2;
  print ": timeout after $time sec\n" if $DEBUG;

  die "Error :: Timeout while waiting for $message\n";
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

sub get_device_path_wwn {
  my ( $serial ) = @_;

  die 'Error :: Volume serial is missing' unless length( $serial );

  # Construct the WWN path
  my $wwn  = lc( $purestorage_wwn_prefix . $serial );
  my $path = '/dev/disk/by-id/wwn-0x' . substr( $wwn, -32 );
  return ( $path, $wwn );
}

sub get_device_size {
  my ( $device ) = @_;
  print "Debug :: get_device_size($device)\n" if $DEBUG;

  my $path = '/sys/block/' . basename( $device ) . '/size';
  my $size = file_read_firstline( $path ) << 9;

  print "Debug :: Device \"$device\" size is $size bytes\n" if $DEBUG;
  return $size;
}

sub device_op {
  my ( $device_path, $op, $value ) = @_;

  open( my $fh, '>', $device_path . '/' . $op ) or die "Error :: Could not open file \"$device_path/$op\" for writing.\n";
  print $fh $value;
  close( $fh );
}

sub block_device_action {
  my ( $action, @devices ) = @_;
  print "Debug :: block_device_action($action,@devices)\n" if $DEBUG;

  foreach my $device ( @devices ) {
    if ( $device !~ /^(sd[a-z]+)$/ ) {
      warn "Warning :: Unexpected device name in block_device_action() => $action $device)\n";
      next;
    }
    $device = $1;    # untaint
    my $device_path = '/sys/block/' . $device . '/device';
    if ( $action eq 'remove' ) {
      print "Debug :: Removing device: $device\n" if $DEBUG;
      exec_command( [ 'blockdev', '--flushbufs', '/dev/' . $device ] );
      device_op( $device_path, 'state',  'offline' );
      device_op( $device_path, 'delete', '1' );
    } elsif ( $action eq 'rescan' ) {
      print "Debug :: Rescanning: $device\n" if $DEBUG;
      device_op( $device_path, 'rescan', '1' );
    } else {
      die "Error :: Unsuported acitonin block_device_action() => $action\n";
    }
  }
}

sub block_device_slaves {
  my ( $path ) = @_;

  my $device_path = abs_path( $path );
  die "Error :: Can't resolve device path for $path\n" unless $device_path =~ /^([\/a-zA-Z0-9_\-\.]+)$/;
  $device_path = $1;    # untaint

  print "Debug :: Device path resolved to \"$device_path\".\n" if $DEBUG;

  my $device_name = basename( $device_path );
  my $slaves_path = '/sys/block/' . $device_name . '/slaves';

  my @slaves;
  if ( -d $slaves_path ) {
    opendir( my $dh, $slaves_path ) or die "Cannot open directory: $!";
    @slaves = grep { !/^\.\.?$/ } readdir( $dh );
    closedir( $dh );
  }
  if ( @slaves ) {
    print "Debug :: Disk \"$device_name\" slaves: " . join( ', ', @slaves ) . "\n" if $DEBUG;
  } else {
    warn "Warning :: Disk \"$device_name\" has no slaves.\n";
    push @slaves, $device_name;
  }
  return $device_path, @slaves;
}

### BLOCK: Local multipath => PVE::Storage::Custom::PureStoragePlugin::sub::s

sub purestorage_api_request {
  my ( $scfg, $action, $all ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_api_request\n" if $DEBUG;

  $all //= 0;

  my $ua = LWP::UserAgent->new( timeout => 15 );
  $ua->ssl_opts(
    verify_hostname => 0,
    SSL_verify_mode => 0x00
  ) unless $scfg->{ check_ssl };

  my $type  = $action->{ type };
  my $login = $type eq 'login' ? 1 : 0;

  my $params = prepare_api_params( $action->{ params } );
  my $path   = $type;
  $path .= '?' . $params if length( $params );

  my $method = $action->{ method };

  my $body = $action->{ body };

  my $error;
  my $content;
  my $url;

  my @urls   = split( ',', $scfg->{ address } // '' );
  my @tokens = split( ',', $scfg->{ token }   // '' );

  foreach my $i ( 0, 1 ) {
    $url = $urls[$i] // '';
    my $token = $tokens[$i] // '';
    next if $i && $url eq '' && $token eq '';

    my $cf = $url eq '' ? 'address' : $token eq '' ? 'token' : '';
    die "Error :: Pure Storage \"$cf\" parameter" . ( $i == 0 ? '' : ' for second array' ) . " is not defined.\n" unless $cf eq '';

    my $config = {
      ua         => $ua,
      url        => $url,
      token      => $token,
      auth_token => $scfg->{ '_auth_token' . $i },
      request_id => $scfg->{ '_request_id' . $i }
    };

    ( $error, $content ) = purestorage_api_request1( $config, $path, $method, $login, $body );
    if ( $error == -1 ) {
      $scfg->{ '_auth_token' . $i } = $config->{ auth_token };
      $scfg->{ '_request_id' . $i } = $config->{ request_id };
    } elsif ( $error == 1 ) {
      my $ignore = $action->{ ignore };
      if ( defined( $ignore ) ) {
        $ignore = [$ignore] if ref( $ignore ) eq '';
        my $first = $content->{ errors }->[0]->{ message };
        $error = 0 if grep { $_ eq $first } @$ignore;
      }
    }

    last if $error == 1 || $error <= 0 && !$all;
  }

  if ( $error > 0 ) {
    my $message = $error == 3 ? 'Authentication' : $action->{ name } || "Action '$type' (method '$method')";
    $message = substr( $message, 0, 1 ) eq uc( substr( $message, 0, 1 ) ) ? $message . ' failed' : 'Failed to ' . $message;
    $message = 'PureStorage API :: ' . $message if $error == 1;
    die "Error :: $message.\n" . "=> Trace:\n" . "==> address: " . $url . "\n" . ( $content ? "==> Message: " . Dumper( $content ) : '' );
  }

  return $content;
}

sub purestorage_api_request1 {
  my ( $config, $path, $method, $login, $body ) = @_;

  my $headers = HTTP::Headers->new( 'Content-Type' => 'application/json' );

  my $token_state;
  if ( $login ) {
    $token_state = 0;    # login request
    $headers->header( 'api-token' => $config->{ token } );
  } elsif ( $config->{ auth_token } ) {
    $token_state = 2;    # have cached token
  } else {
    $token_state = 1;    # need token
  }

  my $error;
  my $response;
  my $content;
  while ( 1 ) {
    if ( $token_state > 0 ) {
      if ( $token_state == 1 ) {
        print "Debug :: Requesting new session token\n" if $DEBUG;
        ( $error, $content ) = purestorage_api_request1( $config, 'login', 'POST', 1 );
        return ( $error, $content ) if $error > 0;
      } else {
        print "Debug :: Using existing session token\n" if $DEBUG;
      }
      $headers->header( 'x-auth-token' => $config->{ auth_token } );
    }
    $headers->header( 'X-Request-ID' => $config->{ request_id } ) if $config->{ request_id };

    my $request = HTTP::Request->new( $method, $config->{ url } . '/api/' . $PSFA_API . '/' . $path, $headers, length( $body ) ? encode_json( $body ) : undef );
    $response = $config->{ ua }->request( $request );

    $error = $response->is_success ? 0 : 1;
    if ( $error && $token_state == 2 && $response->code == 401 ) {
      print "Debug :: Session token expired\n";
      $token_state = 1;
      next;
    }
    last;
  }

  $headers = $response->headers;
  if ( $error == 0 ) {
    if ( $token_state == 0 ) {
      $config->{ auth_token } = $headers->header( 'x-auth-token' ) or die "Error :: PureStorage API :: Header 'x-auth-token' is missing.\n";
      $config->{ request_id } = $headers->header( 'x-request-id' );
    }
    $error = -1 if $token_state < 2;    # auth_token was updated
  }

  $content = $response->decoded_content;
  my $content_type = $headers->header( 'Content-Type' ) // '';
  if ( $content_type =~ /application\/json/ ) {
    $content = decode_json( $content );
  } else {
    $error   = $login ? 3 : 2 if $error == 1;    # non-API error (connectivity, etc.)
    $content = { response => $content };
  }

  return ( $error, $content );
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
  return get_device_path_wwn( $volume->{ serial } ) if $volume;

  warn "Warning :: Can't get volume \"$volname\" info\n";
  return ( '', '' );
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

  my $response = purestorage_api_request( $scfg, $action, 1 );

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

  my $response = purestorage_api_request( $scfg, $action );

  my $serial = $response->{ items }->[0]->{ serial } or die "Error :: Failed to retrieve volume serial";

  my ( $path, $wwid ) = get_device_path_wwn( $serial );

  # return early if the volume is not mapped (normally should not happen)
  return $size unless $path ne '' && -b $path;

  my ( $device_path, @slaves ) = block_device_slaves( $path );

  # Iterate through slaves and rescan each device
  block_device_action( 'rescan', @slaves );

  if ( multipath_check( $wwid ) ) {
    print "Debug :: Device \"$wwid\" is a multipath device. Proceeding with resizing.\n" if $DEBUG;
    exec_command( [ 'multipathd', 'resize', 'map', $wwid ] );
  }

  print "Debug :: Expected size = $size\n" if $DEBUG;

  my $new_size;
  my $updated_size = sub {
    $new_size = get_device_size( $device_path );
    return $new_size >= $size;
  };

  # FIXME: With the current implementation we may not need to wait
  wait_for( $updated_size, "volume \"$volname\" size update" );

  print "Debug :: New size detected for volume \"$volname\": $new_size bytes.\n" if $DEBUG;

  print "Info :: Volume \"$volname\" is resized.\n";

  return $new_size;
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
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::list_images\n" if $DEBUG;

  return $class->purestorage_list_volumes( $scfg, $vmid, $storeid, 0 );
}

sub status {
  my ( $class, $storeid, $scfg, $cache ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::status\n" if $DEBUG;

  my $response = purestorage_api_request( $scfg, { name => 'get array space', type => 'arrays/space', method => 'GET' } );

  # Get storage capacity and used space from the response
  my $array = $response->{ items }->[0];
  my $total = $array->{ capacity };
  my $used  = $array->{ space }->{ total_physical };

  # my $used = $array->{ space }->{ total_used }; # Do not know what is correct

  # Calculate free space
  my $free = $total - $used;

  # Mark storage as active
  my $active = 1;

  # Return total, free, used space and the active status
  return ( $total, $free, $used, $active );
}

sub activate_storage {
  my ( $class, $storeid, $scfg, $cache ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::activate_storage\n" if $DEBUG;

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

  my $protocol = $scfg->{ protocol } // $default_protocol;
  if ( $protocol eq 'iscsi' || $protocol eq 'fc' ) {
    scsi_scan_new( $protocol );
  } elsif ( $protocol eq 'nvme' ) {
    die "Error :: Protocol: \"$protocol\" isn't implemented yet.\n";
  } else {
    die "Error :: Protocol: \"$protocol\" isn't a valid protocol.\n";
  }

  my $path_exists = sub {
    return -e $path;
  };

  # Wait for the device to appear
  wait_for( $path_exists, "volume \"$volname\" to map" );

  # we might end up with operational disk but without multipathing, e.g.
  # if unmapping was interrupted ('remove map' was already done, but slaves were not removed)
  exec_command( [ 'multipathd', 'add', 'map', $wwid ] ) unless multipath_check( $wwid );

  return $path;
}

sub unmap_volume {
  my ( $class, $storeid, $scfg, $volname, $snapname ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::unmap_volume\n" if $DEBUG;

  my ( $path, $wwid ) = $class->purestorage_get_wwn( $scfg, $volname );
  return 0 unless $path ne '' && -b $path;

  my ( $device_path, @slaves ) = block_device_slaves( $path );

  exec_command( [ 'blockdev', '--flushbufs', $device_path ] );

  # this may help if there is a write-back cache (see issue #47)
  ## my $fuser = sub {
  ##   return exec_command( [ 'fuser', '-s', $device_path ], -1 );
  ## };
  ## wait_for( $fuser, 'device cache flush', 30, 0.5 );

  if ( multipath_check( $wwid ) ) {
    print "Debug :: Device \"$wwid\" is a multipath device. Proceeding with multipath removal.\n" if $DEBUG;

    # remove the link
    exec_command( [ 'multipathd', 'remove', 'map', $wwid ] );
  } else {
    print "Debug :: Device \"$wwid\" is not a multipath device. Skipping multipath removal.\n" if $DEBUG;
  }

  # Iterate through slaves and remove each device
  block_device_action( 'remove', @slaves );

  print "Debug :: Device \"$wwid\" is removed.\n" if $DEBUG;
  return 1;
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
