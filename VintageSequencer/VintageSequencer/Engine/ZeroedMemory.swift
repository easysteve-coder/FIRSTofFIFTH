import Foundation

// MARK: - ZeroedMemory (v1.17.7)
//
// Feste Puffer je Kanal (Ereignisringe, Loop-Arbeitspuffer) für 64 Kanäle. Sie werden beim
// Anlegen des Racks reserviert, aber nicht beschrieben: anonyme `mmap`-Seiten sind genullt
// und werden erst bei der ersten Berührung real belegt (`calloc` tut das für kleine Blöcke
// nicht — sie kommen aus dem Heap und werden sofort genullt). Wird ein Kanal benutzt, berührt
// Main seine Puffer einmal vorab (`prefault`) — die Echtzeit-Threads treffen danach nie auf
// eine erste Seitenberührung. Nur für Elementtypen, deren Nullmuster ein gültiger Wert ist.
enum ZeroedMemory {
    private static let page = Int(getpagesize())
    private static func length(_ bytes: Int) -> Int { max(page, (bytes + page - 1) / page * page) }

    static func allocate<T>(_ count: Int, of: T.Type = T.self) -> UnsafeMutablePointer<T> {
        let raw = mmap(nil, length(count * MemoryLayout<T>.stride), PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANON, -1, 0)
        guard let raw, raw != MAP_FAILED else {
            fatalError("ZeroedMemory: \(count) × \(T.self) nicht reservierbar")
        }
        return raw.bindMemory(to: T.self, capacity: count)       // Seitenanfang: ausgerichtet
    }

    /// Gibt einen Puffer frei; `count` wie bei `allocate`.
    static func free<T>(_ p: UnsafeMutablePointer<T>, count: Int) {
        munmap(UnsafeMutableRawPointer(p), length(count * MemoryLayout<T>.stride))
    }

    /// Main: Seiten real belegen (Inhalt bleibt null). Nur, solange kein Echtzeit-Leser den
    /// Puffer benutzt (vor dem Aktivieren).
    static func prefault<T>(_ p: UnsafeMutablePointer<T>, count: Int) {
        memset(p, 0, count * MemoryLayout<T>.stride)
    }
}
