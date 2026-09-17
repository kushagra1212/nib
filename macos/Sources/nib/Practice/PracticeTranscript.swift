import Foundation

/// Turns a take into a Markdown file.
///
/// Markdown rather than JSON or plain text, for one reason: this file is meant
/// to be read by a person and pasted to whoever is coaching them. A transcript
/// nobody opens is the same as no transcript.
///
/// The numbers go above the words. Someone reviewing a take wants "you said um
/// fourteen times" first; the transcript is what they read afterwards to find
/// where.
enum PracticeTranscript {
    static func markdown(segments: [SpokenSegment],
                         report: DeliveryReport,
                         audio: URL,
                         date: Date = Date()) -> String {
        var out = ""

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm"

        out += "---\n"
        out += "tags:\n  - practice\n  - speaking\n"
        out += "created: \(ISO8601DateFormatter().string(from: date))\n"
        out += "type: practice-take\n"
        out += "---\n\n"

        out += "# Practice take, \(stamp.string(from: date))\n\n"
        out += "Audio: [\(audio.lastPathComponent)](\(audio.lastPathComponent))\n\n"

        out += "## Delivery\n\n"
        out += "| | |\n|---|---|\n"
        out += "| Length | \(time(report.duration)) |\n"
        out += "| Words | \(report.wordCount) |\n"
        out += "| Pace | **\(Int(report.pace.rounded())) wpm** -- \(report.paceVerdict) |\n"
        out += "| Fillers | **\(report.fillerTotal)** "
        out += "(\(String(format: "%.1f", report.fillerRate))/min) -- \(report.fillerVerdict) |\n"
        out += "| Pauses over \(Int(DeliveryReport.pauseThreshold))s | \(report.longPauses.count) |\n"
        out += "| Longest sentence | \(report.longestSentence) words"
        out += report.longestSentence > 30 ? " -- too long to follow spoken |\n" : " |\n"
        out += "| Ending | \(report.trailsOff ? "**trails off**" : "lands") |\n\n"

        if !report.fillers.isEmpty {
            out += "### What you said instead of nothing\n\n"
            for filler in report.fillers {
                out += "- **\(filler.word)** \u{00D7} \(filler.count)\n"
            }
            out += "\n"
        }

        if !report.longPauses.isEmpty {
            out += "### Where you stalled\n\n"
            out += "Play the audio at these points. A pause is only a problem "
            out += "when it is silent -- thinking out loud is not a pause.\n\n"
            for pause in report.longPauses {
                out += "- **\(time(pause.at))** -- "
                out += "\(String(format: "%.1f", pause.length))s of silence\n"
            }
            out += "\n"
        }

        out += "## What to fix first\n\n"
        let fixes = advice(report)
        if fixes.isEmpty {
            out += "Nothing measurable. Judge the content on its own.\n\n"
        } else {
            for (index, fix) in fixes.enumerated() {
                out += "\(index + 1). \(fix)\n"
            }
            out += "\n"
        }

        out += "## Transcript\n\n"
        if segments.isEmpty {
            out += "*No speech detected.*\n"
        } else {
            for segment in segments {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                out += "**[\(time(segment.start))]** \(text)\n\n"
            }
        }

        return out
    }

    /// Ordered by how much each one costs the listener, not by how easy it is
    /// to fix. A trailing ending undoes an otherwise good answer, so it ranks
    /// above a filler count that merely sounds untidy.
    static func advice(_ report: DeliveryReport) -> [String] {
        var fixes: [String] = []

        if report.trailsOff {
            fixes.append("**End on a full stop.** The take finishes on a "
                + "trailing phrase, which leaves the listener unsure whether "
                + "you are done. Decide your last sentence before you start.")
        }
        if report.fillerRate >= 6 {
            let worst = report.fillers.first
            fixes.append("**Cut the filler.** "
                + "\(String(format: "%.0f", report.fillerRate)) per minute"
                + (worst.map { ", mostly \u{201C}\($0.word)\u{201D}" } ?? "")
                + ". The fix is not talking faster, it is being willing to be "
                + "silent for a second.")
        }
        if report.pace > 185 {
            fixes.append("**Slow down.** \(Int(report.pace.rounded())) wpm is "
                + "past the point where a listener retains detail.")
        } else if report.pace < 110 && report.wordCount > 30 {
            fixes.append("**Pick up the pace.** \(Int(report.pace.rounded())) "
                + "wpm reads as unsure of the answer.")
        }
        if report.longestSentence > 35 {
            fixes.append("**Break up the long sentence.** "
                + "\(report.longestSentence) words is one the listener lost "
                + "halfway through. Spoken sentences want to be under 25.")
        }
        if report.longPauses.count >= 3 {
            fixes.append("**\(report.longPauses.count) silent stalls.** "
                + "Say what you are thinking instead: \u{201C}let me start with "
                + "the simple version\u{201D} buys the same time and sounds "
                + "like reasoning rather than a blank.")
        }
        return fixes
    }

    static func time(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
