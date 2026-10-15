import Foundation
// mkalias TARGET ALIASPATH: a Finder alias file (bookmark) at ALIASPATH pointing to TARGET.
let a = CommandLine.arguments
let target = URL(fileURLWithPath: a[1]), alias = URL(fileURLWithPath: a[2])
let data = try target.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
try URL.writeBookmarkData(data, to: alias)
