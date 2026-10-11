// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// The BIP-39 English list (2,048 words), used for recovery phrases and check phrases.
public enum Wordlist {
    public static let english: [String] = {
        guard let url = Bundle.module.url(forResource: "wordlist-en", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { fatalError("wordlist-en.txt missing from KhensuKit resources") }
        let words = text.split(whereSeparator: \.isNewline).map(String.init)
        precondition(words.count == 2048)
        return words
    }()

    static let index: [String: Int] = Dictionary(uniqueKeysWithValues: english.enumerated().map { ($1, $0) })
}
