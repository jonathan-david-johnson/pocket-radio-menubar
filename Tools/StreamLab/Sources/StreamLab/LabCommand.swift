import Foundation

/// Parsing is deliberately separated from running so command handling can be
/// tested without opening a stream, contacting a feed, or playing audio.
enum LabCommand {
    case help
    case capture(CaptureOptions)
    case replay(URL)
}

enum LabDispatch {
    static let usage = """
    stream-lab — observation-only stream capture and offline replay.

    USAGE
      stream-lab capture --station kcrw|kexp --stream-url URL --output FILE
                         [--duration SECONDS] [--feed-interval SECONDS]
                         [--feed-url URL | --no-feed] [--muted]
      stream-lab replay FILE
      stream-lab help

    CAPTURE
      --station kcrw|kexp   Station feed parser and default public feed endpoint
      --stream-url URL      Explicit HTTP(S) stream or local file:// fixture
      --output FILE         New JSONL trace path; an existing file is never overwritten
      --duration SECONDS    Capture length, 1–7200 (default 300)
      --feed-interval SEC   Serial feed-poll interval, 5–300 (default 30)
      --feed-url URL        Explicit HTTP(S) feed endpoint
      --no-feed             Disable feed requests; cannot be combined with --feed-url
      --muted               Mute output; this prevents an audible-marker experiment

      While capturing: 1=song change, 2=lyric landmark, 3=wrong artwork,
      p=pause, r=resume, q=finish. Ctrl-C and SIGTERM also end cleanly.

    REPLAY
      Reads only the named trace file. It contacts no stream, feed, or account.
    """

    static func parse(_ arguments: [String]) throws -> LabCommand {
        guard let command = arguments.first else { throw UsageError("No command given") }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "help", "--help", "-h":
            return .help
        case "capture":
            return .capture(try CaptureOptions(rest))
        case "replay":
            guard rest.count == 1, let path = rest.first, !path.isEmpty else {
                throw UsageError("replay takes exactly one trace file path")
            }
            return .replay(URL(fileURLWithPath: path))
        default:
            throw UsageError("Unknown command \(String(reflecting: command))")
        }
    }
}
