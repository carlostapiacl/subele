import CAtomics

/// Un `Float` que un hilo escribe y otro lee sin carrera de datos.
///
/// Vive en memoria propia y no en una propiedad de la clase dueña: así la
/// dirección es estable y leerlo desde el hilo de audio no toca ARC ni locks.
public final class AtomicFloat: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>

    public init(_ value: Float) {
        storage = .allocate(capacity: 1)
        storage.initialize(to: value)
    }

    deinit { storage.deallocate() }

    public var value: Float {
        @inline(__always) get { ca_load_float(storage) }
        @inline(__always) set { ca_store_float(storage, newValue) }
    }
}

/// Un `UInt32` atómico, con orden acquire/release.
public final class AtomicUInt32: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<UInt32>

    public init(_ value: UInt32) {
        storage = .allocate(capacity: 1)
        storage.initialize(to: value)
    }

    deinit { storage.deallocate() }

    public var value: UInt32 {
        @inline(__always) get { ca_load_u32(storage) }
        @inline(__always) set { ca_store_u32(storage, newValue) }
    }

    @discardableResult @inline(__always)
    public func increment() -> UInt32 { ca_increment_u32(storage) }
}
