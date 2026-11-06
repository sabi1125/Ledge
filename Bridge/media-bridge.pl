#!/usr/bin/perl
# Loads MediaBridge.dylib into this Apple-signed perl process and runs one of its
# entry points. Usage: perl media-bridge.pl /path/to/MediaBridge.dylib ledge_stream|ledge_send
use strict;
use warnings;
use DynaLoader;

my ($lib, $entry) = @ARGV;
die "usage: media-bridge.pl LIB ENTRY\n" unless $lib && $entry;

my $ref = DynaLoader::dl_load_file($lib, 0)
    or die "could not load $lib: " . DynaLoader::dl_error() . "\n";
my $sym = DynaLoader::dl_find_symbol($ref, $entry)
    or die "missing symbol $entry\n";
my $sub = DynaLoader::dl_install_xsub("main::ledge_entry", $sym);
&$sub();
