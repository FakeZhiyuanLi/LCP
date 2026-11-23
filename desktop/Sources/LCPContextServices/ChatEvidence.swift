import Foundation
import LCPContextCore

/// Local term selection for chat. The provider always receives the student's full current message.
enum ChatEvidence {
    private static let commonWords: Set<String> = Set("""
        a an the and or but as at by for from in of on to with am are be been do does did is was were
        i me my we our you your it its have has can could would should will please tell give help
        what which when where how why who about this that these those any some there again more
        than then next practice explain summarize show thanks thank
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    static func terms(in message: String) -> [String] {
        // For a pasted long message, both the introduction and closing question can identify the topic.
        let sample = message.utf8.count <= 4_096 ? message : String(message.prefix(1_024)) + " " + String(message.suffix(1_024))
        let folded = sample.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var seen = Set<String>()
        return folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).compactMap { word in
            guard word.utf8.count <= 64, seen.count < 24 else { return nil }
            let term = String(word)
            return !commonWords.contains(term) && seen.insert(term).inserted ? term : nil
        }
    }

    static func matches(_ terms: [String], in text: String) -> [String] {
        terms.filter { text.localizedStandardContains($0) }
    }

    static func terms(for message: String, history: [ChatMessage]) -> [String] {
        var result = terms(in: message)
        guard message.utf8.count <= 512 else { return result }
        let words = message.lowercased().split { !$0.isLetter }.map(String.init)
        let references = ["it", "that", "those", "them", "one", "ones", "continue", "further", "more", "above"]
        guard !Set(words).isDisjoint(with: references) else { return result }
        // A follow-up such as “explain that further” can reuse the preceding exchange's topic.
        for previous in history.suffix(2).reversed() {
            for term in terms(in: previous.content).prefix(8) where result.count < 24 && !result.contains(term) {
                result.append(term)
            }
        }
        return result
    }
}
