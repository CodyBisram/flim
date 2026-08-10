import Foundation

/// Vision label → emoji, for the reaction bar's two contextual slots.
///
/// Keys are `VNClassifyImageRequest`'s own identifiers (confirmed against the live taxonomy via
/// `VNClassifyImageRequest().supportedIdentifiers()`, 1,303 entries as of revision 2, not guessed
/// from label *names*). A key that stops existing in a future revision simply never matches again;
/// nothing here parses or validates identifiers against Vision itself, on purpose, so a taxonomy
/// change degrades to "fewer suggestions", never a crash.
///
/// Deliberately incomplete. A label is only mapped when the emoji is unambiguously what a person
/// would pick for it themselves — a specific dog breed still means 🐶, but a generic label like
/// `people`, `adult`, `spice`, or `celestial_body` maps to nothing, because there is no single
/// emoji that is obviously right for it (and, for anything about a person's identity, no emoji
/// that's ever appropriate to guess). `EmojiSuggestion` is what turns "no mapping" into "no
/// suggestion" rather than a default.
///
/// Several distinct labels intentionally share one emoji (every dog breed → 🐶, every lizard-like
/// label → 🦎), and two broad labels are the deliberate hierarchy fallback the reaction feature is
/// built on: `animal`/`mammal` → 🐾 and `reptile` → 🐾, so a specific label that misses the
/// confidence floor can still resolve to a confident broader guess instead of nothing.
enum EmojiLabelMap {
    static func emoji(forLabel label: String) -> String? { table[label] }

