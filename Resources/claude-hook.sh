#!/bin/sh
# Claude Code hook. Sends the event to Brim over a local socket. For permission requests it waits
# and prints Brim's answer; if Brim doesn't answer, Claude Code shows its own prompt.
# Does nothing when Brim isn't running.
SOCK="${BRIM_SOCKET:-$HOME/Library/Application Support/Brim/claude.sock}"
if [ ! -S "$SOCK" ]; then cat > /dev/null; exit 0; fi
# The connection stays open until Brim replies. If Claude Code kills the hook, Brim sees the
# socket close and dismisses the alert.
exec /usr/bin/perl -MIO::Socket::UNIX -e '
  my $s = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Peer => $ARGV[0]) or exit 0;
  local $/; my $in = <STDIN>; $in =~ tr/\n//d;
  print $s "$in\n";
  print <$s>;
' "$SOCK"
