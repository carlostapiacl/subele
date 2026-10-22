import BoosterKit
import Foundation

/// Lo que se recuerda entre sesiones, en UserDefaults. Un solo lugar para las
/// claves y para las reglas de qué valor guardado se acepta.
enum AppSettings {

    private enum Key {
        static let gain = "gain"
        static let mode = "mode"
        static let bufferFrames = "bufferFrames"
        static let equalizer = "equalizerGains"
    }

    private static var defaults: UserDefaults { .standard }

    /// Tamaños de buffer que ofrece el menú.
    ///
    /// La cadena cuesta unos dos períodos de buffer más los 3 ms de lookahead del
    /// limitador, y esa proporción se mantuvo en todos los tamaños medidos, así
    /// que esta es la única palanca que mueve la latencia de verdad. 256 es el
    /// default: parte al medio la latencia que CoreAudio elegiría solo y todavía
    /// deja margen de sobra. 0 significa "dejar lo que eligió CoreAudio".
    static let bufferChoices: [UInt32] = [128, 256, 512, 0]
    static let defaultBufferFrames: UInt32 = 256

    /// Ganancia lineal, o nil si no hay una guardada válida.
    static var gain: Float? {
        get {
            guard let gain = defaults.object(forKey: Key.gain) as? Float,
                  gain >= 0.5, gain <= 4 else { return nil }
            return gain
        }
        set { defaults.set(newValue, forKey: Key.gain) }
    }

    static var mode: BoostMode? {
        get { defaults.string(forKey: Key.mode).flatMap(BoostMode.init(rawValue:)) }
        set { defaults.set(newValue?.rawValue, forKey: Key.mode) }
    }

    /// "Ausente" y "automático" son respuestas distintas, así que el valor guardado
    /// se lee como opcional en vez de apoyarse en que integer(forKey:) devuelva 0.
    static var bufferFrames: UInt32 {
        get {
            guard let stored = defaults.object(forKey: Key.bufferFrames) as? Int
            else { return defaultBufferFrames }
            return UInt32(max(0, stored))
        }
        set { defaults.set(Int(newValue), forKey: Key.bufferFrames) }
    }

    /// Lo que se le pide al motor: nil es "lo que elija CoreAudio".
    static var preferredBufferFrames: UInt32? { bufferFrames > 0 ? bufferFrames : nil }

    static var equalizerGains: [Float]? {
        get { defaults.array(forKey: Key.equalizer) as? [Float] }
        set { defaults.set(newValue, forKey: Key.equalizer) }
    }

    /// Lleva lo guardado al procesador, antes de arrancar.
    static func restore(into processor: BoostProcessor) {
        if let gain { processor.gain = gain }
        if let mode { processor.mode = mode }
        if let gains = equalizerGains { processor.equalizer.setGains(gains) }
    }

    static func saveEqualizer(from equalizer: Equalizer) {
        equalizerGains = (0..<Equalizer.bandCount).map { equalizer.gain(ofBand: $0) }
    }
}
