import Foundation

let mappingKey = "UserKeyMapping"
let srcKey = "HIDKeyboardModifierMappingSrc"
let dstKey = "HIDKeyboardModifierMappingDst"
let capsLock: UInt64 = 0x700000039
let leftControl: UInt64 = 0x7000000E0
let rightControl: UInt64 = 0x7000000E4
let rightCommand: UInt64 = 0x7000000E7
let supportedProducts: Set<String> = [
    "Apple Internal Keyboard / Trackpad", "Natural® Ergonomic Keyboard 4000"
]

func entry(_ source: UInt64, _ destination: UInt64) -> NSDictionary {
    [srcKey: NSNumber(value: source), dstKey: NSNumber(value: destination)]
}

enum Decision {
    case append(NSArray)
    case unchanged(String)
}

// Pure policy: never mutate or normalize the original array/dictionaries.
// Unknown fields and unrelated entries survive byte-for-byte at the value level.
func plan(_ value: Any?) -> Decision {
    guard let mappings = value as? NSArray else {
        return .unchanged("skipped: mapping array unavailable; start Raycast and try again")
    }
    var destinations: [UInt64: [UInt64]] = [:]
    for object in mappings {
        guard let dictionary = object as? NSDictionary,
              let source = dictionary[srcKey] as? NSNumber,
              let destination = dictionary[dstKey] as? NSNumber,
              CFGetTypeID(source) != CFBooleanGetTypeID(),
              CFGetTypeID(destination) != CFBooleanGetTypeID(),
              source.doubleValue == Double(source.uint64Value),
              destination.doubleValue == Double(destination.uint64Value) else {
            return .unchanged("refusing: malformed mapping entry")
        }
        destinations[source.uint64Value, default: []].append(destination.uint64Value)
    }
    // Exactly one entry for each baseline source: duplicates are ambiguous,
    // even if their destinations happen to agree.
    guard destinations[capsLock] == [rightControl],
          destinations[rightControl] == [leftControl] else {
        return .unchanged("skipped: Raycast baseline missing or ambiguous; check Hyper Key and try again")
    }
    if let existing = destinations[rightCommand] {
        return .unchanged(existing == [rightControl]
            ? "already configured" : "refusing: Right Command conflict or duplicate")
    }
    let result = mappings.mutableCopy() as! NSMutableArray
    result.add(entry(rightCommand, rightControl))
    return .append(result.copy() as! NSArray)
}

func selfTest() {
    var count = 0
    func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fatalError("FAIL: \(name)") }
        count += 1
    }
    func unchanged(_ value: Any?) -> Bool {
        if case .unchanged = plan(value) { return true }; return false
    }
    let baseline: NSArray = [entry(capsLock, rightControl), entry(rightControl, leftControl)]
    guard case .append(let appended) = plan(baseline) else { fatalError("baseline") }
    check(appended.count == 3, "append exactly one")
    check(baseline.count == 2, "input is immutable")
    check(unchanged(appended), "idempotence")
    check(unchanged(nil), "missing array")
    check(unchanged(NSArray()), "empty baseline")
    check(unchanged([entry(capsLock, rightControl)] as NSArray), "partial baseline")
    check(unchanged(baseline.adding(entry(rightCommand, leftControl)) as NSArray), "conflict")
    check(unchanged(appended.adding(entry(rightCommand, rightControl)) as NSArray), "duplicate custom mapping")
    check(unchanged(baseline.adding(entry(capsLock, rightControl)) as NSArray), "duplicate baseline")
    check(unchanged(baseline.adding(entry(rightControl, rightCommand)) as NSArray), "conflicting baseline")
    check(unchanged(baseline.adding([srcKey: "bad"]) as NSArray), "malformed entry")
    let extra: NSDictionary = [srcKey: 0x700000004, dstKey: 0x700000005, "metadata": "keep"]
    let extended = baseline.adding(extra) as NSArray
    guard case .append(let preserved) = plan(extended) else { fatalError("preservation") }
    check((preserved.subarray(with: NSRange(location: 0, length: 3)) as NSArray).isEqual(extended), "preserve order and fields")
    check(!supportedProducts.contains("2.4G Receiver"), "exclude receiver")
    print("PASS: \(count) policy tests (no HID access)")
}

func log(_ message: String) {
    print("\(ISO8601DateFormatter().string(from: Date())) \(message)")
    fflush(stdout)
}

final class Manager {
    let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    let write: Bool
    let journalURL: URL?
    var journal: [[String: Any]] = []
    var failed = false

    init(write: Bool, journalURL: URL?) {
        self.write = write
        self.journalURL = journalURL
    }

