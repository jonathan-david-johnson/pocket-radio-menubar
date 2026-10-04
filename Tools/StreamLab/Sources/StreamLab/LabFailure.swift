import Foundation
import StreamDiagnostics
import StreamSession

/// One short line per failure. Bridged `NSError` descriptions carry a `UserInfo=`
/// dictionary when interpolated, which buries the reason the operator needs.
enum LabFailure {
    static func describe(_ error: Error) -> String {
        switch error {
        case let error as TraceError: return error.description
        case let error as UsageError: return error.description
        case let error as SelectionReplayError: return error.description
        case let error as StreamSessionError: return error.description
        default: return (error as NSError).localizedDescription
        }
    }
}
