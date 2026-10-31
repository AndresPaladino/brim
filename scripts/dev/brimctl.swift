// Sends a debug command to a running Brim (needs `defaults write com.andrespaladino.brim debugTools -bool YES`).
// Build: swiftc scripts/dev/brimctl.swift -o scripts/dev/brimctl
// Commands: snapshot <name> | hover | leave | stats | focus | rec on|other|off | autoanswer on|off
import Foundation
DistributedNotificationCenter.default().postNotificationName(.init("com.andrespaladino.brim.debug"), object: CommandLine.arguments.dropFirst().joined(separator: " "), userInfo: nil, deliverImmediately: true)
