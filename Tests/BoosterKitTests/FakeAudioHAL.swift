import CoreAudio
import Foundation
@testable import BoosterKit

/// Formato float32 nativo, el único que el motor acepta.
func float32Format(channels: Int, sampleRate: Double = 48_000,
                   interleaved: Bool = true) -> AudioStreamBasicDescription {
    var flags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
    if !interleaved { flags |= kAudioFormatFlagIsNonInterleaved }
    let bytesPerFrame = UInt32(interleaved ? 4 * channels : 4)
    return AudioStreamBasicDescription(
        mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
        mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
        mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
}

/// Una AudioBufferList de prueba: un buffer por entrada de `layout`, cada uno con
/// `frames` frames intercalados llenos con `value`, o sin datos si `value` es nil.
final class TestBufferList {
    let list: UnsafeMutableAudioBufferListPointer
    let frames: Int
    private var storage: [(UnsafeMutablePointer<Float>, Int)] = []

    init(_ layout: [(channels: Int, value: Float?)], frames: Int) {
        self.frames = frames
        list = AudioBufferList.allocate(maximumBuffers: layout.count)
        for (index, buffer) in layout.enumerated() {
            let count = frames * buffer.channels
            var data: UnsafeMutableRawPointer?
            if let value = buffer.value {
                let samples = UnsafeMutablePointer<Float>.allocate(capacity: count)
                samples.initialize(repeating: value, count: count)
                storage.append((samples, count))
                data = UnsafeMutableRawPointer(samples)
            }
            list[index] = AudioBuffer(mNumberChannels: UInt32(buffer.channels),
                                      mDataByteSize: UInt32(count * 4), mData: data)
        }
    }

    deinit {
        for (samples, count) in storage {
            samples.deinitialize(count: count)
            samples.deallocate()
        }
        free(list.unsafeMutablePointer)
    }

    /// Las muestras de un buffer, o vacío si no tiene datos.
    func samples(ofBuffer index: Int) -> [Float] {
        let buffer = list[index]
        guard let data = buffer.mData else { return [] }
        let count = Int(buffer.mDataByteSize) / 4
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self),
                                         count: count))
    }

    /// El último frame de un buffer, ya asentados el lookahead y las rampas.
    func lastFrame(ofBuffer index: Int) -> [Float] {
        let channels = Int(list[index].mNumberChannels)
        return Array(samples(ofBuffer: index).suffix(channels))
    }
}

/// Una HAL que no toca el hardware. Se configura con lo que tiene que "ver" el
/// motor y cuenta qué creó y qué destruyó, para que los tests pregunten si quedó
/// algo vivo.
final class FakeAudioHAL: AudioHAL {

    // Lo que ve el motor.
    var outputFormat = float32Format(channels: 2)
    var outputLayout = [2]
    var physicalInputLayout: [Int] = []
    var tapFormat = float32Format(channels: 2)
    /// La entrada del agregado: por defecto, entradas físicas y después el tap.
    var aggregateInputLayout: [Int]?
    /// Cuántas lecturas de la entrada del agregado devuelven vacío antes de que
    /// el stream del tap aparezca.
    var pollsUntilReady = 0

    // Fallas a pedido.
    var failCreateAggregate = false
    var failStartIO = false
    var stopIOStatus: OSStatus = noErr
    var destroyIOProcStatus: OSStatus = noErr

    // Lo que quedó registrado.
    private(set) var tapsCreated = 0
    private(set) var liveTaps = Set<AudioObjectID>()
    private(set) var liveAggregates = Set<AudioDeviceID>()
    private(set) var liveIOProcs = 0
    private(set) var startCount = 0
    private(set) var runningIO = false
    private(set) var requestedBufferFrames: UInt32?
    /// El último bloque instalado, para hacerlo girar desde el test.
    private(set) var block: AudioDeviceIOBlock?
    private var observerTokens: [Weak] = []
    private var nextID: AudioObjectID = 100
    private var polls = 0

    var liveObservers: Int { observerTokens.filter { $0.value != nil }.count }
    var everythingReleased: Bool {
        liveTaps.isEmpty && liveAggregates.isEmpty && liveIOProcs == 0 && !runningIO
            && liveObservers == 0
    }

