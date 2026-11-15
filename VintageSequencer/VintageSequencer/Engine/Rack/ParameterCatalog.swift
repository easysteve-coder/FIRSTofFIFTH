import Foundation
import AVFoundation

// MARK: - ParameterCatalog (v1.18.0, Codex A17-10 — erste Zerlegung des Racks)
//
// Einziger Besitzer der Parameterkataloge gehosteter Plug-ins: schreibbare Parameter je
// Installation (Cache), Beobachtung des Parameterbaums, Quellen eines Kanals (Instrument,
// Effekte), gespeicherte Ziele (`ParameterRef`) und ihre Auflösung zu `ParameterTarget`.
//
// Schnittstelle zum Rack: nur `ParameterCatalogHost` (Kanaldaten, geladene Einheiten, Status,
// Effekt-Warteschlange). Der Katalog verändert keinen Rack-Zustand; Baumwechsel meldet er über
// `onChange` (das Rack löst daraufhin die Routing-Ziele neu auf). Nur Main.

/// Was der Katalog vom Rack lesen darf.
protocol ParameterCatalogHost: AnyObject {
    func catalogChannel(_ id: UUID) -> InstrumentChannelData?
    /// Geladenes Instrument und ob es bereit ist.
    func catalogInstrument(_ id: UUID) -> (unit: AVAudioUnit?, ready: Bool)
    /// Effekte in Kettenfolge: Token der Installation, Einheit (nil = lädt), bereit.
    func catalogEffects(_ id: UUID) -> [(token: UUID, unit: AVAudioUnit?, ready: Bool)]
    /// Platz und Belegung der Warteschlange eines geladenen Effekts.
    func catalogEffectQueue(_ id: UUID, token: UUID) -> (slot: Int, epoch: UInt32)?
}

final class ParameterCatalog {

    struct Info: Identifiable, Equatable {
        let address: UInt64
        let name: String
        /// Gruppe im Parameterbaum des Plug-ins ("" = ohne Gruppe).
        let group: String
        let min: Float
        let max: Float
        var id: UInt64 { address }
    }

    /// Ein Plug-in eines Kanals, dessen Parameter eine CC-Lane steuern kann (v1.17.1).
    struct Source: Identifiable, Equatable {
        /// nil = Instrument; sonst Position in der Effektkette.
        let effectIndex: Int?
        /// Laufende Nummer unter gleichen Plug-ins der Kette (`ParameterRef.effect`).
        let ordinal: Int?
        let name: String
        let component: String
        let ready: Bool
        /// Effekt-Instanz (`PluginRef.instance`); nil beim Instrument.
        var instance: UUID? = nil
        var id: String { effectIndex.map { "fx\($0)" } ?? "inst" }
    }

    weak var host: ParameterCatalogHost?
    /// Ein Parameterbaum hat sich geändert (Main): Ziele neu auflösen.
    var onChange: (() -> Void)?

    private var instrumentCache: [UUID: [Info]] = [:]          // je Kanal
    private var effectCache: [UUID: [Info]] = [:]              // je Effekt-Token
    private var instrumentTrees: [UUID: NSKeyValueObservation] = [:]
    private var effectTrees: [UUID: NSKeyValueObservation] = [:]

    // MARK: Lebenszyklus (vom Rack an festen Punkten gerufen)

    /// Instrument geladen: Baum beobachten (Cache entsteht bei Bedarf).
    func instrumentLoaded(_ unit: AVAudioUnit, channel id: UUID) {
        instrumentCache[id] = nil
        instrumentTrees[id] = unit.auAudioUnit.observe(\.parameterTree) { [weak self] _, _ in
            DispatchQueue.main.async { self?.instrumentCache[id] = nil; self?.onChange?() }
        }
    }
    func instrumentUnloaded(channel id: UUID) {
        instrumentCache[id] = nil; instrumentTrees[id] = nil
    }
    func effectLoaded(_ unit: AVAudioUnit, token: UUID) {
        effectCache[token] = nil
        effectTrees[token] = unit.auAudioUnit.observe(\.parameterTree) { [weak self] _, _ in
            DispatchQueue.main.async { self?.effectCache[token] = nil; self?.onChange?() }
        }
    }
    func effectUnloaded(token: UUID) {
        effectCache[token] = nil; effectTrees[token] = nil
    }

    // MARK: Kataloge

    /// Schreibbare Parameter des Instruments eines Kanals, in der Reihenfolge des Plug-ins.
    func parameters(for id: UUID) -> [Info] {
        if let cached = instrumentCache[id] { return cached }
        guard let unit = host?.catalogInstrument(id).unit else { return [] }
        let list = Self.writableParameters(of: unit)
        instrumentCache[id] = list
        return list
    }

    /// Schreibbare Parameter des Effekts an Position `index` der Kette.
    func effectParameters(for id: UUID, at index: Int) -> [Info] {
        guard let fx = host?.catalogEffects(id), fx.indices.contains(index) else { return [] }
        let token = fx[index].token
        if let cached = effectCache[token] { return cached }
        guard let unit = fx[index].unit else { return [] }
        let list = Self.writableParameters(of: unit)
        effectCache[token] = list
        return list
    }

