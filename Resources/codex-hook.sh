#!/bin/sh
# Codex hook. Sends the event to Brim over the same socket as Claude Code, tagged as Codex.
# For permission requests it waits and prints Brim's answer. Codex waits for this hook before
# showing its own approval prompt, so Brim lets go as soon as you open Codex from the notch.
# Codex expects JSON on stdout, so it prints {} when there is nothing to say.
SOCK="${BRIM_SOCKET:-$HOME/Library/Application Support/Brim/claude.sock}"
if [ ! -S "$SOCK" ]; then cat > /dev/null; echo '{}'; exit 0; fi
exec /usr/bin/perl -MIO::Socket::UNIX -e '
  local $/; my $in = <STDIN>; $in =~ tr/\n//d;
  $in =~ s/^\s*\{\s*\}\s*$/{"brim_agent":"codex"}/ or $in =~ s/^\s*\{/{"brim_agent":"codex",/;
  my $s = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Peer => $ARGV[0]) or do { print "{}\n"; exit 0 };
  print $s "$in\n";
  my $out = <$s>;
  print(defined $out && $out =~ /\S/ ? $out : "{}\n");
' "$SOCK"