    func services() -> [IOHIDServiceClient]? {
        IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]
    }

    func property(_ service: IOHIDServiceClient, _ key: String) -> Any? {
        IOHIDServiceClientCopyProperty(service, key as CFString)
    }

    func identity(_ service: IOHIDServiceClient) -> String {
        String(describing: IOHIDServiceClientGetRegistryID(service))
    }

    func eligible(_ service: IOHIDServiceClient) -> Bool {
        IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop),
                                    UInt32(kHIDUsage_GD_Keyboard)) != 0 &&
        supportedProducts.contains(property(service, "Product") as? String ?? "")
    }

    func reconcile(_ reason: String) {
        guard let current = services() else {
            log("ERROR: HID services unavailable; no mappings changed")
            failed = true
            return
        }
        for service in current {
            let id = identity(service)
            let product = property(service, "Product") as? String ?? "Unknown"
            guard eligible(service) else {
                if product == "2.4G Receiver" { log("excluded: \(product) [\(id)]") }
                continue
            }
            let before = property(service, mappingKey)
            switch plan(before) {
            case .unchanged(let explanation):
                log("\(product) [\(id)]: \(explanation)")
                if write && explanation != "already configured" { failed = true }
            case .append(let after):
                guard write else {
                    log("\(product) [\(id)]: would append Right Command → Right Control")
                    continue
                }
                // Narrow the read-modify-write race with Raycast. IOKit has no
                // atomic compare-and-swap API for this property.
                guard let original = before as? NSArray,
                      let latest = property(service, mappingKey) as? NSArray,
                      latest.isEqual(original) else {
                    failed = true
                    log("\(product): changed during read; run the command again")
                    continue
                }
                // Save before writing so an interrupted process still has rollback data.
                if let url = journalURL {
                    journal.append(["id": id, "product": product, "before": original, "after": after])
                    do {
                        let data = try PropertyListSerialization.data(fromPropertyList: journal, format: .xml, options: 0)
                        try data.write(to: url, options: .atomic)
                    } catch {
                        journal.removeLast()
                        failed = true
                        log("ERROR: cannot save rollback journal: \(error)"); continue
                    }
                }
                guard IOHIDServiceClientSetProperty(service, mappingKey as CFString, after) else {
                    failed = true
                    log("ERROR: \(product): mapping write rejected"); continue
                }
                let actual = property(service, mappingKey) as? NSArray
                if actual?.isEqual(after) == true {
                    log("\(product) [\(id)]: applied and verified (\(reason))")
                } else {
                    failed = true
                    log("ERROR: \(product): readback differs; preserving current state")
                }
            }
        }
    }

    func restore(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let records = try PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]],
              let current = services() else { throw NSError(domain: "Invalid journal or unavailable HID services", code: 1) }
        for record in records.reversed() {
            guard let id = record["id"] as? String,
                  let before = record["before"] as? NSArray,
                  let after = record["after"] as? NSArray,
                  let service = current.first(where: { identity($0) == id && eligible($0) }),
                  property(service, "Product") as? String == record["product"] as? String else {
                log("Rollback skipped: service no longer connected or journal invalid"); continue
            }
            guard (property(service, mappingKey) as? NSArray)?.isEqual(after) == true else {
                log("Rollback skipped [\(id)]: mappings changed since our write"); continue
            }
            let success = IOHIDServiceClientSetProperty(service, mappingKey as CFString, before)
                && (property(service, mappingKey) as? NSArray)?.isEqual(before) == true
            log("Rollback [\(id)]: \(success ? "restored and verified" : "FAILED")")
            if !success { failed = true }
        }
    }
}

var args = Array(CommandLine.arguments.dropFirst())
// A normal manual run chooses a unique journal automatically.
if args == ["--apply"] {
    let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/KeyboardManager/Rollbacks", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let journal = directory.appendingPathComponent(UUID().uuidString + ".plist")
        log("Rollback journal (created only if a mapping changes): \(journal.path)")
        args = ["--once", "--journal", journal.path]
    } catch { log("ERROR: cannot create rollback directory: \(error)"); exit(1) }
}
if args == ["--self-test"] {
    selfTest()
} else if args.count == 2 && args[0] == "--restore" {
    do {
        let manager = Manager(write: false, journalURL: nil)
        try manager.restore(URL(fileURLWithPath: args[1]))
        if manager.failed { exit(1) }
    }
    catch { log("ERROR: \(error)"); exit(1) }
} else if args == ["--inspect"] {
    let manager = Manager(write: false, journalURL: nil)
    guard let services = manager.services() else { log("ERROR: HID services unavailable"); exit(1) }
    for service in services where IOHIDServiceClientConformsTo(service, 1, 6) != 0 {
        print("\(manager.property(service, "Product") ?? "Unknown") [\(manager.identity(service))] eligible=\(manager.eligible(service))")
        print(manager.property(service, mappingKey) ?? "no mappings")
    }
    manager.reconcile("inspect")
} else if args.count == 3 && args[0] == "--once" && args[1] == "--journal" {
    let url = URL(fileURLWithPath: args[2])
    guard !FileManager.default.fileExists(atPath: url.path) else {
        log("ERROR: choose a new journal path; existing rollback data will not be overwritten"); exit(1)
    }
    let manager = Manager(write: true, journalURL: url)
    guard manager.services() != nil else { log("ERROR: HID services unavailable"); exit(1) }
    manager.reconcile("manual run")
    if manager.failed { exit(1) }
} else {
    print("Usage: keyboard-manager --apply | --inspect | --self-test | --once --journal PATH | --restore PATH")
    exit(args.isEmpty ? 0 : 2)
}
