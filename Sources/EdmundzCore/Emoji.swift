import Foundation

/// GitHub-style emoji shortcodes. Every value is a single code point pair or less, so a shortcode of >= 4 UTF-16 units
/// can be displayed as the emoji (2 units) with the remainder hidden, preserving offsets.
public enum Emoji {
    public static let table: [String: String] = [
        "smile": "😄", "smiley": "😃", "grinning": "😀", "laughing": "😆", "joy": "😂", "wink": "😉", "blush": "😊",
        "heart_eyes": "😍", "sunglasses": "😎", "thinking": "🤔", "neutral_face": "😐", "confused": "😕", "cry": "😢",
        "sob": "😭", "angry": "😠", "scream": "😱", "sleeping": "😴", "innocent": "😇", "slightly_smiling_face": "🙂",
        "upside_down_face": "🙃", "wave": "👋", "+1": "👍", "thumbsup": "👍", "-1": "👎", "thumbsdown": "👎",
        "clap": "👏", "pray": "🙏", "muscle": "💪", "eyes": "👀", "ok_hand": "👌", "point_right": "👉", "point_left": "👈",
        "heart": "❤️", "broken_heart": "💔", "sparkles": "✨", "star": "⭐", "fire": "🔥", "zap": "⚡", "boom": "💥",
        "tada": "🎉", "rocket": "🚀", "bulb": "💡", "bug": "🐛", "memo": "📝", "books": "📚", "book": "📖",
        "warning": "⚠️", "x": "❌", "white_check_mark": "✅", "heavy_check_mark": "✔️", "question": "❓",
        "exclamation": "❗", "100": "💯", "lock": "🔒", "key": "🔑", "mag": "🔍", "hammer": "🔨", "wrench": "🔧",
        "gear": "⚙️", "package": "📦", "link": "🔗", "pushpin": "📌", "bell": "🔔", "calendar": "📆", "clock": "🕐",
        "hourglass": "⌛", "email": "📧", "phone": "☎️", "computer": "💻", "tv": "📺", "camera": "📷", "art": "🎨",
        "musical_note": "🎵", "trophy": "🏆", "medal": "🏅", "gift": "🎁", "balloon": "🎈", "cake": "🍰", "coffee": "☕",
        "pizza": "🍕", "beer": "🍺", "apple": "🍎", "sun": "☀️", "cloud": "☁️", "rainbow": "🌈", "snowflake": "❄️",
        "umbrella": "☔", "earth_americas": "🌎", "seedling": "🌱", "tree": "🌳", "cat": "🐱", "dog": "🐶",
        "unicorn": "🦄", "bee": "🐝", "turtle": "🐢", "penguin": "🐧", "construction": "🚧", "recycle": "♻️",
        "checkered_flag": "🏁", "hourglass_flowing_sand": "⏳", "arrow_right": "➡️", "arrow_left": "⬅️",
        "arrow_up": "⬆️", "arrow_down": "⬇️", "dart": "🎯", "shield": "🛡️", "moneybag": "💰", "chart_with_upwards_trend": "📈",
    ]

    /// Shortcodes in `text` as (range, emoji). Only those whose emoji occupies <= the shortcode length.
    public static func find(in text: NSString) -> [(NSRange, String)] {
        var out: [(NSRange, String)] = []
        let n = text.length
        var i = 0
        while i < n {
            if text.character(at: i) == 0x3A { // :
                var j = i + 1
                while j < n, j - i < 40 {
                    let c = text.character(at: j)
                    let ok = (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x2B || c == 0x2D
                    if !ok { break }
                    j += 1
                }
                if j < n, j > i + 1, text.character(at: j) == 0x3A {
                    let name = text.substring(with: NSRange(location: i + 1, length: j - i - 1))
                    if let e = table[name], (e as NSString).length <= j + 1 - i {
                        out.append((NSRange(location: i, length: j + 1 - i), e)); i = j + 1; continue
                    }
                }
            }
            i += 1
        }
        return out
    }
}
