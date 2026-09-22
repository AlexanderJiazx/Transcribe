import Foundation

/// Minimal pure-Swift byte-level BPE tokenizer compatible with Qwen2/Qwen3
/// (`vocab.json` + `merges.txt` + special tokens from `tokenizer_config.json`).
final class BPETokenizer {
    private var encoder: [String: Int] = [:]        // token piece -> id
    private var decoder: [Int: String] = [:]        // id -> token piece
    private var bpeRanks: [String: Int] = [:]        // "a b" -> rank
    private var specialContentToId: [String: Int] = [:]   // added-token content -> id
    private var addedIds: Set<Int> = []                   // all added tokens (atomic)
    private var skippableIds: Set<Int> = []               // added tokens with special=true

    private var byteEncoder: [UInt8: Character] = [:]
    private var byteDecoder: [Character: UInt8] = [:]

    private let pattern = "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?\\p{L}+|\\p{N}| ?[^\\s\\p{L}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+"
    private let regex: NSRegularExpression

    init(modelDir: URL) throws {
        regex = try NSRegularExpression(pattern: pattern)
        buildByteMaps()

        // vocab.json
        let vocabData = try Data(contentsOf: modelDir.appendingPathComponent("vocab.json"))
        let vocab = try JSONSerialization.jsonObject(with: vocabData) as! [String: Int]
        encoder = vocab
        for (k, v) in vocab { decoder[v] = k }

        // merges.txt
        let mergesText = try String(contentsOf: modelDir.appendingPathComponent("merges.txt"), encoding: .utf8)
        var rank = 0
        for line in mergesText.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") { continue }
            let parts = line.split(separator: " ")
            if parts.count == 2 {
                bpeRanks["\(parts[0]) \(parts[1])"] = rank
            }
            rank += 1   // rank is line position — a skipped malformed line must not shift it
        }

        // special tokens from tokenizer_config.json
        let cfgData = try Data(contentsOf: modelDir.appendingPathComponent("tokenizer_config.json"))
        let cfg = try JSONSerialization.jsonObject(with: cfgData) as! [String: Any]
        if let atd = cfg["added_tokens_decoder"] as? [String: Any] {
            for (idStr, info) in atd {
                guard let id = Int(idStr), let dict = info as? [String: Any],
                      let content = dict["content"] as? String else { continue }
                specialContentToId[content] = id
                addedIds.insert(id)
                if (dict["special"] as? Bool) == true { skippableIds.insert(id) }
                decoder[id] = content
            }
        }
    }

    private func buildByteMaps() {
        var bs: [Int] = []
        bs.append(contentsOf: Int(Character("!").asciiValue!)...Int(Character("~").asciiValue!))
        bs.append(contentsOf: 0xA1...0xAC)
        bs.append(contentsOf: 0xAE...0xFF)
        var cs = bs
        var n = 0
        for b in 0..<256 {
            if !bs.contains(b) {
                bs.append(b)
                cs.append(256 + n)
                n += 1
            }
        }
        for (b, c) in zip(bs, cs) {
            let ch = Character(UnicodeScalar(c)!)
            byteEncoder[UInt8(b)] = ch
            byteDecoder[ch] = UInt8(b)
        }
    }

    // MARK: - BPE

    private func bpe(_ token: String) -> [String] {
        var word = token.map { String($0) }
        if word.count < 2 { return word }

        func pairs(_ w: [String]) -> [(String, String)] {
            var p: [(String, String)] = []
            for i in 0..<(w.count - 1) { p.append((w[i], w[i + 1])) }
            return p
        }

        while true {
            let ps = pairs(word)
            if ps.isEmpty { break }
            // find pair with the lowest merge rank
            var best: (String, String)? = nil
            var bestRank = Int.max
            for p in ps {
                if let r = bpeRanks["\(p.0) \(p.1)"], r < bestRank {
                    bestRank = r
                    best = p
                }
            }
            guard let (first, second) = best else { break }

            var newWord: [String] = []
            var i = 0
            while i < word.count {
                if i < word.count - 1 && word[i] == first && word[i + 1] == second {
                    newWord.append(first + second)
                    i += 2
                } else {
                    newWord.append(word[i])
                    i += 1
                }
            }
            word = newWord
            if word.count == 1 { break }
        }
        return word
    }

    /// Encode a plain (non-special) text segment into token ids.
    private func encodeOrdinary(_ text: String) -> [Int] {
        var ids: [Int] = []
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let piece = ns.substring(with: m.range)
            // map UTF-8 bytes -> unicode pieces
            var mapped = ""
            for byte in Array(piece.utf8) {
                mapped.append(byteEncoder[byte]!)
            }
            for tok in bpe(mapped) {
                if let id = encoder[tok] {
                    ids.append(id)
                }
            }
        }
        return ids
    }

    /// Encode text, treating any known special-token strings as atomic ids.
    func encode(_ text: String) -> [Int] {
        // Split on special tokens (longest first to avoid prefix collisions).
        let specials = specialContentToId.keys.sorted { $0.count > $1.count }
        var segments: [(String, Bool)] = [(text, false)]  // (text, isSpecial)
        for sp in specials {
            var next: [(String, Bool)] = []
            for (seg, isSpecial) in segments {
                if isSpecial { next.append((seg, true)); continue }
                var rest = seg
                while let range = rest.range(of: sp) {
                    let before = String(rest[rest.startIndex..<range.lowerBound])
                    if !before.isEmpty { next.append((before, false)) }
                    next.append((sp, true))
                    rest = String(rest[range.upperBound...])
                }
                if !rest.isEmpty { next.append((rest, false)) }
            }
            segments = next
        }

        var ids: [Int] = []
        for (seg, isSpecial) in segments {
            if isSpecial {
                ids.append(specialContentToId[seg]!)
            } else {
                ids.append(contentsOf: encodeOrdinary(seg))
            }
        }
        return ids
    }

    /// Decode token ids back to text.
    func decode(_ ids: [Int], skipSpecial: Bool = true) -> String {
        var bytes: [UInt8] = []
        var out = ""
        for id in ids {
            if addedIds.contains(id) {
                if skipSpecial && skippableIds.contains(id) { continue }
                // flush byte buffer then append the token content as-is
                if !bytes.isEmpty {
                    out += String(decoding: bytes, as: UTF8.self)
                    bytes.removeAll()
                }
                out += decoder[id] ?? ""
                continue
            }
            guard let piece = decoder[id] else { continue }
            for ch in piece {
                if let b = byteDecoder[ch] { bytes.append(b) }
            }
        }
        if !bytes.isEmpty {
            out += String(decoding: bytes, as: UTF8.self)
        }
        return out
    }

    func specialId(_ content: String) -> Int { specialContentToId[content]! }
}
