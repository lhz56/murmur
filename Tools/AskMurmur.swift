import Foundation
// Testing only, for a Murmur started with --debug-requests:
//   ask-murmur open youtube and search for lofi     runs it as if said with Space + ↓
//   ask-murmur --survey "T3 Code"                    lists what it could click by name in that app
var words = Array(CommandLine.arguments.dropFirst())
var name = "app.murmur.debug.request"
if words.first == "--survey" { name = "app.murmur.debug.survey"; words.removeFirst() }
DistributedNotificationCenter.default().postNotificationName(.init(name), object: words.joined(separator: " "), userInfo: nil, deliverImmediately: true)
