import Foundation

/// Generates a markdown document of roughly `bytes` size.
func makeFixture(bytes: Int) -> String {
    var out = ""
    out.reserveCapacity(bytes + 1024)
    var i = 0
    while out.utf8.count < bytes {
        if i % 12 == 0 { out += "## Section \(i / 12)\n\n" }
        out += "Paragraph \(i): lorem ipsum **bold text** and *italic text* with `inline code` and more words "
        out += "to make this line long enough to wrap across a couple of lines in a typical column width, "
        out += "plus another **strong run** and *emphasis run* near the end.\n\n"
        i += 1
    }
    return out
}
