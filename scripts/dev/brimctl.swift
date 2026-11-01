// Sends a debug command to a running Brim (needs `defaults write com.andrespaladino.brim debugTools -bool YES`).
// Build: swiftc scripts/dev/brimctl.swift -o scripts/dev/brimctl
// Commands: snapshot <name> | state | hover | leave | click | stats [reset] | focus | answer allow|deny | choose <labels>
//   | rec on|other|off | autoanswer on|off | capture on|off | hud volume|brightness <0-1> | device | charge <kind>
//   | boop | music on|off | media toggle|next|prev
import Foundation
DistributedNotificationCenter.default().postNotificationName(.init("com.andrespaladino.brim.debug"), object: CommandLine.arguments.dropFirst().joined(separator: " "), userInfo: nil, deliverImmediately: true)
