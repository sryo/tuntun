/// A small curated word→emoji map per language so the candidate strip can
/// suggest an emoji for the word being typed ("smart emoji"). Lookup is
/// language-scoped with no cross-language fallback, so false friends never
/// fire (German "gift" is poison, not 🎁; Portuguese "bravo" is angry, not 👏).
/// Keys are lowercase display forms, diacritics included, matching what the
/// decoder emits before casing is applied.
public enum EmojiSuggestions {
    public static func emoji(for word: String, language: KeyboardLanguage) -> String? {
        maps[language]?[word.lowercased()]
    }

    /// Every trigger word for one language (tests assert map invariants).
    static func allWords(for language: KeyboardLanguage) -> [String] {
        maps[language].map { Array($0.keys) } ?? []
    }

    private static let maps: [KeyboardLanguage: [String: String]] = [
        .english: english, .french: french, .german: german, .spanish: spanish,
        .italian: italian, .dutch: dutch, .portuguese: portuguese, .russian: russian,
    ]

    private static let english: [String: String] = [
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

    private static let french: [String: String] = [
        "amour": "❤️", "cœur": "❤️", "coeur": "❤️", "feu": "🔥", "lol": "😂", "mdr": "😂",
        "haha": "😂", "heureux": "😊", "heureuse": "😊", "sourire": "😊", "triste": "😢",
        "pleurer": "😭", "rire": "😂", "joie": "😂",
        "oui": "👍", "non": "👎", "ok": "👌", "merci": "🙏", "stp": "🙏", "svp": "🙏",
        "fête": "🎉", "anniversaire": "🎂", "gâteau": "🎂", "cadeau": "🎁",
        "café": "☕️", "bière": "🍺", "vin": "🍷", "pizza": "🍕", "faim": "🍔", "manger": "🍔",
        "chien": "🐶", "chat": "🐱", "soleil": "☀️", "pluie": "🌧️", "neige": "❄️",
        "étoile": "⭐️", "lune": "🌙", "argent": "💰", "riche": "💰", "musique": "🎵", "chanson": "🎶",
        "téléphone": "📱", "appel": "📞", "voiture": "🚗", "maison": "🏠", "travail": "💼",
        "dormir": "😴", "fatigué": "😪", "fatiguée": "😪", "cool": "😎", "wow": "😮",
        "colère": "😠", "fâché": "😡",
        "bisou": "😘", "bise": "😘", "câlin": "🤗", "courir": "🏃", "muscu": "💪", "fort": "💪",
        "livre": "📖", "idée": "💡", "penser": "🤔", "parfait": "💯",
        "yeux": "👀", "bravo": "👏", "salut": "👋", "bonjour": "👋", "coucou": "👋", "bye": "👋",
        "brisé": "💔", "fleur": "🌸", "rose": "🌹", "arbre": "🌳", "fusée": "🚀",
    ]

    private static let german: [String: String] = [
        "liebe": "❤️", "herz": "❤️", "feuer": "🔥", "lol": "😂", "haha": "😂",
        "glücklich": "😊", "lächeln": "😊", "traurig": "😢", "weinen": "😭", "lachen": "😂",
        "freude": "😂",
        "ja": "👍", "nein": "👎", "ok": "👌", "okay": "👌", "danke": "🙏", "bitte": "🙏",
        "party": "🎉", "feiern": "🎉", "geburtstag": "🎂", "kuchen": "🎂", "geschenk": "🎁",
        "kaffee": "☕️", "bier": "🍺", "wein": "🍷", "pizza": "🍕", "hunger": "🍔", "essen": "🍔",
        "hund": "🐶", "katze": "🐱", "sonne": "☀️", "regen": "🌧️", "schnee": "❄️",
        "stern": "⭐️", "mond": "🌙", "geld": "💰", "reich": "💰", "musik": "🎵", "lied": "🎶",
        "handy": "📱", "telefon": "📱", "anruf": "📞", "auto": "🚗", "haus": "🏠",
        "zuhause": "🏠", "arbeit": "💼",
        "schlafen": "😴", "müde": "😪", "cool": "😎", "wow": "😮", "wütend": "😡", "sauer": "😡",
        "kuss": "😘", "umarmung": "🤗", "laufen": "🏃", "sport": "💪", "stark": "💪",
        "buch": "📖", "idee": "💡", "denken": "🤔", "fertig": "✅", "erledigt": "✅",
        "perfekt": "💯",
        "augen": "👀", "applaus": "👏", "hallo": "👋", "hi": "👋", "tschüss": "👋",
        "gebrochen": "💔", "blume": "🌸", "rose": "🌹", "baum": "🌳", "rakete": "🚀",
    ]

    private static let spanish: [String: String] = [
        "amor": "❤️", "corazón": "❤️", "fuego": "🔥", "jaja": "😂", "jajaja": "😂", "lol": "😂",
        "feliz": "😊", "sonrisa": "😊", "triste": "😢", "llorar": "😭", "reír": "😂", "risa": "😂",
        "sí": "👍", "no": "👎", "ok": "👌", "vale": "👌", "gracias": "🙏", "porfa": "🙏",
        "fiesta": "🎉", "celebrar": "🎉", "cumpleaños": "🎂", "cumple": "🎂", "pastel": "🎂",
        "torta": "🎂", "regalo": "🎁",
        "café": "☕️", "cerveza": "🍺", "vino": "🍷", "pizza": "🍕", "hambre": "🍔", "comida": "🍔",
        "perro": "🐶", "gato": "🐱", "sol": "☀️", "lluvia": "🌧️", "nieve": "❄️",
        "estrella": "⭐️", "luna": "🌙", "dinero": "💰", "rico": "💰", "música": "🎵",
        "canción": "🎶",
        "teléfono": "📱", "celular": "📱", "móvil": "📱", "llamada": "📞", "coche": "🚗",
        "carro": "🚗", "auto": "🚗", "casa": "🏠", "trabajo": "💼",
        "dormir": "😴", "sueño": "😴", "cansado": "😪", "cansada": "😪", "genial": "😎",
        "guay": "😎", "wow": "😮", "guau": "😮", "enojado": "😡", "enfadado": "😡",
        "beso": "😘", "abrazo": "🤗", "correr": "🏃", "gimnasio": "💪", "fuerte": "💪",
        "libro": "📖", "idea": "💡", "pensar": "🤔", "listo": "✅", "hecho": "✅",
        "perfecto": "💯",
        "ojos": "👀", "aplausos": "👏", "hola": "👋", "adiós": "👋", "chau": "👋",
        "roto": "💔", "flor": "🌸", "rosa": "🌹", "árbol": "🌳", "cohete": "🚀",
    ]

    private static let italian: [String: String] = [
        "amore": "❤️", "cuore": "❤️", "fuoco": "🔥", "ahah": "😂", "haha": "😂", "lol": "😂",
        "felice": "😊", "sorriso": "😊", "triste": "😢", "piangere": "😭", "ridere": "😂",
        "gioia": "😂",
        "sì": "👍", "no": "👎", "ok": "👌", "grazie": "🙏", "prego": "🙏",
        "festa": "🎉", "festeggiare": "🎉", "compleanno": "🎂", "torta": "🎂", "regalo": "🎁",
        "caffè": "☕️", "birra": "🍺", "vino": "🍷", "pizza": "🍕", "fame": "🍔", "cibo": "🍔",
        "cane": "🐶", "gatto": "🐱", "sole": "☀️", "pioggia": "🌧️", "neve": "❄️",
        "stella": "⭐️", "luna": "🌙", "soldi": "💰", "ricco": "💰", "musica": "🎵",
        "canzone": "🎶",
        "telefono": "📱", "chiamata": "📞", "macchina": "🚗", "auto": "🚗", "casa": "🏠",
        "lavoro": "💼",
        "dormire": "😴", "stanco": "😪", "stanca": "😪", "figo": "😎", "wow": "😮",
        "arrabbiato": "😡",
        "bacio": "😘", "abbraccio": "🤗", "correre": "🏃", "palestra": "💪", "forte": "💪",
        "libro": "📖", "idea": "💡", "pensare": "🤔", "fatto": "✅", "perfetto": "💯",
        "occhi": "👀", "applausi": "👏", "ciao": "👋", "salve": "👋",
        "rotto": "💔", "fiore": "🌸", "rosa": "🌹", "albero": "🌳", "razzo": "🚀",
    ]

    private static let dutch: [String: String] = [
        "liefde": "❤️", "hart": "❤️", "vuur": "🔥", "lol": "😂", "haha": "😂",
        "blij": "😊", "lach": "😊", "verdrietig": "😢", "huilen": "😭", "lachen": "😂",
        "ja": "👍", "nee": "👎", "ok": "👌", "oké": "👌", "bedankt": "🙏", "dank": "🙏",
        "alsjeblieft": "🙏",
        "feest": "🎉", "feestje": "🎉", "verjaardag": "🎂", "taart": "🎂", "cadeau": "🎁",
        "kado": "🎁",
        "koffie": "☕️", "bier": "🍺", "wijn": "🍷", "pizza": "🍕", "honger": "🍔", "eten": "🍔",
        "hond": "🐶", "kat": "🐱", "zon": "☀️", "regen": "🌧️", "sneeuw": "❄️",
        "ster": "⭐️", "maan": "🌙", "geld": "💰", "rijk": "💰", "muziek": "🎵", "liedje": "🎶",
        "telefoon": "📱", "bellen": "📞", "auto": "🚗", "huis": "🏠", "thuis": "🏠",
        "werk": "💼",
        "slapen": "😴", "moe": "😪", "cool": "😎", "wauw": "😮", "boos": "😡",
        "kus": "😘", "knuffel": "🤗", "rennen": "🏃", "sporten": "💪", "sterk": "💪",
        "boek": "📖", "idee": "💡", "denken": "🤔", "klaar": "✅", "gedaan": "✅",
        "perfect": "💯",
        "ogen": "👀", "applaus": "👏", "hoi": "👋", "hallo": "👋", "doei": "👋",
        "gebroken": "💔", "bloem": "🌸", "roos": "🌹", "boom": "🌳", "raket": "🚀",
    ]

    private static let portuguese: [String: String] = [
        "amor": "❤️", "coração": "❤️", "fogo": "🔥", "kkk": "😂", "kkkk": "😂", "rsrs": "😂",
        "haha": "😂", "feliz": "😊", "sorriso": "😊", "triste": "😢", "chorar": "😭",
        "rir": "😂",
        "sim": "👍", "não": "👎", "ok": "👌", "obrigado": "🙏", "obrigada": "🙏", "valeu": "🙏",
        "festa": "🎉", "comemorar": "🎉", "aniversário": "🎂", "bolo": "🎂", "presente": "🎁",
        "café": "☕️", "cerveja": "🍺", "vinho": "🍷", "pizza": "🍕", "fome": "🍔", "comida": "🍔",
        "cachorro": "🐶", "gato": "🐱", "sol": "☀️", "chuva": "🌧️", "neve": "❄️",
        "estrela": "⭐️", "lua": "🌙", "dinheiro": "💰", "rico": "💰", "música": "🎵",
        "telefone": "📱", "celular": "📱", "ligação": "📞", "carro": "🚗", "casa": "🏠",
        "trabalho": "💼",
        "dormir": "😴", "sono": "😴", "cansado": "😪", "cansada": "😪", "legal": "😎",
        "uau": "😮", "raiva": "😡",
        "beijo": "😘", "beijos": "😘", "abraço": "🤗", "correr": "🏃", "academia": "💪",
        "forte": "💪", "livro": "📖", "ideia": "💡", "pensar": "🤔", "feito": "✅",
        "pronto": "✅", "perfeito": "💯",
        "olhos": "👀", "palmas": "👏", "oi": "👋", "olá": "👋", "tchau": "👋",
        "flor": "🌸", "rosa": "🌹", "árvore": "🌳", "foguete": "🚀",
    ]

    private static let russian: [String: String] = [
        "любовь": "❤️", "люблю": "❤️", "сердце": "❤️", "огонь": "🔥", "лол": "😂",
        "ахаха": "😂", "хаха": "😂", "счастлив": "😊", "счастлива": "😊", "улыбка": "😊",
        "грустно": "😢", "плакать": "😭", "смех": "😂",
        "да": "👍", "нет": "👎", "ок": "👌", "окей": "👌", "спасибо": "🙏", "пожалуйста": "🙏",
        "праздник": "🎉", "вечеринка": "🎉", "днюха": "🎂", "торт": "🎂", "подарок": "🎁",
        "кофе": "☕️", "пиво": "🍺", "вино": "🍷", "пицца": "🍕", "голоден": "🍔", "еда": "🍔",
        "собака": "🐶", "кот": "🐱", "кошка": "🐱", "солнце": "☀️", "дождь": "🌧️",
        "снег": "❄️",
        "звезда": "⭐️", "луна": "🌙", "деньги": "💰", "богат": "💰", "музыка": "🎵",
        "песня": "🎶",
        "телефон": "📱", "звонок": "📞", "машина": "🚗", "дом": "🏠", "работа": "💼",
        "спать": "😴", "устал": "😪", "устала": "😪", "круто": "😎", "вау": "😮",
        "злой": "😡", "злюсь": "😡",
        "поцелуй": "😘", "обнимаю": "🤗", "бежать": "🏃", "сильный": "💪", "книга": "📖",
        "идея": "💡", "думаю": "🤔", "готово": "✅", "сделано": "✅", "идеально": "💯",
        "глаза": "👀", "браво": "👏", "привет": "👋", "пока": "👋", "здравствуйте": "👋",
        "разбито": "💔", "цветок": "🌸", "роза": "🌹", "дерево": "🌳", "ракета": "🚀",
    ]
}
