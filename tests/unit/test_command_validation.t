#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 9;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

# Mock the command paths for testing
my $test_dir = tempdir( CLEANUP => 1 );
my $cmd = {
  multipath  => "$test_dir/multipath",
  multipathd => "$test_dir/multipathd",
  blockdev   => "$test_dir/blockdev",
  dmsetup    => "$test_dir/dmsetup",
  kpartx     => "$test_dir/kpartx"
};

# Track if commands were checked
my $commands_checked = 0;

sub ensure_commands_checked {
  return if $commands_checked;
  check_commands();
  $commands_checked = 1;
}

sub get_command_path {
  my ( $name ) = @_;

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

sub check_commands {
  my @missing;

  foreach my $name ( keys %$cmd ) {
    my $path = $cmd->{ $name };
    if ( !-x $path ) {
      push @missing, "$name ($path)";
    }
  }

  if ( @missing ) {
    note "Warning :: The following commands are not available:";
    note "  - $_" foreach @missing;
  }

  return scalar @missing == 0;
}

# Test 1: Unknown command should die
eval { get_command_path('unknown_command') };
like( $@, qr/Unknown command/, 'Unknown command throws error' );

# Test 2: Non-existent command should die
eval { get_command_path('multipath') };
like( $@, qr/not found or not executable/, 'Non-existent command throws error' );

# Test 3: Create executable commands
foreach my $name ( keys %$cmd ) {
  my $path = $cmd->{ $name };
  open my $fh, '>', $path or die "Cannot create $path: $!";
  print $fh "#!/bin/sh\necho 'test'\n";
  close $fh;
  chmod 0755, $path;
}

# Reset check flag to re-run validation
$commands_checked = 0;

# Test 4: Valid command should return path
my $path = get_command_path('multipath');
is( $path, $cmd->{multipath}, 'Valid command returns correct path' );

# Test 5: Commands should be checked only once
my $check_count = 0;
{
  no warnings 'redefine';
  my $original = \&check_commands;
  *check_commands = sub {
    $check_count++;
    $original->();
  };

  $commands_checked = 0;
  get_command_path('multipath');
  get_command_path('dmsetup');
  get_command_path('kpartx');
}
is( $check_count, 1, 'check_commands called only once' );

# Test 6: All commands should be validated
my $result = check_commands();
ok( $result, 'All commands are valid' );

# Test 7: Make one command non-executable
chmod 0644, $cmd->{kpartx};
$result = check_commands();
ok( !$result, 'Non-executable command detected' );

# Test 8: Check that non-executable command fails
eval { get_command_path('kpartx') };
like( $@, qr/not executable/, 'Non-executable command throws error' );

# Test 9: Restore executable and verify it works
chmod 0755, $cmd->{kpartx};
$commands_checked = 0;
$path = get_command_path('kpartx');
is( $path, $cmd->{kpartx}, 'Restored command works' );

# Test 10: Verify all expected commands exist in hash
my @expected = qw(multipath multipathd blockdev dmsetup kpartx);
my @actual = sort keys %$cmd;
is_deeply( \@actual, [sort @expected], 'All expected commands present in hash' );

done_testing();
