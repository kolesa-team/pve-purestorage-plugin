#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use POSIX qw( WNOHANG );
use Test::More;
use PluginLoader;

my $plugin = PluginLoader::load();
my $reap   = $plugin->can( 'purestorage_reap_sync_children' ) // BAIL_OUT( "$plugin has no purestorage_reap_sync_children" );
my $track  = $plugin->can( 'purestorage_track_sync_child' )   // BAIL_OUT( "$plugin has no purestorage_track_sync_child" );

# status() forks the protection-group sync and does not wait for it, so in pvestatd (it lives for days) every finished
# run stays a zombie. The parent reaps the finished runs it started, and only those: pvestatd has children of its own
# that its daemon code waits for.
my $done = fork() // die "fork: $!\n";
if ( !$done ) { exit 0 }
my $running = fork() // die "fork: $!\n";
if ( !$running ) { sleep 30; exit 0 }
my $foreign = fork() // die "fork: $!\n";
if ( !$foreign ) { exit 0 }

$track->( $done );
$track->( $running );
select( undef, undef, undef, 0.5 );

$reap->();
is( waitpid( $done,    WNOHANG ), -1,       'a finished run is reaped: no such child is left' );
is( waitpid( $running, WNOHANG ),  0,       'a run that still works is left alone' );
is( waitpid( $foreign, WNOHANG ), $foreign, 'a child that is not a run of the sync is not reaped by it' );

kill 'TERM', $running;
select( undef, undef, undef, 0.3 );
$reap->();
is( waitpid( $running, WNOHANG ), -1, 'the run is reaped after it ended' );

done_testing;
