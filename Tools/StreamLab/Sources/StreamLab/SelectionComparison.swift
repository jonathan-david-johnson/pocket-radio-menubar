import Foundation
import StreamDiagnostics

struct SelectionReplayInput {
    let events: [TraceEvent]
    let annotations: SelectionAnnotations
}

enum SelectionComparison {
    static func render(inputs: [SelectionReplayInput], primaryOffset: Double = 160,
                       sensitivityOffsets: [Double] = [158, 159, 160, 161, 162, 163]) throws -> String {
        guard !inputs.isEmpty else { throw SelectionReplayError.invalid("comparison needs at least one session") }
        guard primaryOffset.isFinite,
              !sensitivityOffsets.isEmpty,
              sensitivityOffsets.allSatisfy(\.isFinite) else {
            throw SelectionReplayError.invalid("comparison offsets must be finite")
        }

        let primary = try inputs.map {
            try SelectionReplay.analyze(events: $0.events, annotations: $0.annotations,
                                        offsetSeconds: primaryOffset)
        }
        let primaryMetrics = combinedMetrics(analyses: primary)

        var lines = [
            "stream-lab compare — M11-A development evidence; not an independent holdout.",
            "",
            "primary offset: \(signed(primaryOffset))s",
            "sessions: \(inputs.count)",
            "included markers measured: \(primaryMetrics.measured)/\(primaryMetrics.expected)",
            "combined median absolute error: \(optionalSeconds(primaryMetrics.medianAbsoluteError))",
            "combined worst absolute error: \(optionalSeconds(primaryMetrics.worstAbsoluteError))",
            "",
            "sensitivity (fixed before retained-trace replay)",
            "  offset     measured   median-abs   worst-abs",
        ]

        for offset in sensitivityOffsets {
            let analyses = try inputs.map {
                try SelectionReplay.analyze(events: $0.events, annotations: $0.annotations,
                                            offsetSeconds: offset)
            }
            let metrics = combinedMetrics(analyses: analyses)
            lines.append("  \(paddedSigned(offset))   \(metrics.measured)/\(metrics.expected)"
                         + "       \(paddedOptional(metrics.medianAbsoluteError))"
                         + "      \(paddedOptional(metrics.worstAbsoluteError))")
        }

        lines.append("")
        lines.append("leave-one-session-out median calibration")
        if inputs.count < 2 {
            lines.append("  unavailable: at least two sessions are required")
        } else {
            for trainingIndex in inputs.indices {
                let trainingAnalysis = primary[trainingIndex]
                let observed = trainingAnalysis.markerResults.compactMap { result -> Double? in
                    guard result.includedInMetrics else { return nil }
                    return result.observedProgramOffsetSeconds
                }
                guard let fitted = median(observed) else {
                    lines.append("  \(inputs[trainingIndex].annotations.traceFilename): no calibration markers")
                    continue
                }
                let evaluationInputs = inputs.enumerated().filter { $0.offset != trainingIndex }.map(\.element)
                let evaluations = try evaluationInputs.map {
                    try SelectionReplay.analyze(events: $0.events, annotations: $0.annotations,
                                                offsetSeconds: fitted)
                }
                let metrics = combinedMetrics(analyses: evaluations)
                let evaluatedNames = evaluationInputs.map { $0.annotations.traceFilename }.joined(separator: ",")
                lines.append("  train=\(inputs[trainingIndex].annotations.traceFilename)"
                             + " fitted=\(signed(fitted))s evaluate=\(evaluatedNames)")
                lines.append("    measured=\(metrics.measured)/\(metrics.expected)"
                             + " median-abs=\(optionalSeconds(metrics.medianAbsoluteError))"
                             + " worst-abs=\(optionalSeconds(metrics.worstAbsoluteError))")
            }
        }

        lines.append("")
        lines.append("primary session reports")
        for (index, input) in inputs.enumerated() {
            lines.append("")
            lines.append("=== session \(index + 1): \(input.annotations.traceFilename) ===")
            lines.append(try SelectionReplay.render(events: input.events,
                                                    annotations: input.annotations,
                                                    offsetSeconds: primaryOffset))
        }

        lines.append("")
        lines.append("Comparison boundary: both retained sessions helped motivate the rule.")
        lines.append("Only fresh fixed-policy sessions can act as holdout evidence for M11-B.")
        return lines.joined(separator: "\n")
    }

    private static func combinedMetrics(analyses: [SelectionAnalysis]) -> ComparisonMetrics {
        let results = analyses.flatMap(\.markerResults).filter(\.includedInMetrics)
        let errors = results.compactMap(\.signedErrorSeconds).map(abs).sorted()
        return ComparisonMetrics(expected: results.count, measured: errors.count,
                                 medianAbsoluteError: median(errors),
                                 worstAbsoluteError: errors.last)
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    private static func signed(_ value: Double) -> String { String(format: "%+.3f", value) }
    private static func seconds(_ value: Double) -> String { String(format: "%.3fs", value) }
    private static func optionalSeconds(_ value: Double?) -> String { value.map(seconds) ?? "unavailable" }
    private static func paddedSigned(_ value: Double) -> String { String(format: "%+8.3fs", value) }
    private static func paddedOptional(_ value: Double?) -> String {
        value.map { String(format: "%8.3fs", $0) } ?? "unavailable"
    }
}

private struct ComparisonMetrics {
    let expected: Int
    let measured: Int
    let medianAbsoluteError: Double?
    let worstAbsoluteError: Double?
}
