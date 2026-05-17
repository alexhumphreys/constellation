import ConstellationLogging
import Foundation
import Testing

@Suite("WideEvent + sinks")
struct WideEventTests {

    @Test("Composite sink fans out to every child")
    func compositeFanout() {
        let a = RecordingSink()
        let b = RecordingSink()
        let composite = CompositeSink([a, b])
        composite.emit(WideEvent(op: "test.x"))
        #expect(a.events.count == 1)
        #expect(b.events.count == 1)
        #expect(a.events[0].op == "test.x")
    }

    @Test("WideValue literals map to the right cases")
    func valueLiterals() {
        let s: WideValue = "hi"
        let i: WideValue = 42
        let d: WideValue = 3.14
        let b: WideValue = true
        #expect(s.stringValue == "hi")
        #expect(i.intValue == 42)
        #expect(d.doubleValue == 3.14)
        #expect(b.boolValue == true)
    }

    @Test("Subscript access on fields")
    func subscriptAccess() {
        var event = WideEvent(op: "x")
        event["skill_id"] = .string("hip-key")
        event["count"] = .int(3)
        #expect(event["skill_id"]?.stringValue == "hip-key")
        #expect(event["count"]?.intValue == 3)
    }

    @Test("Recording sink survives concurrent emissions")
    func concurrentEmissions() async {
        let sink = RecordingSink()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    sink.emit(WideEvent(
                        op: "test.concurrent",
                        fields: ["i": .int(Int64(i))]
                    ))
                }
            }
        }
        #expect(sink.events.count == 100)
    }
}