    /// Baum in Plug-in-Reihenfolge; die innerste Gruppe benennt den Abschnitt.
    static func writableParameters(of unit: AVAudioUnit) -> [Info] {
        var list: [Info] = []
        func walk(_ nodes: [AUParameterNode], group: String) {
            for node in nodes {
                if let g = node as? AUParameterGroup {
                    walk(g.children, group: g.displayName)
                } else if let p = node as? AUParameter,
                          p.flags.contains(.flag_IsWritable), p.maxValue > p.minValue {
                    list.append(Info(address: p.address, name: p.displayName, group: group,
                                     min: p.minValue, max: p.maxValue))
                }
            }
        }
        walk(unit.auAudioUnit.parameterTree?.children ?? [], group: "")
        return list
    }

    func parameterRange(_ address: UInt64, in id: UUID) -> (min: Float, max: Float)? {
        parameters(for: id).first { $0.address == address }.map { ($0.min, $0.max) }
    }

    // MARK: Quellen und Ziele

    /// Instrument und Effekte eines Kanals in Kettenfolge.
    func sources(for id: UUID) -> [Source] {
        guard let host, let data = host.catalogChannel(id) else { return [] }
        var out: [Source] = []
        if let inst = data.instrument {
            out.append(Source(effectIndex: nil, ordinal: nil, name: inst.name,
                              component: inst.componentKey, ready: host.catalogInstrument(id).ready))
        }
        let fx = host.catalogEffects(id)
        for (i, ref) in data.effects.enumerated() {
            let ordinal = data.effects[..<i].filter { $0.componentKey == ref.componentKey }.count
            out.append(Source(effectIndex: i, ordinal: ordinal, name: ref.name, component: ref.componentKey,
                              ready: fx.indices.contains(i) && fx[i].ready, instance: ref.instance))
        }
        return out
    }

    func parameters(for id: UUID, source: Source) -> [Info] {
        source.effectIndex.map { effectParameters(for: id, at: $0) } ?? parameters(for: id)
    }

    /// Gespeichertes Ziel für einen Parameter eines Plug-ins.
    static func ref(_ p: Info, of source: Source) -> ParameterRef {
        ParameterRef(address: p.address, name: p.name, component: source.component, effect: source.ordinal,
                     effectInstance: source.instance)
    }

    /// Plug-in eines gespeicherten Ziels: Instrument, oder die Effekt-Instanz (v1.17.8).
    /// Ziele ohne Instanz (vor der Zuordnung beim Laden) über die laufende Nummer.
    func source(of ref: ParameterRef, in id: UUID) -> Source? {
        let all = sources(for: id)
        if let inst = ref.effectInstance {
            return all.first { $0.effectIndex != nil && $0.instance == inst && $0.component == ref.component }
        }
        guard let ordinal = ref.effect else { return all.first { $0.effectIndex == nil } }
        return all.first { $0.effectIndex != nil && $0.component == ref.component && $0.ordinal == ordinal }
    }

    /// Einmalige Zuordnung beim Laden (Codex A17-04): ein Effekt-Ziel ohne Instanz bekommt die
    /// Instanz, die seine laufende Nummer in der geladenen Kette bezeichnet.
    func bindEffectInstance(_ ref: ParameterRef, in id: UUID) -> ParameterRef {
        guard ref.effectInstance == nil, ref.effect != nil,
              let src = source(of: ref, in: id), let inst = src.instance else { return ref }
        var bound = ref
        bound.effectInstance = inst
        return bound
    }

    /// Löst ein gespeichertes Ziel gegen die geladenen Plug-ins eines Kanals auf. nil, wenn
    /// das Plug-in nicht bereit ist, ein anderes als das gebundene geladen ist oder der
    /// Parameter dort fehlt. Effekt-Ziele tragen Platz und Belegung ihrer Warteschlange.
    func resolve(_ ref: ParameterRef, in id: UUID) -> ParameterTarget? {
        guard let host else { return nil }
        if ref.effect != nil || ref.effectInstance != nil {
            let fx = host.catalogEffects(id)
            guard ref.component != nil, let src = source(of: ref, in: id), src.ready,
                  let index = src.effectIndex, fx.indices.contains(index),
                  let q = host.catalogEffectQueue(id, token: fx[index].token),
                  let p = effectParameters(for: id, at: index).first(where: { $0.address == ref.address })
            else { return nil }
            return ParameterTarget(address: ref.address, min: p.min, max: p.max, queue: q.slot, epoch: q.epoch)
        }
        guard host.catalogInstrument(id).ready, let inst = host.catalogChannel(id)?.instrument else { return nil }
        if let bound = ref.component, bound != inst.componentKey { return nil }
        return parameterRange(ref.address, in: id).map {
            ParameterTarget(address: ref.address, min: $0.min, max: $0.max)
        }
    }

    #if DEBUG
    func _setInstrumentParameters(_ list: [Info], for id: UUID) { instrumentCache[id] = list }
    func _setEffectParameters(_ list: [Info], token: UUID) { effectCache[token] = list }
    #endif
}
