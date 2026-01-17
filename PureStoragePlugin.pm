package PVE::Storage::Custom::PureStoragePlugin;

use strict;
use warnings;

use Data::Dumper qw( Dumper );    # DEBUG

use IO::File   ();
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

# Error code constants for API requests
use constant {
  ERROR_TOKEN_UPDATED => -1,    # Token was refreshed (success, but need to update cache)
  ERROR_SUCCESS       =>  0,    # Request succeeded
  ERROR_API_ERROR     =>  1,    # PureStorage API returned an error
  ERROR_NETWORK_ERROR =>  2,    # Network or connectivity error
  ERROR_AUTH_FAILED   =>  3,    # Authentication failed
};

# Token state constants for authentication state machine
use constant {
  TOKEN_STATE_LOGIN  => 0,      # Performing login request (using api-token)
  TOKEN_STATE_NEEDED => 1,      # Need to obtain session token
  TOKEN_STATE_CACHED => 2,      # Have valid cached session token
};

my $PSFA_API               = '2.26';
my $purestorage_wwn_prefix = '3624a9370';
my $default_hgsuffix       = "";
my $default_protocol       = 'iscsi';

# Global debug level (can be overridden per-storage or via environment)
my $DEBUG = $ENV{ PURESTORAGE_DEBUG } // 0;

# Get effective debug level for a storage config
sub get_debug_level {
  my ( $scfg ) = @_;
  return $scfg->{ debug } if defined $scfg && defined $scfg->{ debug };
  return $DEBUG;
}

# Set debug level from storage config (updates global $DEBUG)
sub set_debug_from_config {
  my ( $scfg ) = @_;
  if ( defined $scfg && defined $scfg->{ debug } ) {
    $DEBUG = $scfg->{ debug };
  }
}

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
# PVE 8.4: APIVER 11 e2dc01ac9f06fe37cf434bad9157a50ecc4a99ce / new_backup_provider/sensitive_properties; backup provider might be interesting, we can look at it later
# PVE 9:   APIVER 12 280bb6be777abdccd89b1b1d7bdd4feaba9af4c2 / qemu_blockdev_options/rename_snapshot/get_formats

  my $tested_apiver = 12;

  my $apiver = PVE::Storage::APIVER;
  my $apiage = PVE::Storage::APIAGE;

  # the plugin supports multiple PVE generations, currently we did not break anything, tell them what they want to hear if possible
  if ( $apiver >= 2 and $apiver <= $tested_apiver ) {
    return $apiver;
  }

  # if we are still in the APIAGE, we can still report what we have
  if ( $apiver - $apiage < $tested_apiver ) {
    return $tested_apiver;
  }

  # lowest apiver we support
  return 10;
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
    token_ttl => {
      description => "Session token time-to-live in seconds.",
      type        => 'integer',
      default     => 3600                                        # Max 10h
    },
    debug => {
      description => "Enable debug logging (0=off, 1=basic, 2=verbose, 3=trace).",
      type        => 'integer',
      minimum     => 0,
      maximum     => 3,
      default     => 0
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
    token_ttl => { optional => 1 },
    debug     => { optional => 1 },
    nodes     => { optional => 1 },
    disable   => { optional => 1 },
    content   => { optional => 1 },
    format    => { optional => 1 },
  };
}

### BLOCK: Supporting functions

my $cmd = {

  #  fuser      => '/usr/bin/fuser',
  multipath  => '/sbin/multipath',
  multipathd => '/sbin/multipathd',
  blockdev   => '/usr/sbin/blockdev',
  dmsetup    => '/sbin/dmsetup',
  kpartx     => '/sbin/kpartx',
  udevadm    => '/usr/bin/udevadm',
  sync       => '/usr/bin/sync'
};

# Get full path for a command, checking availability
sub get_command_path {
  my ( $name ) = @_;

  # Check all commands on first use
  ensure_commands_checked();

  my $path = $cmd->{ $name };
  if ( !defined $path ) {
    die "Error :: Unknown command '$name'\n";
  }

  if ( !-x $path ) {
    die "Error :: Command '$name' not found or not executable at '$path'\n";
  }

  return $path;
}

# Check if required commands are available on the system
sub check_commands {
  my @missing;

  foreach my $name ( keys %$cmd ) {
    my $path = $cmd->{ $name };
    if ( !-x $path ) {
      push @missing, "$name ($path)";
    }
  }

  if ( @missing ) {
    warn "Warning :: The following commands are not available or not executable:\n";
    warn "  - $_\n" foreach @missing;
    warn "Plugin functionality may be limited.\n";
  }

  return scalar @missing == 0;
}

# Check commands availability - called lazily on first use
my $commands_checked = 0;

sub ensure_commands_checked {
  return if $commands_checked;
  check_commands();
  $commands_checked = 1;
}

