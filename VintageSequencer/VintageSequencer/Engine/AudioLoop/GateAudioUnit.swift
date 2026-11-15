import AVFoundation
import AudioToolbox

// MARK: - GateAudioUnit (v1.15.0)
//
// Rauschgate als app-eigene Audio Unit, damit es im Kanalzug an beliebiger Stelle stehen kann
// (vor oder nach dem Fader). Im eigenen Prozess registriert und geladen — eigener Code, keine
// Sandbox-Abfrage. Der Renderblock fängt nur Zeiger auf vorab angelegten Speicher und das
// `GateControl` (Atomics); kein Zugriff auf `self`.

final class GateAudioUnit: AUAudioUnit {

    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x66676174,        // 'fgat'
        componentManufacturer: 0x466F4673,   // 'FoFs'
        // Eigener Code im eigenen Prozess: als sandbox-tauglich ausweisen. Ohne das Flag fragt
        // macOS beim Anlegen, ob die Sicherheitseinstellungen gesenkt werden sollen (gemessen:
        // `ACSandboxHelper::askToOpenComponent` blockiert).
        componentFlags: AudioComponentFlags.sandboxSafe.rawValue, componentFlagsMask: 0)

    private static let registered: Void = {
        AUAudioUnit.registerSubclass(GateAudioUnit.self, as: GateAudioUnit.componentDescription,
                                     name: "FIRSTofFIFTH: Gate", version: 1)
    }()
    static func register() { _ = registered }

    /// Einstellungen; Main schreibt, der Renderblock liest.
    let control = GateControl()

    private var inputBus:  AUAudioUnitBus!
    private var outputBus: AUAudioUnitBus!
    private var inputArray:  AUAudioUnitBusArray!
    private var outputArray: AUAudioUnitBusArray!
    private let dsp: UnsafeMutablePointer<GateDSP>
    private let scratchL: UnsafeMutablePointer<Float>
    private let scratchR: UnsafeMutablePointer<Float>
    private static let scratchFrames = 8192

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        dsp = .allocate(capacity: 1); dsp.initialize(to: GateDSP())
        scratchL = .allocate(capacity: Self.scratchFrames); scratchL.initialize(repeating: 0, count: Self.scratchFrames)
        scratchR = .allocate(capacity: Self.scratchFrames); scratchR.initialize(repeating: 0, count: Self.scratchFrames)
        try super.init(componentDescription: componentDescription, options: options)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        inputBus  = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        inputArray  = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        maximumFramesToRender = AUAudioFrameCount(Self.scratchFrames)
    }

    deinit {
        dsp.deinitialize(count: 1); dsp.deallocate()
        scratchL.deallocate(); scratchR.deallocate()
    }

    override var inputBusses: AUAudioUnitBusArray { inputArray }
    override var outputBusses: AUAudioUnitBusArray { outputArray }
    override var canProcessInPlace: Bool { true }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        dsp.pointee.reset()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let dsp = dsp, control = control, scratchL = scratchL, scratchR = scratchR
        let maxFrames = Self.scratchFrames
        let sampleRate = outputBus.format.sampleRate
        return { flags, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pull = pullInputBlock else { return kAudioUnitErr_NoConnection }
            let n = Int(frameCount)
            guard n <= maxFrames else { return kAudioUnitErr_TooManyFramesToProcess }
            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            // Ohne eigene Puffer des Aufrufers in den vorab angelegten Speicher ziehen.
            if abl.count > 0, abl[0].mData == nil { abl[0].mData = UnsafeMutableRawPointer(scratchL) }
            if abl.count > 1, abl[1].mData == nil { abl[1].mData = UnsafeMutableRawPointer(scratchR) }
            var pullFlags = AudioUnitRenderActionFlags()
            let err = pull(&pullFlags, timestamp, frameCount, 0, outputData)
            guard err == noErr else { return err }
            guard abl.count > 0, let l = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let r = abl.count > 1 ? abl[1].mData?.assumingMemoryBound(to: Float.self) ?? l : l
            dsp.pointee.process(l, r, frames: n, sampleRate: sampleRate, control.values())
            return noErr
        }
    }
}
