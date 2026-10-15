import Foundation

var failures = 0

func check(_ name: String, _ actual: String, _ expected: String) {
    if actual == expected {
        print("ok    \(name)")
    } else {
        failures += 1
        print("FAIL  \(name): got \"\(actual)\", expected \"\(expected)\"")
    }
}

let rules = UserFiles.rules(explicit: ["teh => the", "price => $5", "path => C:\\temp"], vocabulary: ["WhisperKit", "SpeechAnalyzer"])

check("strips leading filler", TextPolish.apply("um, hello there", rules: []), "Hello there")
check("strips inner filler", TextPolish.apply("so uh we go", rules: []), "So we go")
check("collapses spaces", TextPolish.apply("a   b", rules: []), "A b")
check("capitalises first letter", TextPolish.apply("hello", rules: []), "Hello")
check("explicit rule", TextPolish.apply("fix teh bug", rules: rules), "Fix the bug")
check("explicit rule is case-insensitive", TextPolish.apply("Teh end", rules: rules), "The end")
check("explicit rule keeps word boundary", TextPolish.apply("tehran", rules: rules), "Tehran")
check("dollar in replacement is literal", TextPolish.apply("the price", rules: rules), "The $5")
check("backslash in replacement is literal", TextPolish.apply("open path", rules: rules), "Open C:\\temp")
check("vocabulary joins split camel case", TextPolish.apply("use whisper kit now", rules: rules), "Use WhisperKit now")
check("vocabulary fixes casing", TextPolish.apply("speechanalyzer works", rules: rules), "SpeechAnalyzer works")

let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let store = TranscriptionStore(directory: directory)
for offset in 0..<30 {
    _ = store.save("note \(offset)", timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(offset) * 60))
}
let recent = store.loadRecent(limit: 20)
check("store count", "\(store.count())", "30")
check("recent is capped", "\(recent.count)", "20")
check("recent is newest first", recent.first?.text ?? "", "note 29")
check("recent ends at the 20th newest", recent.last?.text ?? "", "note 10")
check("empty store loads nothing", "\(TranscriptionStore(directory: directory.appendingPathComponent("missing")).loadRecent(limit: 20).count)", "0")
try? FileManager.default.removeItem(at: directory)

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