sub exec_command {
  my ( $command, $dm, %param ) = @_;

  $dm //= 1;

  # Try to resolve command path if it's a known command name
  my $cmd_name = $command->[0];
  if ( exists $cmd->{ $cmd_name } ) {
    eval { $command->[0] = get_command_path( $cmd_name ); };
    if ( $@ ) {

      # Command not available, but continue with original name
      # This allows system PATH resolution as fallback
      warn "Warning :: $@" if $dm >= 0;
    }
  }

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

  # TODO: Find a better check
  # TODO: Support non-multipath mode
  my $multipath_cmd = get_command_path( 'multipath' );
  my $output        = `$multipath_cmd -l $wwid 2>/dev/null`;

  return $output ne '';
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
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::prepare_api_params\n" if $DEBUG >= 2;

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

sub cleanup_lvm_on_device {
  my ( $wwid ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::cleanup_lvm_on_device\n" if $DEBUG;

  my $cleaned = 0;

  my @dm_devices;
  eval {
    run_command(
      [ get_command_path( 'dmsetup' ), 'ls' ],
      outfunc => sub {
        my $line = shift;
        if ( $line =~ /^(\S+)\s+\(/ ) {
          push @dm_devices, $1;
        }
      }
    );
  };
  return 0 if $@;

  my @lvm_to_remove;
  foreach my $dm ( @dm_devices ) {
    next if $dm =~ /^${wwid}(-part\d+)?$/;

    my $deps = '';
    eval {
      run_command(
        [ get_command_path( 'dmsetup' ), 'deps', '-o', 'devname', $dm ],
        outfunc => sub { $deps .= shift; },
        errfunc => sub { }
      );
    };

    if ( $deps =~ /${wwid}/ ) {
      push @lvm_to_remove, $dm;
    }
  }

  foreach my $lvm ( reverse sort @lvm_to_remove ) {
    print "Debug :: Removing LVM device: $lvm\n" if $DEBUG;
    my $removed = 0;

    eval {
      run_command( [ get_command_path( 'dmsetup' ), 'remove', $lvm ], errfunc => sub { } );
      $removed = 1;
    };

    if ( !$removed ) {
      eval {
        run_command( [ get_command_path( 'dmsetup' ), 'remove', '--force', $lvm ], errfunc => sub { } );
        $removed = 1;
      };
    }

    $cleaned++ if $removed;
    warn "Warning :: Failed to remove LVM device $lvm\n" unless $removed;
  }

  return $cleaned;
}

sub cleanup_partitions_on_device {
  my ( $wwid ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::cleanup_partitions_on_device\n" if $DEBUG;

  my $cleaned = 0;
  my $dm_path = '/dev/mapper/' . $wwid;

  eval {
    run_command( [ get_command_path( 'kpartx' ), '-d', $dm_path ], errfunc => sub { } );
    $cleaned++;
  };

  opendir( my $dh, '/dev/mapper' ) or return $cleaned;
  my @partitions = grep { /^${wwid}-part\d+$/ } readdir( $dh );
  closedir( $dh );

  foreach my $part ( reverse sort @partitions ) {
    print "Debug :: Removing partition: $part\n" if $DEBUG;
    eval {
      run_command( [ get_command_path( 'dmsetup' ), 'remove', '--force', $part ], errfunc => sub { } );
      $cleaned++;
    };
    warn "Warning :: Failed to remove partition $part\n" if $@;
  }

  return $cleaned;
}

### BLOCK: Token cache management => PVE::Storage::Custom::PureStoragePlugin::sub::token_cache
#
# Race condition mitigation strategy:
# 1. Jitter in is_token_valid() spreads refresh timing across nodes (±2.5%)
# 2. Read-check-write pattern in save_token_to_cache() prevents overwriting newer tokens
# 3. On 401 error, re-check file cache before requesting new token (another node may have refreshed)
# 4. HTTP retry on 401 with max_retries=1 prevents infinite loops
# 5. pmxcfs replication is eventually consistent (typically <1s)
#
# Scenario: Two nodes refresh simultaneously
# - Node A and Node B both see expired token at ~80% TTL (with jitter spread)
# - Node A gets token T1, Node B gets token T2
# - Node B tries to write T2, but sees T1 is already cached (created <5s ago), skips write
# - Both nodes use T1 from cache → success
#
# Edge case: If somehow both write (race in pmxcfs replication)
# - Node A has T1 in memory, but file has T2
# - Node A gets 401 on next request
# - Node A re-reads cache, finds valid T2, uses it
# - Success without extra API call
#
# Error scenarios:
# 1. Node B login fails (network/API error) during simultaneous refresh
#    - Node A successfully cached token T1
#    - Node B checks cache after login error, finds T1
#    - Node B uses T1 → continues operating
#    - No service disruption
#
# 2. Worst case: Cache file deleted/corrupted during race
#    - Node gets 401, cache re-read fails
#    - Node requests new token (1 extra API call)
#    - Result: At most 1 extra API call, system remains operational

sub get_token_cache_path {
  my ( $storeid, $array_index ) = @_;

  my $cache_dir = '/etc/pve/priv/purestorage';

  # Create cache directory if it doesn't exist
  if ( !-d $cache_dir ) {
    eval {
      File::Path::make_path( $cache_dir, { mode => 0700 } );
      print "Debug :: Created token cache directory: $cache_dir\n" if $DEBUG;
    };
    if ( $@ ) {
      warn "Warning :: Failed to create token cache directory $cache_dir: $@\n";
      return undef;
    }
  }

  return "$cache_dir/${storeid}_array${array_index}.json";
}

sub read_token_cache {
  my ( $cache_path ) = @_;

  return undef unless defined $cache_path;

  if ( !-f $cache_path ) {
    print "Debug :: Token cache file does not exist: $cache_path\n" if $DEBUG >= 2;
    return undef;
  }

  my $token_data;
  eval {
    my $json_text = PVE::Tools::file_get_contents( $cache_path );
    $token_data = decode_json( $json_text );
    print "Debug :: Read token cache from: $cache_path\n" if $DEBUG >= 1;
  };
  if ( $@ ) {
    warn "Warning :: Failed to read token cache from $cache_path: $@\n";

    # Delete corrupt cache file
    eval { unlink $cache_path };
    return undef;
  }

  return $token_data;
}

sub write_token_cache {
  my ( $cache_path, $token_data ) = @_;

  return unless defined $cache_path;

  my $json_text = encode_json( $token_data );

  # Atomic write: write to temp file, then rename
  my $temp_path = "$cache_path.tmp.$$";

  eval {
    my $fh = IO::File->new( $temp_path, 'w', 0600 )
      or die "Cannot create temp file $temp_path: $!\n";
    print $fh $json_text . "\n";
    $fh->close();

    rename( $temp_path, $cache_path )
      or die "Cannot rename $temp_path to $cache_path: $!\n";

    print "Debug :: Wrote token cache to: $cache_path\n" if $DEBUG >= 1;
  };
  if ( $@ ) {
    warn "Warning :: Failed to write token cache to $cache_path: $@\n";

    # Clean up temp file if it exists
    eval { unlink $temp_path if -f $temp_path };
    die $@;
  }
}

sub is_token_valid {
  my ( $token_data, $ttl ) = @_;

  return 0 unless defined $token_data;
  return 0 unless defined $token_data->{ auth_token };
  return 0 unless defined $token_data->{ created_at };
  return 0 unless defined $token_data->{ ttl };

  my $now = time();
  my $age = $now - $token_data->{ created_at };

  # Add jitter (±5%) to refresh threshold to prevent thundering herd
  # when multiple nodes check token expiration simultaneously
  my $jitter            = 0.05 * ( rand() - 0.5 );    # -2.5% to +2.5%
  my $refresh_threshold = $ttl * ( 0.8 + $jitter );

  print "Debug :: Token validation: now=$now, created_at=$token_data->{ created_at }, age=${age}s, threshold=${refresh_threshold}s\n" if $DEBUG >= 2;

  if ( $age < $refresh_threshold ) {
    print "Debug :: Token is valid (age: ${age}s)\n" if $DEBUG >= 1;
    return 1;
  }

  print "Debug :: Token needs refresh (age: ${age}s >= threshold: ${refresh_threshold}s)\n" if $DEBUG >= 1;
  return 0;
}

sub cleanup_expired_cache {
  my ( $cache_path, $ttl ) = @_;

  return unless defined $cache_path;
  return unless -f $cache_path;

  my $token_data = read_token_cache( $cache_path );
  return unless defined $token_data;

  if ( defined $token_data->{ expires_at } ) {
    my $now = time();
    if ( $now >= $token_data->{ expires_at } ) {
      print "Debug :: Cleaning up expired token cache: $cache_path\n" if $DEBUG;
      eval { unlink $cache_path };
      if ( $@ ) {
        warn "Warning :: Failed to delete expired cache $cache_path: $@\n";
      }
    }
  }
}

### BLOCK: API Helper functions => PVE::Storage::Custom::PureStoragePlugin::sub::api_helpers

sub load_auth_token {
  my ( $storeid, $array_index, $scfg ) = @_;

  my $cache_path = defined( $storeid ) ? get_token_cache_path( $storeid, $array_index ) : undef;
  my $ttl        = $scfg->{ token_ttl } || 3600;

  # Try in-memory cache first (fastest, no I/O)
  my $mem_token_key      = '_auth_token' . $array_index;
  my $mem_request_id_key = '_request_id' . $array_index;
  if ( defined( $scfg->{ $mem_token_key } ) && $scfg->{ $mem_token_key } ne '' ) {
    print "Debug :: Using cached token from memory\n" if $DEBUG >= 2;
    return ( $scfg->{ $mem_token_key }, $scfg->{ $mem_request_id_key }, $cache_path, $ttl );
  }

  # Try file cache
  if ( $cache_path ) {
    my $cached_token = read_token_cache( $cache_path );
    if ( $cached_token && is_token_valid( $cached_token, $ttl ) ) {
      my $age = time() - $cached_token->{ created_at };
      print "Debug :: Using cached token from file (age: ${age}s)\n" if $DEBUG >= 1;

      # Update in-memory cache for faster access next time
      $scfg->{ $mem_token_key }      = $cached_token->{ auth_token };
      $scfg->{ $mem_request_id_key } = $cached_token->{ request_id };
      return ( $cached_token->{ auth_token }, $cached_token->{ request_id }, $cache_path, $ttl );
    }
  }

  # File cache is expired or missing, return undef to force new token request
  return ( undef, undef, $cache_path, $ttl );
}

sub save_token_to_cache {
  my ( $config, $token_state ) = @_;

  # Only save if this was a login request
  return unless $token_state == TOKEN_STATE_LOGIN;

  # Only save if we have cache path and token
  return unless $config->{ cache_path } && $config->{ auth_token };

  my $now = time();
  my $ttl = $config->{ ttl } || 3600;

  my $token_data = {
    auth_token => $config->{ auth_token },
    request_id => $config->{ request_id },
    created_at => $now,
    ttl        => $ttl,
    expires_at => $now + $ttl
  };

  eval {
    # Race condition mitigation: check if another node already wrote a newer token
    my $existing = read_token_cache( $config->{ cache_path } );
    if ( $existing && $existing->{ created_at } > $token_data->{ created_at } - 5 ) {

      # Another node wrote a token within last 5 seconds, use that instead
      print "Debug :: Another node already cached a token, skipping write\n" if $DEBUG >= 2;
      return;
    }

    write_token_cache( $config->{ cache_path }, $token_data );
    print "Debug :: Token cached to file: $config->{ cache_path }\n" if $DEBUG >= 1;
  };

  if ( $@ ) {
    warn "Warning :: Failed to write token cache: $@\n";
  }
}

sub cleanup_token_cache {
  my ( $config ) = @_;

  return unless $config->{ cache_path };

  eval { cleanup_expired_cache( $config->{ cache_path }, $config->{ ttl } || 3600 ); };
}

sub is_ignorable_error {
  my ( $action, $content ) = @_;

  my $ignore = $action->{ ignore };
  return 0 unless defined $ignore;

  # Normalize to array
  $ignore = [$ignore] unless ref( $ignore ) eq 'ARRAY';

  # Check if error message is in ignore list
  my $error_msg = $content->{ errors }->[0]->{ message } // '';
  return grep { $_ eq $error_msg } @$ignore;
}

sub try_cached_token {
  my ( $config ) = @_;

  return 0 unless $config->{ cache_path };

  my $cached_token = read_token_cache( $config->{ cache_path } );
  return 0 unless $cached_token && $cached_token->{ auth_token };
  return 0 unless is_token_valid( $cached_token, $config->{ ttl } || 3600 );

  my $age = time() - $cached_token->{ created_at };
  print "Debug :: Using cached token from file (age: ${age}s)\n" if $DEBUG >= 1;

  $config->{ auth_token } = $cached_token->{ auth_token };
  $config->{ request_id } = $cached_token->{ request_id };

  return 1;
}

### BLOCK: Local multipath => PVE::Storage::Custom::PureStoragePlugin::sub::s

sub purestorage_api_call {
  my ( $scfg, $action, $all, $storeid ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_api_call\n" if $DEBUG >= 3;

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

  my $array_count        = 0;
  my $success_count      = 0;
  my $last_success_error = ERROR_SUCCESS;
  my $last_success_content;

  foreach my $i ( 0, 1 ) {
    $url = $urls[$i] // '';
    my $token = $tokens[$i] // '';
    next if $i && $url eq '' && $token eq '';

    $array_count++;

    my $cf = $url eq '' ? 'address' : $token eq '' ? 'token' : '';
    die "Error :: Pure Storage \"$cf\" parameter" . ( $i == 0 ? '' : ' for second array' ) . " is not defined.\n" unless $cf eq '';

    # Load auth token (file cache → memory cache → undef)
    my ( $auth_token, $request_id, $cache_path, $ttl ) = load_auth_token( $storeid, $i, $scfg );

    my $config = {
      ua         => $ua,
      url        => $url,
      token      => $token,
      auth_token => $auth_token,
      request_id => $request_id,
      cache_path => $cache_path,
      ttl        => $ttl
    };

    ( $error, $content ) = purestorage_http_request( $config, $path, $method, $login, $body );

    # Handle token update
    if ( $error == ERROR_TOKEN_UPDATED ) {
      $scfg->{ '_auth_token' . $i } = $config->{ auth_token };
      $scfg->{ '_request_id' . $i } = $config->{ request_id };
    }

    # Handle ignorable API errors
    elsif ( $error == ERROR_API_ERROR && is_ignorable_error( $action, $content ) ) {
      $error = ERROR_SUCCESS;
    }

    # Track success for this array
    if ( $error <= ERROR_SUCCESS ) {
      $success_count++;
      $last_success_error   = $error;
      $last_success_content = $content;
      print "Debug :: Array " . ( $i + 1 ) . " ($url) succeeded\n" if $DEBUG >= 2;
    }

    # Stop on critical authentication error (cannot continue)
    if ( $error == ERROR_AUTH_FAILED ) {
      last;
    }

    # Handle API errors in Active Cluster mode
    if ( $error == ERROR_API_ERROR ) {
      if ( $all && $success_count > 0 ) {

        # Continue to next array - partial success acceptable in Active Cluster
        print "Warning :: Array " . ( $i + 1 ) . " ($url) failed but array(s) succeeded. Continuing...\n";
        next;
      } else {
        last;
      }
    }

    # Stop on success if not processing all arrays
    last if $error <= ERROR_SUCCESS && !$all;
  }

  # Use last successful response if we processed multiple arrays
  if ( $all && $success_count > 0 ) {
    $error   = $last_success_error;
    $content = $last_success_content;
    print "Debug :: Processed $array_count array(s), $success_count succeeded\n" if $DEBUG >= 2;
  }

  # Handle fatal errors
  # For operations on all arrays (Active Cluster), fail only if all arrays failed
  if ( $error > ERROR_SUCCESS ) {
    if ( $all && $success_count > 0 ) {

      # At least one array succeeded, so operation is partially successful
      # This is acceptable for Active Cluster scenarios
      print "Warning :: Operation completed on $success_count of $array_count array(s). Some arrays may have failed.\n";
      return $last_success_content;
    }
    my $message = $error == ERROR_AUTH_FAILED ? 'Authentication' : $action->{ name } || "Action '$type' (method '$method')";
    $message = substr( $message, 0, 1 ) eq uc( substr( $message, 0, 1 ) ) ? $message . ' failed' : 'Failed to ' . $message;
    $message = 'PureStorage API :: ' . $message if $error == ERROR_API_ERROR;
    die "Error :: $message.\n" . "=> Trace:\n" . "==> address: " . $url . "\n" . ( $content ? "==> Message: " . Dumper( $content ) : '' );
  }

  return $content;
}

sub purestorage_http_request {
  my ( $config, $path, $method, $login, $body ) = @_;

  my $headers = HTTP::Headers->new( 'Content-Type' => 'application/json' );

  # Determine token state
  my $token_state;
  if ( $login ) {
    $token_state = TOKEN_STATE_LOGIN;
    $headers->header( 'api-token' => $config->{ token } );
  } elsif ( $config->{ auth_token } ) {
    $token_state = TOKEN_STATE_CACHED;
  } else {
    $token_state = TOKEN_STATE_NEEDED;
  }

  my $error;
  my $response;
  my $content;
  my $retry_count = 0;
  my $max_retries = 1;    # Allow one retry for token refresh

  # Retry loop for token expiration (max 1 retry)
  while ( $retry_count <= $max_retries ) {

    # Obtain token if needed
    if ( $token_state > TOKEN_STATE_LOGIN ) {
      if ( $token_state == TOKEN_STATE_NEEDED ) {

        # Check cache first (race condition mitigation)
        unless ( try_cached_token( $config ) ) {

          # Request new token
          print "Debug :: Requesting new session token\n" if $DEBUG >= 1;
          ( $error, $content ) = purestorage_http_request( $config, 'login', 'POST', 1 );

          # On failure, try cache again (another node may have succeeded)
          if ( $error > ERROR_SUCCESS ) {
            print "Debug :: Login failed, checking if another node cached a token\n" if $DEBUG >= 2;
            unless ( try_cached_token( $config ) ) {
              return ( $error, $content );
            }
          }
        }
        $token_state = TOKEN_STATE_CACHED;
      } else {
        print "Debug :: Using existing session token\n" if $DEBUG >= 2;
      }
      $headers->header( 'x-auth-token' => $config->{ auth_token } );
    }
    $headers->header( 'X-Request-ID' => $config->{ request_id } ) if $config->{ request_id };

    # Execute HTTP request
    my $request = HTTP::Request->new( $method, $config->{ url } . '/api/' . $PSFA_API . '/' . $path, $headers, length( $body ) ? encode_json( $body ) : undef );
    $response = $config->{ ua }->request( $request );

    # Handle 401 Unauthorized (token expired)
    $error = $response->is_success ? ERROR_SUCCESS : ERROR_API_ERROR;
    if ( $error && $token_state == TOKEN_STATE_CACHED && $response->code == 401 ) {
      $retry_count++;
      if ( $retry_count <= $max_retries ) {
        print "Debug :: Session token expired (401), retry $retry_count/$max_retries\n" if $DEBUG >= 1;

        # Save current token to detect if cache has newer version
        my $old_token = $config->{ auth_token };

        # Try cache first - another node may have already refreshed
        if ( try_cached_token( $config ) && $config->{ auth_token } ne $old_token ) {
          print "Debug :: Using refreshed token from another node\n" if $DEBUG >= 2;
          $token_state = TOKEN_STATE_CACHED;
          next;
        }

        # No fresh token in cache, request new one
        cleanup_token_cache( $config );
        $token_state = TOKEN_STATE_NEEDED;
        next;
      } else {
        print "Debug :: Max retries ($max_retries) reached, giving up\n" if $DEBUG >= 1;
        last;
      }
    }
    last;
  }

  # Process successful response
  $headers = $response->headers;
  if ( $error == ERROR_SUCCESS ) {
    if ( $token_state == TOKEN_STATE_LOGIN ) {

      # Extract tokens from login response
      $config->{ auth_token } = $headers->header( 'x-auth-token' )
        or die "Error :: PureStorage API :: Header 'x-auth-token' is missing.\n";
      $config->{ request_id } = $headers->header( 'x-request-id' );

      # Save token to cache
      save_token_to_cache( $config, $token_state );
    }

    # Signal that token was updated
    $error = ERROR_TOKEN_UPDATED if $token_state < TOKEN_STATE_CACHED;
  }

  # Parse response content
  $content = $response->decoded_content;
  my $content_type = $headers->header( 'Content-Type' ) // '';
  if ( $content_type =~ /application\/json/ ) {
    $content = decode_json( $content );
  } else {

    # Non-JSON response indicates connectivity/network error
    $error   = $login ? ERROR_AUTH_FAILED : ERROR_NETWORK_ERROR if $error == ERROR_API_ERROR;
    $content = { response => $content };
  }

  return ( $error, $content );
}

sub purestorage_list_volumes {
  my ( $class, $scfg, $vmid, $storeid, $destroyed ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_list_volumes\n" if $DEBUG >= 2;

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

  my $response = purestorage_api_call( $scfg, $action, 0, $storeid );

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
  my ( $class, $storeid, $scfg, $volname, $mode ) = @_;

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

  # For Active Cluster: connect/disconnect on all arrays (both primary and secondary)
  # This ensures volumes are accessible from both arrays in Active Cluster configuration
  my $response = purestorage_api_call( $scfg, $action, 1, $storeid );

  my $message = ( $response->{ errors } ? 'already ' : '' ) . ( $mode ? 'connected to' : 'disconnected from' );
  print "Info :: Volume \"$volname\" is $message host \"$hname\" on all arrays.\n";
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

  my $response = purestorage_api_call( $scfg, $action, 0, $storeid );

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

  # Clean up local device mappings before removing from Pure Storage
  my $volume = $class->purestorage_get_volume_info( $scfg, $volname, $storeid, 0 );
  if ( $volume && $volume->{ serial } ) {
    my ( $path, $wwid ) = get_device_path_wwn( $volume->{ serial } );

    if ( $wwid ne '' && -e "/dev/mapper/$wwid" ) {
      print "Debug :: Cleaning up local device mappings for $wwid\n" if $DEBUG;

      # 1. Remove LVM mappings on top of the device
      cleanup_lvm_on_device( $wwid );

      # 2. Remove partition mappings
      cleanup_partitions_on_device( $wwid );

      # 3. Remove multipath device
      if ( multipath_check( $wwid ) ) {
        print "Debug :: Removing multipath device $wwid\n" if $DEBUG;
        exec_command( [ 'multipath', '-f', $wwid ], 0 );
      }
    }
  }

  # Disconnect volume from all hosts on all arrays before destroying
  # For Active Cluster: get connections from first array (they are synced) and disconnect from all hosts
  print "Debug :: Disconnecting volume from all hosts on all arrays\n" if $DEBUG >= 2;
  my $pure_volname = purestorage_name( $scfg, $volname );

  # Get list of all connections (from first array - in Active Cluster connections are synced)
  my $connections_action = {
    name   => 'list volume connections',
    type   => 'connections',
    method => 'GET',
    params => { volume_names => $pure_volname }
  };

  my $connections_response = purestorage_api_call( $scfg, $connections_action, 0, $storeid );
  my @connections          = @{ $connections_response->{ items } || [] };

  if ( @connections ) {
    print "Debug :: Found " . scalar( @connections ) . " connection(s) for volume \"$volname\"\n" if $DEBUG >= 1;

    # Collect unique hostnames
    my %unique_hosts;
    foreach my $conn ( @connections ) {
      my $hostname = $conn->{ host }->{ name };
      $unique_hosts{ $hostname } = 1;
    }

    # Disconnect from each unique host on all arrays
    foreach my $hostname ( keys %unique_hosts ) {
      print "Debug :: Disconnecting from host \"$hostname\" on all arrays\n" if $DEBUG >= 2;

      my $disconnect_action = {
        name   => 'delete volume connection',
        type   => 'connections',
        method => 'DELETE',
        ignore => [ 'Volume has been destroyed.', 'Connection does not exist.' ],
        params => {
          host_names   => $hostname,
          volume_names => $pure_volname
        }
      };

      # For Active Cluster: disconnect from this host on all arrays
      purestorage_api_call( $scfg, $disconnect_action, 1, $storeid );
    }
    print "Info :: Volume \"$volname\" disconnected from " . scalar( keys %unique_hosts ) . " host(s) on all arrays.\n";
  } else {
    print "Debug :: No connections found for volume \"$volname\"\n" if $DEBUG >= 2;
  }
  my $params = { names => $pure_volname };
  my $action = {
    name   => 'destroy volume',
    type   => 'volumes',
    method => 'PATCH',
    ignore => 'Volume has been deleted.',
    params => $params,
    body   => { destroyed => \1 }
  };

  # For Active Cluster: destroy volume on all arrays
  my $response = purestorage_api_call( $scfg, $action, 1, $storeid );

  my $message = ( $response->{ errors } ? 'already ' : '' ) . 'destroyed';
  print "Info :: Volume \"$volname\" is $message.\n";

  if ( $eradicate ) {
    $action = {
      name   => 'eradicate volume',
      type   => 'volumes',
      method => 'DELETE',
      ignore => 'Eradication is disabled.',
      params => $params,
    };

    # For Active Cluster: eradicate volume on all arrays
    purestorage_api_call( $scfg, $action, 1, $storeid );

    print "Info :: Volume \"$volname\" is eradicated.\n";
  }

  return 1;
}

sub purestorage_resize_volume {
  my ( $class, $scfg, $storeid, $volname, $size ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_resize_volume\n" if $DEBUG;

  my $action = {
    name   => 'resize volume',
    type   => 'volumes',
    method => 'PATCH',
    params => { names       => purestorage_name( $scfg, $volname ) },
    body   => { provisioned => $size }
  };

  my $response = purestorage_api_call( $scfg, $action, 0, $storeid );

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
  my ( $class, $scfg, $storeid, $source_volname, $target_volname ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::purestorage_rename_volume\n" if $DEBUG;

  my $action = {
    name   => 'rename volume',
    type   => 'volumes',
    method => 'PATCH',
    params => { names => purestorage_name( $scfg, $source_volname ) },
    body   => { name  => purestorage_name( $scfg, $target_volname ) }
  };

  purestorage_api_call( $scfg, $action, 0, $storeid );

  print "Info :: Volume \"$source_volname\" is renamed to \"$target_volname\".\n";

  return 1;
}

sub purestorage_snap_volume_create {
  my ( $class, $scfg, $storeid, $snap_name, $volname ) = @_;
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

  purestorage_api_call( $scfg, $action, 0, $storeid );

  print "Info :: Volume \"$volname\" snapshot \"$snap_name\" is created.\n";
  return 1;
}

sub purestorage_volume_restore {
  my ( $class, $scfg, $storeid, $volname, $svolname, $snap, $overwrite ) = @_;
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

  purestorage_api_call( $scfg, $action, 0, $storeid );

  my $source = length( $snap ) ? 'snapshot "' . $snap . '"' : '';
  if ( $volname ne $svolname ) {
    $source .= ' of ' if $source ne '';
    $source .= 'volume "' . $svolname . '"';
  }
  $source = ' from ' . $source if $source ne '';

  print "Info :: Volume \"$volname\" is restored$source.\n";
}

sub purestorage_snap_volume_delete {
  my ( $class, $scfg, $storeid, $snap_name, $volname ) = @_;
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
  my $response = purestorage_api_call( $scfg, $action, 0, $storeid );

  my $message = ( $response->{ errors } ? 'already ' : '' ) . 'destroyed';
  print "Info :: Volume \"$volname\" snapshot \"$snap_name\" is $message.\n";

  #FIXME: Pure FA API states that replication_snapshot is query (not body) parameter
  $action = {
    name   => 'eradicate volume snapshot',
    type   => 'volume-snapshots',
    method => 'DELETE',
    ignore => [ 'No such volume or snapshot.', 'Eradication is disabled.' ],
    params => $params,
    body   => { replication_snapshot => \1 }
  };
  $response = purestorage_api_call( $scfg, $action, 0, $storeid );

  $message = ( $response->{ errors } ? 'already ' : '' ) . 'eradicated';
  print "Info :: Volume \"$volname\" snapshot \"$snap_name\" is $message.\n";
  return 1;
}

### BLOCK: Storage implementation

sub parse_volname {
  my ( $class, $volname ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::parse_volname\n" if $DEBUG >= 3;

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

  die "Error :: filesystem_path: snapshot is not implemented ($snapname)\n" if defined( $snapname );

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

  $class->purestorage_volume_restore( $scfg, $storeid, $name, $volname, $snap );

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
  set_debug_from_config( $scfg );
  print "Debug :: list_images ($storeid, vmid=" . ( $vmid // 'all' ) . ")\n" if $DEBUG >= 1;

  return $class->purestorage_list_volumes( $scfg, $vmid, $storeid, 0 );
}

sub status {
  my ( $class, $storeid, $scfg, $cache ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::status\n" if $DEBUG;

  my $total;
  my $used;

  # If using pod with quota, get pod-specific capacity
  if ( defined $scfg->{ podname } && $scfg->{ podname } ne '' ) {
    my $podname = $scfg->{ podname };
    print "Debug :: Getting pod quota for pod: $podname\n" if $DEBUG >= 2;

    my $action = {
      name   => 'get pod space',
      type   => 'pods/space',
      method => 'GET',
      params => { names => $podname }
    };
    my $response = purestorage_api_call( $scfg, $action, 0, $storeid );

    my $pod = $response->{ items }->[0];
    if ( $pod ) {

      # Use quota_limit if set and non-zero, otherwise fall back to array capacity
      # quota_limit = 0 or undef means unlimited (no quota)
      my $quota = $pod->{ quota_limit };
      $total = ( defined( $quota ) && $quota > 0 ) ? $quota : $pod->{ capacity };
      $used  = $pod->{ space }->{ total_physical };

      my $quota_str = defined( $quota ) ? ( $quota > 0 ? $quota : 'unlimited' ) : 'not set';
      print "Debug :: Pod quota_limit: $quota_str\n" if $DEBUG >= 2;
    } else {
      die "Error :: Pod \"$podname\" not found\n";
    }
  } else {

    # Get array-wide capacity
    my $response = purestorage_api_call( $scfg, { name => 'get array space', type => 'arrays/space', method => 'GET' }, 0, $storeid );

    my $array = $response->{ items }->[0];
    $total = $array->{ capacity };

    # total_physical - physically used space on the array (after deduplication and compression)
    # total_used - logically used space (before deduplication and compression)
    $used = $array->{ space }->{ total_physical };
  }

  # Calculate free space
  my $free = $total - $used;

  # Mark storage as active
  my $active = 1;

  # Return total, free, used space and the active status
  return ( $total, $free, $used, $active );
}

sub activate_storage {
  my ( $class, $storeid, $scfg, $cache ) = @_;
  set_debug_from_config( $scfg );
  print "Debug :: activate_storage ($storeid)\n" if $DEBUG >= 1;

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
  wait_for( $path_exists, "volume \"$volname\" to map", 30 );

  # we might end up with operational disk but without multipathing, e.g.
  # if unmapping was interrupted ('remove map' was already done, but slaves were not removed)
  if ( !multipath_check( $wwid ) ) {
    print "Debug :: Adding multipath map for device \"$wwid\"\n" if $DEBUG;
    exec_command( [ 'multipathd', 'add', 'map', $wwid ] );

    # Wait for multipath to be fully established
    my $multipath_ready = sub {
      return multipath_check( $wwid );
    };
    wait_for( $multipath_ready, "multipath map for volume \"$volname\" to be ready", 30 );
  }
  return $path;
}

sub unmap_volume {
  my ( $class, $storeid, $scfg, $volname, $snapname ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::unmap_volume\n" if $DEBUG;

  my ( $path, $wwid ) = $class->purestorage_get_wwn( $scfg, $volname );
  return 0 unless $path ne '' && -b $path;

  my ( $device_path, @slaves ) = block_device_slaves( $path );

  # Ensure all data is flushed to disk for write-back cache environments
  print "Debug :: Flushing filesystem and device buffers for $device_path\n" if $DEBUG >= 2;
  exec_command( ['sync'] );
  exec_command( [ 'blockdev', '--flushbufs', $device_path ] );

  # Wait for udev events to settle, ensuring all async operations complete
  eval { exec_command( [ 'udevadm', 'settle', '--timeout=10' ] ) };

  # Final sync to guarantee write-back cache is flushed
  exec_command( ['sync'] );

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

  $class->purestorage_volume_connection( $storeid, $scfg, $volname, 1 );

  $class->map_volume( $storeid, $scfg, $volname, $snapname );
  return 1;
}

sub deactivate_volume {
  my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::deactivate_volume\n" if $DEBUG;

  $class->unmap_volume( $storeid, $scfg, $volname, $snapname );

  $class->purestorage_volume_connection( $storeid, $scfg, $volname, 0 );

  print "Info :: Volume \"$volname\" is deactivated.\n";

  return 1;
}

sub volume_resize {
  my ( $class, $scfg, $storeid, $volname, $size, $running ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::volume_resize\n" if $DEBUG;
  warn "Debug :: New Size: $size\n"                                              if $DEBUG;

  return $class->purestorage_resize_volume( $scfg, $storeid, $volname, $size );
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

  $class->purestorage_rename_volume( $scfg, $storeid, $source_volname, $target_volname );

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

  $class->purestorage_snap_volume_create( $scfg, $storeid, $snap, $volname );

  return 1;
}

sub volume_snapshot_rollback {
  my ( $class, $scfg, $storeid, $volname, $snap ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::volume_snapshot_rollback\n" if $DEBUG;

  $class->purestorage_volume_restore( $scfg, $storeid, $volname, $volname, $snap, 1 );

  return 1;
}

sub volume_snapshot_delete {
  my ( $class, $scfg, $storeid, $volname, $snap ) = @_;
  print "Debug :: PVE::Storage::Custom::PureStoragePlugin::sub::volume_snapshot_delete\n" if $DEBUG;

  $class->purestorage_snap_volume_delete( $scfg, $storeid, $snap, $volname );

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
