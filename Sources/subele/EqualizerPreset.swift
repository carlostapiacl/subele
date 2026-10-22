import Foundation

/// Puntos de partida, no recetas: después se ajustan arrastrando. Valores por
/// banda de 60 Hz a 12 kHz.
struct EqualizerPreset {
    let name: KeyPath<Strings, String>
    let gains: [Float]

    static let all: [EqualizerPreset] = [
        EqualizerPreset(name: \.presetFlat, gains: [0, 0, 0, 0, 0]),
        EqualizerPreset(name: \.presetBass, gains: [6, 3, 0, 0, 1]),
        EqualizerPreset(name: \.presetVoice, gains: [-4, -1, 2, 4, 2]),
        EqualizerPreset(name: \.presetBright, gains: [0, -1, 0, 3, 6]),
        EqualizerPreset(name: \.presetNight, gains: [-6, -2, 2, 2, -2]),
        EqualizerPreset(name: \.presetLaptop, gains: [2, 4, 0, 1, 3]),
    ]
}
