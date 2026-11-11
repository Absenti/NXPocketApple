import Foundation

/// The words of a game's settings list. A game's `dm/launcher.json` is written in English by the engine's build
/// (`dm/games/settings.tsv`); the rows most games share get French here, keyed by their variable, and any other row shows
/// the game's own English. An option is keyed by its value, so a relabelled option keeps its translation.
extension ShellStrings {
    public static func settingLabel(_ env: String, english: String, language: String) -> String {
        isFrench(language) ? frenchLabels[env] ?? english : english
    }

    /// Nil when the game gives no note.
    public static func settingNote(_ env: String, english: String, language: String) -> String? {
        guard !english.isEmpty else { return nil }
        return isFrench(language) ? frenchNotes[env] ?? english : english
    }

    public static func settingOption(_ env: String, value: String, english: String, language: String) -> String {
        isFrench(language) ? frenchOptions["\(env)=\(value)"] ?? english : english
    }

    public static func settingSection(_ english: String, language: String) -> String {
        isFrench(language) ? frenchSections[english] ?? english : english
    }

    static func isFrench(_ language: String) -> Bool { language.hasPrefix("fr") }

    static let frenchSections: [String: String] = [
        "Game": "Jeu",
        "Controls": "Commandes",
        "Performance": "Performances",
        "Graphics": "Graphismes",
        "Audio": "Son",
        "Display": "Affichage"
    ]

    static let frenchLabels: [String: String] = [
        "DM_OPMODE": "Mode de la console",
        "DM_PRESENT_UPSCALE": "Mise à l'échelle",
        "DM_LANG": "Langue du jeu",
        "DM_PICTURE_FIT": "Image",
        "DM_SHOW_FPS": "Compteur d'images par seconde",
        "DM_TOUCH_HAPTICS": "Vibration au toucher",
        "DM_RUMBLE": "Vibrations du jeu",
        "DM_RUMBLE_GAIN": "Force des vibrations",
        "DM_RUMBLE_MIN": "Seuil des vibrations",
        "DM_PAD_PRESS_TO_JOIN": "Appuyer sur un bouton pour rejoindre",
        "DM_PRESENT_SNAP": "Mise en mémoire tampon des images",
        "DM_PSO_MTL4": "Pipelines Metal 4",
        "DM_PSO_PREBUILD": "Préparation des pipelines",
        "DM_NVN_ENC_THREAD": "Thread d'encodage",
        "DM_METAL_HUD": "HUD de performances",
        "DM_RENDER_SCALE": "Échelle de rendu"
    ]

    static let frenchNotes: [String: String] = [
        "DM_PRESENT_UPSCALE": "Demande plus de temps GPU et peut faire chauffer le téléphone.",
        "DM_PICTURE_FIT": "Remplir recadre l'image 16:9 du jeu pour couvrir l'écran. Les barres de vie, les sous-titres ou les cartes près des bords peuvent être coupés. Une image plein écran sans recadrage demande un correctif propre à chaque jeu.",
        "DM_PRESENT_SNAP": "Jusqu'à une image de latence d'affichage en plus.",
        "DM_PSO_MTL4": "Garde une archive de pipelines ; utilise plus de mémoire.",
        "DM_PSO_PREBUILD": "Le premier lancement l'attend quelques minutes, une seule fois."
    ]

    static let frenchOptions: [String: String] = [
        "DM_OPMODE=1": "TV (station d'accueil)",
        "DM_OPMODE=0": "Portable",
        "DM_PRESENT_UPSCALE=off": "Standard",
        "DM_PRESENT_UPSCALE=metalfx": "MetalFX",
        "DM_PICTURE_FIT=fit": "Ajuster",
        "DM_PICTURE_FIT=fill": "Remplir",
        "DM_LANG=en-US": "Anglais (États-Unis)",
        "DM_LANG=en-GB": "Anglais (Royaume-Uni)",
        "DM_LANG=ja": "Japonais",
        "DM_LANG=fr": "Français",
        "DM_LANG=fr-CA": "Français (Canada)",
        "DM_LANG=de": "Allemand",
        "DM_LANG=es": "Espagnol",
        "DM_LANG=es-419": "Espagnol (Amérique latine)",
        "DM_LANG=it": "Italien",
        "DM_LANG=nl": "Néerlandais",
        "DM_LANG=pt": "Portugais",
        "DM_LANG=pt-BR": "Portugais (Brésil)",
        "DM_LANG=ru": "Russe",
        "DM_LANG=ko": "Coréen",
        "DM_LANG=zh-Hans": "Chinois simplifié",
        "DM_LANG=zh-Hant": "Chinois traditionnel",
        "DM_LANG=zh-CN": "Chinois simplifié",
        "DM_LANG=zh-TW": "Chinois traditionnel"
    ]
}