    private static let table: [String: String] = [
        // MARK: - Animals (broad + hierarchy fallbacks)
        "animal": "🐾", "mammal": "🐾", "reptile": "🐾", "canine": "🐶", "feline": "🐱",
        "rodent": "🐭", "arachnid": "🕷️", "poultry": "🐔",

        // MARK: - Dogs
        "dog": "🐶", "australian_shepherd": "🐶", "basenji": "🐶", "basset": "🐶", "beagle": "🐶",
        "bernese_mountain": "🐶", "bichon": "🐶", "bulldog": "🐶", "chihuahua": "🐶", "collie": "🐶",
        "corgi": "🐶", "dachshund": "🐶", "dalmatian": "🐶", "doberman": "🐶", "german_shepherd": "🐶",
        "greyhound": "🐶", "hound": "🐶", "husky": "🐶", "irish_wolfhound": "🐶",
        "jack_russell_terrier": "🐶", "malamute": "🐶", "malinois": "🐶", "mastiff": "🐶",
        "newfoundland": "🐶", "pitbull": "🐶", "pomeranian": "🐶", "poodle": "🐶", "pug": "🐶",
        "retriever": "🐶", "ridgeback": "🐶", "rottweiler": "🐶", "saint_bernard": "🐶",
        "schnauzer": "🐶", "setter": "🐶", "sheepdog": "🐶", "spaniel": "🐶", "terrier": "🐶",
        "vizsla": "🐶", "weimaraner": "🐶",

        // MARK: - Cats & other pets
        "cat": "🐱", "kitten": "🐱", "adult_cat": "🐱",
        "hamster": "🐹", "rabbit": "🐰",

        // MARK: - Farm & large mammals
        "cow": "🐄", "goat": "🐐", "sheep": "🐑", "pig": "🐷", "boar": "🐗", "horse": "🐴",
        "donkey": "🫏", "llama": "🦙", "camel": "🐫", "bison": "🦬",

        // MARK: - Wild mammals
        "bear": "🐻", "panda": "🐼", "koala": "🐨", "lion": "🦁", "tiger": "🐯", "leopard": "🐆",
        "elephant": "🐘", "giraffe": "🦒", "zebra": "🦓", "kangaroo": "🦘", "hippopotamus": "🦛",
        "rhinoceros": "🦏", "deer": "🦌", "fox": "🦊", "coyote_wolf": "🐺", "squirrel": "🐿️",
        "hedgehog": "🦔", "otter": "🦦", "skunk": "🦨", "raccoon": "🦝", "rat": "🐀",

        // MARK: - Birds
        "bird": "🐦", "sparrow": "🐦", "woodpecker": "🐦", "hummingbird": "🐦", "heron": "🐦",
        "stork": "🐦", "pelican": "🐦", "gull": "🐦", "sandpiper": "🐦", "pigeon": "🐦",
        "eagle": "🦅", "raptor": "🦅", "owl": "🦉", "penguin": "🐧", "flamingo": "🦩",
        "parrot": "🦜", "parakeet": "🦜", "cockatoo": "🦜", "peacock": "🦚",
        "swan": "🦢", "dove": "🕊️",

        // MARK: - Aquatic life
        "fish": "🐟", "angelfish": "🐠", "clownfish": "🐠", "lionfish": "🐠", "sunfish": "🐠",
        "guppy": "🐠", "goldfish": "🐠", "koi": "🐠", "shark": "🦈", "whale": "🐋",
        "dolphin": "🐬", "cephalopod": "🐙", "crab": "🦀", "lobster": "🦞", "oyster": "🦪",
        "clam": "🦪", "scallop": "🦪", "mussel": "🦪", "jellyfish": "🪼", "turtle": "🐢",
        "tortoise": "🐢", "seal": "🦭", "sealion": "🦭",

        // MARK: - Reptiles, amphibians & bugs
        "lizard": "🦎", "gecko": "🦎", "iguana": "🦎", "chameleon": "🦎", "monitor_lizard": "🦎",
        "snake": "🐍", "python": "🐍", "rattlesnake": "🐍", "snake_other": "🐍",
        "alligator_crocodile": "🐊", "frog": "🐸", "toad": "🐸", "dinosaur": "🦕",
        "bee": "🐝", "ant": "🐜", "butterfly": "🦋", "ladybug": "🐞", "spider": "🕷️",
        "spiderweb": "🕸️", "scorpion": "🦂", "worm": "🪱", "caterpillar": "🐛", "snail": "🐌",

        // MARK: - Fruit
        "apple": "🍎", "banana": "🍌", "oranges": "🍊", "mandarine": "🍊",
        "pear": "🍐", "peach": "🍑", "cherry": "🍒", "grape": "🍇", "strawberry": "🍓",
        "blueberry": "🫐", "watermelon": "🍉", "melon": "🍈", "cantaloupe": "🍈",
        "honeydew": "🍈", "pineapple": "🍍", "mango": "🥭", "coconut": "🥥", "kiwi": "🥝",
        "lemon": "🍋", "lime": "🍋", "avocado": "🥑",

        // MARK: - Vegetables
        "tomato": "🍅", "eggplant": "🍆", "potato": "🥔", "carrot": "🥕", "corn": "🌽",
        "bell_pepper": "🫑", "habanero": "🌶️", "jalapeno": "🌶️", "broccoli": "🥦",
        "cucumber": "🥒", "garlic": "🧄", "onion": "🧅", "mushroom": "🍄", "peanut": "🥜",
        "chestnut": "🌰",

        // MARK: - Prepared food
        "pizza": "🍕", "hamburger": "🍔", "hotdog": "🌭", "fries": "🍟", "taco": "🌮",
        "burrito": "🌯", "sandwich": "🥪", "sushi": "🍣", "ramen": "🍜", "pasta": "🍝",
        "spaghetti": "🍝", "bread": "🍞", "croissant": "🥐", "bagel": "🥯", "pretzel": "🥨",
        "pancake": "🥞", "waffle": "🧇", "fried_egg": "🍳", "scrambled_eggs": "🍳",
        "egg": "🥚", "cheese": "🧀", "bacon": "🥓", "steak": "🥩", "popcorn": "🍿",
        "donut": "🍩", "cookie": "🍪", "cake_regular": "🍰", "birthday_cake": "🎂",
        "wedding_cake": "🎂", "pie": "🥧", "candy": "🍬", "chocolate": "🍫", "honey": "🍯",
        "soup": "🍲", "salad": "🥗", "curry": "🍛", "dumpling": "🥟", "seafood": "🍤",
        "tempura": "🍤", "rice": "🍚",

        // MARK: - Drinks
        "coffee": "☕", "tea_drink": "🍵", "beer": "🍺", "red_wine": "🍷", "white_wine": "🍷",
        "wine": "🍷", "wine_bottle": "🍷", "sparkling_wine": "🍾", "cocktail": "🍸",
        "margarita": "🍹", "mojito": "🍹", "juice": "🧃", "milkshake": "🥤", "smoothie": "🥤",
        "soda": "🥤", "bubble_tea": "🧋",

        // MARK: - Weather & sky
        "sky": "🌤️", "cloudy": "☁️", "blue_sky": "☀️", "night_sky": "🌌", "sunset_sunrise": "🌅",
        "rainbow": "🌈", "thunderstorm": "⛈️", "lightning": "⚡", "snow": "❄️",
        "blizzard": "🌨️", "haze": "🌫️", "tornado": "🌪️", "moon": "🌙", "sun": "☀️",
        "aurora": "🌌",

        // MARK: - Landscape & water
        "mountain": "⛰️", "volcano": "🌋", "beach": "🏖️", "ocean": "🌊", "water_body": "🌊",
        "lake": "🏞️", "forest": "🌲", "desert": "🏜️", "sand_dune": "🏜️", "island": "🏝️",
        "iceberg": "🧊", "ice": "🧊",

        // MARK: - Plants & flowers
        "rose": "🌹", "tulip": "🌷", "sunflower": "🌻", "daisy": "🌼", "chrysanthemum": "🏵️",
        "flower": "🌸", "blossom": "🌸", "lily": "🌸", "orchid": "🌸", "bouquet": "💐",
        "flower_arrangement": "💐", "tree": "🌳", "palm_tree": "🌴", "evergreen": "🌲",
        "cactus": "🌵", "clover": "🍀", "wheat": "🌾", "maple_tree": "🍁",

        // MARK: - City & buildings
        "skyscraper": "🏙️", "cityscape": "🏙️", "building": "🏢", "house_single": "🏠",
        "bridge": "🌉", "castle": "🏰", "museum": "🏛️", "hospital": "🏥", "tower": "🗼",
        "ferris_wheel": "🎡", "rollercoaster": "🎢", "carousel": "🎠", "stadium": "🏟️",
        "arena": "🏟️", "traffic_light": "🚦", "crane_construction": "🏗️", "tent": "⛺",
        "camping": "🏕️",

        // MARK: - Vehicles
        "car": "🚗", "automobile": "🚗", "convertible": "🚗", "suv": "🚙", "jeep": "🚙",
        "sportscar": "🏎️", "formula_one_car": "🏎️", "police_car": "🚓", "ambulance": "🚑",
        "firetruck": "🚒", "bus": "🚌", "truck": "🚚", "semi_truck": "🚛", "van": "🚐",
        "motorhome": "🚐", "tractor": "🚜", "bicycle": "🚲", "motorcycle": "🏍️",
        "motocross": "🏍️", "scooter": "🛴", "train": "🚆", "train_real": "🚆",
        "tramway": "🚊", "monorail": "🚝", "airplane": "✈️", "aircraft": "✈️",
        "helicopter": "🚁", "rocket": "🚀", "sailboat": "⛵", "speedboat": "🚤",
        "jetski": "🚤", "canoe": "🛶", "kayak": "🛶", "yacht": "🛥️", "cruise_ship": "🛳️",
        "boat": "⛵", "warship": "🚢", "sled": "🛷", "sledding": "🛷", "luggage": "🧳",
        "suitcase": "🧳",

        // MARK: - Sport & activity
        "basketball": "🏀", "football": "🏈", "soccer": "⚽", "baseball": "⚾", "tennis": "🎾",
        "golf": "⛳", "golf_ball": "⛳", "volleyball": "🏐", "rugby": "🏉", "hockey": "🏒",
        "cricket_sport": "🏏", "badminton": "🏸", "ping_pong": "🏓", "bowling": "🎳",
        "boxing": "🥊", "kickboxing": "🥊", "wrestling": "🤼", "martial_arts": "🥋",
        "fencing_sport": "🤺", "archery": "🏹", "swimming": "🏊", "diving": "🤿",
        "scuba": "🤿", "surfing": "🏄", "waterpolo": "🤽", "skiing": "⛷️",
        "snowboarding": "🏂", "ice_skating": "⛸️", "skating": "⛸️", "rollerskating": "🛼",
        "skateboarding": "🛹", "cycling": "🚴", "gymnastics": "🤸", "yoga": "🧘",
        "hiking": "🥾", "rock_climbing": "🧗", "trophy": "🏆", "medal": "🏅",

        // MARK: - Music
        "guitar": "🎸", "piano": "🎹", "drum": "🥁", "bongo_drum": "🥁", "violin": "🎻",
        "cello": "🎻", "saxophone": "🎷", "trumpet": "🎺", "accordion": "🪗",
        "microphone": "🎤", "karaoke": "🎤", "headphones": "🎧", "disco_ball": "🪩",
        "dancing": "💃", "ballet": "🩰", "ballet_dancer": "🩰",

        // MARK: - Celebrations
        "bride": "👰", "wedding_dress": "👰", "groom": "🤵", "gift": "🎁", "balloon": "🎈",
        "balloon_hotair": "🎈", "fireworks": "🎆", "firecracker": "🧨", "sparkler": "🎇",
        "christmas_tree": "🎄", "christmas_decoration": "🎄", "santa_claus": "🎅",
        "graduation": "🎓", "carnival": "🎪", "circus": "🎪",

        // MARK: - Games
        "board_game": "🎲", "dice": "🎲", "chess": "♟️", "poker": "🃏", "play_card": "🃏",
        "videogame": "🎮", "gamepad": "🎮", "puzzles": "🧩",

        // MARK: - Clothing & accessories
        "footwear": "👟", "shoes": "👟", "sneaker": "👟", "high_heel": "👠", "boot": "👢",
        "sandal": "👡", "jacket": "🧥", "gown": "👗", "scarf": "🧣", "mitten": "🧤",
        "glove": "🧤", "sock": "🧦", "baseball_hat": "🧢", "beanie": "🧢",
        "cowboy_hat": "🤠", "sunhat": "👒", "fedora": "🎩", "hat": "🎩", "headgear": "🎩",
        "tiara": "👑", "necktie": "👔", "kimono": "👘", "eyeglasses": "👓",
        "sunglasses": "🕶️", "purse": "👛", "backpack": "🎒",

        // MARK: - Home & interiors
        "bed": "🛏️", "sofa": "🛋️", "chair": "🪑", "bookshelf": "📚", "book": "📚",
        "television": "📺", "candle": "🕯️", "candlestick": "🕯️", "bath": "🛁",
        "shower": "🚿", "toilet_seat": "🚽",

        // MARK: - Tech & objects
        "laptop": "💻", "computer": "🖥️", "computer_keyboard": "⌨️", "computer_mouse": "🖱️",
        "phone": "📱", "camera": "📷", "printer": "🖨️", "watch": "⌚", "newspaper": "📰",
        "umbrella": "☂️", "jewelry": "💍",
    ]
}
