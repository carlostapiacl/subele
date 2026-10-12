import CAtomics

/// Las últimas muestras de la salida, en mono, para que la interfaz dibuje el
/// espectro.
///
/// Un buffer circular que escribe solo el hilo de audio y lee solo la interfaz.
/// Cada muestra se guarda con una escritura atómica relajada —en arm64 y x86-64
/// es una escritura común, así que no cuesta nada— y el índice se publica con
/// release. Si la interfaz lee mientras el audio da la vuelta puede ver una
/// muestra de un bloque más nuevo: para dibujar un espectro da igual, y a cambio
/// no hay ni un lock.
///
/// Apagado no escribe nada: el espectro solo hace falta con el ecualizador
/// abierto.
public final class SpectrumTap: @unchecked Sendable {

    public static let capacity = 8192
    private static let mask = capacity - 1

    private let samples: UnsafeMutablePointer<Float>
    private let writeIndex = AtomicUInt32(0)
    private let enabled = AtomicUInt32(0)

    public init() {
        samples = .allocate(capacity: SpectrumTap.capacity)
        samples.initialize(repeating: 0, count: SpectrumTap.capacity)
    }

    deinit { samples.deallocate() }

    public var isEnabled: Bool {
        get { enabled.value != 0 }
        set { enabled.value = newValue ? 1 : 0 }
    }

    /// Del hilo de audio.
    @inline(__always)
    func write(_ buffer: UnsafePointer<Float>, frames: Int, channels: Int) {
        guard enabled.value != 0, channels > 0 else { return }
        var index = Int(writeIndex.value)
        let scale = 1 / Float(channels)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels { sum += buffer[frame * channels + channel] }
            ca_store_float(samples + (index & SpectrumTap.mask), sum * scale)
            index &+= 1
        }
        writeIndex.value = UInt32(truncatingIfNeeded: index)
    }

    /// De la interfaz: copia las últimas `count` muestras, de la más vieja a la
    /// más nueva.
    public func copyLatest(_ count: Int, into destination: UnsafeMutablePointer<Float>) {
        let count = min(count, SpectrumTap.capacity)
        let end = Int(writeIndex.value)
        for offset in 0..<count {
            let index = (end &- count &+ offset) & SpectrumTap.mask
            destination[offset] = ca_load_float(samples + index)
        }
    }
}
