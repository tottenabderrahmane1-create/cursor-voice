import Foundation

/// Lightweight web access for the realtime model. No API keys —
/// `web_search` scrapes the DuckDuckGo HTML endpoint; `fetch_url`
/// downloads a page and returns stripped text.
enum WebSearch {
    struct Result {
        let title: String
        let url: String
        let snippet: String
    }

    static func search(_ query: String, maxResults: Int = 6) async -> [String: Any] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else {
            return ["error": "invalid query"]
        }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("Mozilla/5.0 (Macintosh; CursorVoice/0.1)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let html = String(data: data, encoding: .utf8) ?? ""
            let results = parse(html: html).prefix(maxResults)
            return [
                "query": trimmed,
                "results": results.map {
                    ["title": $0.title, "url": $0.url, "snippet": $0.snippet]
                }
            ]
        } catch {
            return ["error": "search failed: \(error.localizedDescription)"]
        }
    }

    static func fetch(_ urlString: String, maxChars: Int = 4000) async -> [String: Any] {
        guard let url = URL(string: urlString), let scheme = url.scheme,
              scheme == "http" || scheme == "https" else {
            return ["error": "invalid url"]
        }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("Mozilla/5.0 (Macintosh; CursorVoice/0.1)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let html = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) ?? ""
            let text = stripHTML(html)
            let truncated = text.count > maxChars
                ? String(text.prefix(maxChars)) + "\n…(truncated)"
                : text
            return [
                "url": urlString,
                "status": status,
                "text": truncated
            ]
        } catch {
            return ["error": "fetch failed: \(error.localizedDescription)"]
        }
    }

    // MARK: - Parsing

    /// DuckDuckGo HTML results look like:
    ///   <a class="result__a" href="…">Title</a>
    ///   <a class="result__snippet">Snippet…</a>
    private static func parse(html: String) -> [Result] {
        var results: [Result] = []
        let pattern = #"<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#
        let snipPattern = #"<a[^>]*class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</a>"#

        let titleMatches = matches(in: html, pattern: pattern)
        let snipMatches  = matches(in: html, pattern: snipPattern)

        for (i, m) in titleMatches.enumerated() {
            guard m.count >= 3 else { continue }
            let rawHref = m[1]
            let url = unwrapDDGRedirect(rawHref)
            let title = stripHTML(m[2])
            let snippet = i < snipMatches.count && snipMatches[i].count >= 2
                ? stripHTML(snipMatches[i][1])
                : ""
            results.append(Result(title: title, url: url, snippet: snippet))
        }
        return results
    }

    /// DDG wraps result links as /l/?uddg=<encoded-url>&… — unwrap to the real URL.
    private static func unwrapDDGRedirect(_ raw: String) -> String {
        guard raw.contains("uddg="),
              let comps = URLComponents(string: raw.hasPrefix("//") ? "https:\(raw)" : raw),
              let item = comps.queryItems?.first(where: { $0.name == "uddg" }),
              let value = item.value else {
            return raw
        }
        return value
    }

    private static func matches(in s: String, pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.dotMatchesLineSeparators, .caseInsensitive])
        else { return [] }
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.matches(in: s, options: [], range: range).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    /// Quick-and-dirty HTML → text: drop script/style blocks, drop tags,
    /// decode a handful of common entities, collapse whitespace.
    static func stripHTML(_ html: String) -> String {
        var s = html
        // Drop script/style blocks
        for pat in [#"<script[^>]*>.*?</script>"#, #"<style[^>]*>.*?</style>"#,
                    #"<noscript[^>]*>.*?</noscript>"#] {
            if let re = try? NSRegularExpression(pattern: pat,
                                                 options: [.dotMatchesLineSeparators, .caseInsensitive]) {
                s = re.stringByReplacingMatches(
                    in: s, options: [],
                    range: NSRange(location: 0, length: (s as NSString).length),
                    withTemplate: " ")
            }
        }
        // Strip all remaining tags
        if let re = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            s = re.stringByReplacingMatches(in: s, options: [],
                                            range: NSRange(location: 0, length: (s as NSString).length),
                                            withTemplate: " ")
        }
        // Decode a handful of entities
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&hellip;", "…"),
            ("&#8217;", "'"), ("&#8220;", "\""), ("&#8221;", "\""), ("&mdash;", "—")
        ]
        for (e, r) in entities { s = s.replacingOccurrences(of: e, with: r) }
        // Collapse whitespace
        if let re = try? NSRegularExpression(pattern: #"\s+"#, options: []) {
            s = re.stringByReplacingMatches(in: s, options: [],
                                            range: NSRange(location: 0, length: (s as NSString).length),
                                            withTemplate: " ")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
