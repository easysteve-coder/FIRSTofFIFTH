import Foundation

// MARK: - HostTime (v1.16.1, Codex V16-6)
//
// Umrechnung Host-Zeit (mach_absolute_time) ↔ Nanosekunden und Verschiebung um Sekunden.
// Vorher statische Helfer von `SequencerEngine`; der Tick-Kern braucht sie ohne die Engine.
// RT-sicher: nur Arithmetik auf einer einmal gelesenen Zeitbasis.

enum HostTime {
    static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// `t` um `seconds` verschoben (auch negativ), ohne Unterlauf.
    @inline(__always)
    static func shifted(_ t: UInt64, bySeconds seconds: Double) -> UInt64 {
        if seconds >= 0 { return t &+ nanosToMachTime(UInt64(seconds * 1_000_000_000)) }
        let back = nanosToMachTime(UInt64(-seconds * 1_000_000_000))
        return t > back ? t - back : 0
    }

    static func machToNanos(_ t: UInt64) -> UInt64 {
        let tb = timebase
        return UInt64(Double(t) * Double(tb.numer) / Double(tb.denom))
    }

    /// mach_time = ns × denom / numer; der kleinere Faktor zuerst (Überlaufschutz).
    static func nanosToMachTime(_ ns: UInt64) -> UInt64 {
        let tb = timebase
        return (tb.denom <= tb.numer)
            ? ns * UInt64(tb.denom) / UInt64(tb.numer)
            : ns / UInt64(tb.numer) * UInt64(tb.denom)
    }
}
