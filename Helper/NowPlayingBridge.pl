# Loads NowPlayingBridge.dylib into the system perl and hands control to it.
use strict;
use DynaLoader;
$| = 1;
my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die "Could not load the bridge: " . DynaLoader::dl_error();
my $sym = DynaLoader::dl_find_symbol($lib, "bridge_xs") or die "Missing bridge_xs";
DynaLoader::dl_install_xsub("main::bridge", $sym);
bridge();
