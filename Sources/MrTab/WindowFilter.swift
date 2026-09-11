import Foundation

/// Matches the list against what the user has typed into the switcher.
///
/// Tokens match independently and in any order against the app name and the window title taken
/// together, so "sl gen" finds Slack's #general and "code mrtab" finds one editor window out of
/// six. Comparison folds case, diacritics and width, because the point of typing is to get to a
/// window in three keystrokes -- stopping to reproduce the accent in "Sessão" defeats it.
enum WindowFilter {
    static func apply(_ query: String, to entries: [WindowEntry]) -> [WindowEntry] {
        let tokens = tokens(in: query)
        guard !tokens.isEmpty else { return entries }
        return entries.filter { matches(tokens: tokens, appName: $0.appName, title: $0.title) }
    }

    static func matches(tokens: [String], appName: String, title: String) -> Bool {
        let haystack = normalized(appName + " " + title)
        return tokens.allSatisfy(haystack.contains)
    }

    static func tokens(in query: String) -> [String] {
        normalized(query).split(separator: " ").map(String.init)
    }

    private static func normalized(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                       locale: nil)
    }
}
