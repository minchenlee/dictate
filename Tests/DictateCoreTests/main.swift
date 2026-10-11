import Darwin
import Testing

// `swift test` under Command Line Tools 6.2 exits 0 without running anything,
// so the tests live in an executable that calls the swift-testing entry point.
// Run: swift run DictateChecks   (accepts swift-testing flags, e.g. --filter HoldMode)
let code: CInt = await __swiftPMEntryPoint()
exit(code)
