import Foundation
import StreamDiagnostics

@main
struct StreamLab {
    static func main() async {
        do {
            switch try LabDispatch.parse(Array(CommandLine.arguments.dropFirst())) {
            case .help:
                print(LabDispatch.usage)
            case .replay(let url):
                try replay(url)
            case .select(let options):
                try select(options)
            case .compare(let options):
                try compare(options)
            case .capture(let options):
                guard await runCapture(options) else { exit(1) }
            }
        } catch let error as UsageError {
            fail("\(error.description)\n\n\(LabDispatch.usage)", code: 2)
        } catch {
            fail(LabFailure.describe(error), code: 1)
        }
    }

    /// Reads only the named file. No stream, feed, account, or Supabase access.
    private static func replay(_ url: URL) throws {
        do {
            print(try ReplayReport.render(try TraceReader.read(url: url)))
        } catch {
            fail("Cannot replay trace: \(LabFailure.describe(error))", code: 1)
        }
    }

    /// Reads only the named trace and annotation files. No network or account access.
    private static func select(_ options: SelectionOptions) throws {
        do {
            let events = try TraceReader.read(url: options.traceURL)
            let annotations = try SelectionAnnotations.read(url: options.annotationsURL)
            print(try SelectionReplay.render(events: events, annotations: annotations,
                                             offsetSeconds: options.offsetSeconds))
        } catch {
            fail("Cannot replay selection: \(LabFailure.describe(error))", code: 1)
        }
    }

    /// Reads only explicit local trace/annotation pairs and renders one comparison.
    private static func compare(_ options: SelectionComparisonOptions) throws {
        do {
            let inputs = try options.pairs.map { pair in
                SelectionReplayInput(events: try TraceReader.read(url: pair.traceURL),
                                     annotations: try SelectionAnnotations.read(url: pair.annotationsURL))
            }
            print(try SelectionComparison.render(inputs: inputs,
                                                 primaryOffset: options.offsetSeconds))
        } catch {
            fail("Cannot compare selections: \(LabFailure.describe(error))", code: 1)
        }
    }

    @MainActor
    private static func runCapture(_ options: CaptureOptions) async -> Bool {
        do {
            return await (try CaptureSession(options: options)).run()
        } catch {
            fail("Cannot start capture: \(LabFailure.describe(error))", code: 1)
        }
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        fputs(message + "\n", stderr)
        exit(code)
    }
}