    private let outputDevice: AudioDeviceID = 42

    func defaultOutputDevice() throws -> AudioDeviceID { outputDevice }
    func uid(of device: AudioObjectID) throws -> String { "fake-\(device)" }
    func name(of device: AudioObjectID) throws -> String { "Parlantes de prueba" }
    func ownProcessObject() throws -> AudioObjectID { 7 }

    func streamFormat(of device: AudioObjectID,
                      scope: AudioObjectPropertyScope) throws -> AudioStreamBasicDescription {
        outputFormat
    }

    func streamLayout(of device: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int] {
        let input = scope == kAudioObjectPropertyScopeInput
        if device == outputDevice { return input ? physicalInputLayout : outputLayout }
        guard liveAggregates.contains(device) else { return [] }
        guard input else { return outputLayout }
        polls += 1
        guard polls > pollsUntilReady else { return physicalInputLayout }
        return aggregateInputLayout ?? physicalInputLayout + [Int(tapFormat.mChannelsPerFrame)]
    }

    func createTap(excluding processes: [AudioObjectID],
                   deviceUID: String) throws -> (id: AudioObjectID, uuid: UUID) {
        tapsCreated += 1
        let id = makeID()
        liveTaps.insert(id)
        return (id, UUID())
    }

    func tapFormat(of tap: AudioObjectID) throws -> AudioStreamBasicDescription { tapFormat }

    func destroyTap(_ tap: AudioObjectID) -> OSStatus {
        liveTaps.remove(tap) == nil ? OSStatus(kAudioHardwareBadObjectError) : noErr
    }

    func createAggregate(tapUUID: UUID, outputDeviceUID: String) throws -> AudioDeviceID {
        if failCreateAggregate { throw AudioError("agregado de prueba que falla") }
        polls = 0
        let id = makeID()
        liveAggregates.insert(id)
        return id
    }

    func destroyAggregate(_ device: AudioDeviceID) -> OSStatus {
        // Destruir el agregado también detiene su E/S, como en la HAL de verdad.
        runningIO = false
        return liveAggregates.remove(device) == nil ? OSStatus(kAudioHardwareBadObjectError) : noErr
    }

    func bufferFrameSize(of device: AudioDeviceID) -> UInt32 { requestedBufferFrames ?? 512 }
    func setBufferFrameSize(_ frames: UInt32, of device: AudioDeviceID) {
        requestedBufferFrames = frames
    }

    func createIOProc(on device: AudioDeviceID,
                      _ block: @escaping AudioDeviceIOBlock) throws -> IOProcHandle {
        self.block = block
        liveIOProcs += 1
        return IOProcHandle(device: device)
    }

    func startIO(_ handle: IOProcHandle) throws {
        if failStartIO { throw AudioError("arranque de prueba que falla") }
        startCount += 1
        runningIO = true
    }

    func stopIO(_ handle: IOProcHandle) -> OSStatus {
        guard stopIOStatus == noErr else { return stopIOStatus }
        runningIO = false
        return noErr
    }

    func destroyIOProc(_ handle: IOProcHandle) -> OSStatus {
        guard destroyIOProcStatus == noErr else { return destroyIOProcStatus }
        liveIOProcs -= 1
        return noErr
    }

    func observe(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope,
                 _ handler: @escaping () -> Void) -> AnyObject? {
        let token = Token(handler)
        observerTokens.append(Weak(token))
        return token
    }

    /// Dispara todos los observadores vivos, como un cambio de dispositivo.
    func notifyChange() {
        for token in observerTokens.compactMap({ $0.value }) { token.handler() }
    }

    /// Hace girar el IOProc una vez con la entrada dada.
    func drive(input: TestBufferList, output: TestBufferList) {
        var stamp = AudioTimeStamp()
        withUnsafePointer(to: &stamp) { time in
            block?(time, UnsafePointer(input.list.unsafeMutablePointer), time,
                   output.list.unsafeMutablePointer, time)
        }
    }

    private func makeID() -> AudioObjectID {
        nextID += 1
        return nextID
    }

    final class Token {
        let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
    }

    private struct Weak {
        weak var value: Token?
        init(_ value: Token) { self.value = value }
    }
}
