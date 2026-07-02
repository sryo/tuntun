/// A small curated word→emoji map so the candidate strip can suggest an emoji for
/// the word being typed ("smart emoji"). English-keyed for now.
public enum EmojiSuggestions {
    public static func emoji(for word: String) -> String? { map[word.lowercased()] }

    private static let map: [String: String] = [
        "love": "❤️", "heart": "❤️", "fire": "🔥", "lit": "🔥", "lol": "😂", "haha": "😂",
        "happy": "😊", "smile": "😊", "sad": "😢", "cry": "😭", "laugh": "😂", "joy": "😂",
        "yes": "👍", "no": "👎", "ok": "👌", "okay": "👌", "thanks": "🙏", "please": "🙏",
        "party": "🎉", "celebrate": "🎉", "birthday": "🎂", "cake": "🎂", "gift": "🎁",
        "coffee": "☕️", "beer": "🍺", "wine": "🍷", "pizza": "🍕", "food": "🍔", "hungry": "🍔",
        "dog": "🐶", "cat": "🐱", "sun": "☀️", "sunny": "☀️", "rain": "🌧️", "snow": "❄️",
        "star": "⭐️", "moon": "🌙", "money": "💰", "rich": "💰", "music": "🎵", "song": "🎶",
        "phone": "📱", "call": "📞", "car": "🚗", "home": "🏠", "house": "🏠", "work": "💼",
        "sleep": "😴", "tired": "😪", "cool": "😎", "wow": "😮", "angry": "😠", "mad": "😡",
        "kiss": "😘", "hug": "🤗", "run": "🏃", "gym": "💪", "strong": "💪", "book": "📖",
        "idea": "💡", "think": "🤔", "check": "✅", "done": "✅", "hundred": "💯", "perfect": "💯",
        "eyes": "👀", "clap": "👏", "wave": "👋", "hi": "👋", "hello": "👋", "bye": "👋",
        "broken": "💔", "flower": "🌸", "rose": "🌹", "tree": "🌳", "rocket": "🚀",
    ]
}
