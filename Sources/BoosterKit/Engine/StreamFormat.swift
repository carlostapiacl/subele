import CoreAudio

/// Qué formato acepta el motor, comprobado antes de tocar el audio de nadie.
///
/// El callback lee y escribe los buffers como `Float` y calcula los frames
/// suponiendo cuatro bytes por muestra. Cualquier otra cosa —enteros de 16 bits,
/// float64, big-endian— leída así es ruido en el mejor caso y lectura fuera del
/// buffer en el peor. En la práctica la HAL le entrega float32 nativo a todo
/// IOProc, pero "en la práctica" no es una garantía, así que se verifica cada
/// campo y se rechaza antes de crear el tap: rechazado ahí, el sistema sigue
/// sonando como siempre.
public enum StreamFormat {

    /// Más canales que esto no se procesan. Alcanza para 7.1.4 con margen y deja
    /// los buffers del DSP en tamaños razonables.
    public static let maximumChannels = Limiter.maximumChannels

    /// nil si el formato sirve; si no, por qué no.
    public static func problem(with format: AudioStreamBasicDescription) -> String? {
        guard format.mFormatID == kAudioFormatLinearPCM else {
            return "no es PCM lineal (\(fourCharCode(OSStatus(bitPattern: format.mFormatID))))"
        }
        let flags = format.mFormatFlags
        guard flags & kAudioFormatFlagIsFloat != 0 else { return "no es punto flotante" }
        guard flags & kAudioFormatFlagIsBigEndian == 0 else { return "es big-endian" }
        guard format.mBitsPerChannel == 32 else {
            return "\(format.mBitsPerChannel) bits por muestra en vez de 32"
        }
        let channels = format.mChannelsPerFrame
        guard channels > 0 else { return "no tiene canales" }
        guard channels <= UInt32(maximumChannels) else {
            return "\(channels) canales; el máximo es \(maximumChannels)"
        }
        // Intercalado: un frame son todos los canales. No intercalado: un buffer por
        // canal y un frame es una sola muestra.
        let nonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        let expectedBytes = nonInterleaved ? 4 : 4 * channels
        guard format.mBytesPerFrame == expectedBytes else {
            return "\(format.mBytesPerFrame) bytes por frame en vez de \(expectedBytes)"
        }
        guard format.mFramesPerPacket == 1 else { return "más de un frame por paquete" }
        guard format.mSampleRate > 0 else { return "sin frecuencia de muestreo" }
        return nil
    }

    /// Lanza con un mensaje que nombra qué lado falló.
    static func require(_ format: AudioStreamBasicDescription, _ side: String) throws {
        if let problem = problem(with: format) {
            throw AudioError("\(side): formato no soportado — \(problem)")
        }
    }
}
