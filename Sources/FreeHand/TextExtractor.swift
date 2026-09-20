import Foundation

enum TextExtractor {
    /// Seed literal candidates for Laya; this does not generate new text.
    static func extract(from goal: String) -> String? {
        let patterns = [#"^(?:type|enter)\s+"([^"]*)"\s*$"#,
                        #"^search for\s+"([^"]+)"\s*$"#,
                        #"^search for\s+([^"\n]+)$"#,
                        #"^(?:请)?(?:输入|键入|填写|搜索|查找)[：:\s]*["“「]([^"”」]+)["”」][。.]?$"#,
                        #"^(?:请)?(?:搜索|查找)\s*([^"“”「」\n]+)$"#,
                        #"^(?:type|enter|search for)\s+[“「]([^”」]+)[”」]\s*$"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: goal, range: NSRange(goal.startIndex..., in: goal)),
                  let range = Range(match.range(at: 1), in: goal) else { continue }
            let value = String(goal[range])
            if value.range(of: #"\b(and|then|into)\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return nil }
            return value
        }
        return nil
    }
}
