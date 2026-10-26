//
//  Telex.swift
//  SuperMinimalTools
//

import Foundation

/// Turns the keys typed for one word into Vietnamese using Telex: `aa` â,
/// `aw` ă, `ee` ê, `oo` ô, `ow` ơ, `uw` (or a bare `w`) ư, `uow` ươ, `dd` đ,
/// and the tone keys `s` sắc, `f` huyền, `r` hỏi, `x` ngã, `j` nặng, `z` none.
/// Pressing a mark key again types it literally (`ass` → `as`).
///
/// The word is recomposed from all of its keys on every keystroke, so the
/// result depends only on what was typed. Marks are added only while the word
/// can still become a Vietnamese syllable; once it can't (`string`, `what`),
/// the word is shown exactly as typed, except that repeating the last letter
/// stretches the word instead (`điii`, `đẹppp`). Tones follow the modern
/// placement (`hoà`, `thuý`).
nonisolated enum Telex {

    static func compose(_ keys: [Character]) -> String {
        var word = Word()
        var typesLiterally = false
        for key in keys {
            if typesLiterally {
                word.append(key)
                continue
            }
            switch word.applying(key) {
            case .undone(let undone):
                word = undone
                typesLiterally = true
                continue
            case .changed(var changed):
                changed.completeHornedUO()
                if changed.isPossibleSyllable {
                    word = changed
                    continue
                }
            case .literal:
                break
            }
            var appended = word
            appended.append(key)
            appended.completeHornedUO()
            if appended.isPossibleSyllable {
                word = appended
            } else if word.letters.last?.base == Character(key.lowercased()) {
                // A repeated letter stretches the word: `điii`, `đẹppp`, `khônggg`.
                word.pinTone()
                word.append(key)
                typesLiterally = true
            } else {
                return typedAsIs(keys)
            }
        }
        return word.text
    }

    /// The keys as typed, except that a leading `dd` stays đ: no English word
    /// starts with it, and abbreviations like `đc` (được) or `đt` need it.
    private static func typedAsIs(_ keys: [Character]) -> String {
        guard keys.count >= 2, keys[0].lowercased() == "d", keys[1].lowercased() == "d" else { return String(keys) }
        return (keys[0] == "D" ? "Đ" : "đ") + String(keys.dropFirst(2))
    }

    /// Keys that compose back into `text`, used to keep editing a word after
    /// a backspace. Callers check `compose(keys(for:)) == text`, since text
    /// typed literally has no such keys.
    static func keys(for text: String) -> [Character] {
        var keys: [Character] = []
        var needsW = false
        var toneKey: Character?
        for character in text {
            if character == "đ" || character == "Đ" {
                keys += [character == "Đ" ? "D" : "d", "d"]
                continue
            }
            let scalars = String(character).decomposedStringWithCanonicalMapping.unicodeScalars
            guard let base = scalars.first else { continue }
            keys.append(Character(base))
            for scalar in scalars.dropFirst() {
                if scalar == Mark.circumflex.combining {
                    keys.append(Character(base.properties.lowercaseMapping))
                } else if scalar == Mark.breve.combining || scalar == Mark.horn.combining {
                    needsW = true
                } else if let tone = Tone.allCases.first(where: { $0.combining == scalar }) {
                    toneKey = tone.key
                }
            }
        }
        if needsW { keys.append("w") }
        if let toneKey { keys.append(toneKey) }
        return keys
    }

    // MARK: - Model

    private enum Mark {
        case none, circumflex, breve, horn, stroke

        var combining: Unicode.Scalar? {
            switch self {
            case .none, .stroke: nil
            case .circumflex: "\u{0302}"
            case .breve: "\u{0306}"
            case .horn: "\u{031B}"
            }
        }
    }

    private enum Tone: CaseIterable {
        case none, acute, grave, hook, tilde, dot

        init?(key: Character) {
            guard let tone = Self.allCases.first(where: { $0.key == key }) else { return nil }
            self = tone
        }

        var key: Character? {
            switch self {
            case .none: nil
            case .acute: "s"
            case .grave: "f"
            case .hook: "r"
            case .tilde: "x"
            case .dot: "j"
            }
        }

        var combining: Unicode.Scalar? {
            switch self {
            case .none: nil
            case .acute: "\u{0301}"
            case .grave: "\u{0300}"
            case .hook: "\u{0309}"
            case .tilde: "\u{0303}"
            case .dot: "\u{0323}"
            }
        }
    }

    private struct Letter {
        /// Lowercase a–z.
        var base: Character
        var mark: Mark = .none
        var isUppercase: Bool
        /// A ư typed with a bare `w`: pressing `w` again turns it back into `w`.
        var isBareW = false

        init(base: Character, mark: Mark = .none, isUppercase: Bool, isBareW: Bool = false) {
            self.base = base
            self.mark = mark
            self.isUppercase = isUppercase
            self.isBareW = isBareW
        }

        init(key: Character) {
            self.init(base: Character(key.lowercased()), isUppercase: key.isUppercase)
        }

        var isVowel: Bool { "aeiouy".contains(base) }

        /// The letter without case or tone, e.g. "ư" or "đ".
        var plain: Character { rendered(tone: .none, uppercase: false) }

        func rendered(tone: Tone, uppercase: Bool? = nil) -> Character {
            var scalars = String(mark == .stroke ? "đ" : base).unicodeScalars
            if let combining = mark.combining { scalars.append(combining) }
            if let combining = tone.combining { scalars.append(combining) }
            var text = String(scalars).precomposedStringWithCanonicalMapping
            if uppercase ?? isUppercase { text = text.uppercased() }
            return Character(text)
        }
    }

    /// The shape a vowel must have in a valid nucleus.
    private struct VowelShape {
        var base: Character
        var mark: Mark

        init(_ vowel: Character) {
            switch vowel {
            case "ă": (base, mark) = ("a", .breve)
            case "â": (base, mark) = ("a", .circumflex)
            case "ê": (base, mark) = ("e", .circumflex)
            case "ô": (base, mark) = ("o", .circumflex)
            case "ơ": (base, mark) = ("o", .horn)
            case "ư": (base, mark) = ("u", .horn)
            default: (base, mark) = (vowel, .none)
            }
        }

        /// A letter matches when it is the same vowel, or the same vowel still
        /// waiting for its mark (the `e` in `tie` before `tiee`).
        func matches(_ letter: Letter) -> Bool {
            letter.base == base && (letter.mark == mark || letter.mark == .none)
        }
    }

    private struct Nucleus {
        var shapes: [VowelShape]
        var takesFinal: Bool
    }

    private static let initials: Set<String> = [
        "", "b", "c", "ch", "d", "đ", "g", "gh", "gi", "h", "k", "kh", "l", "m", "n", "ng", "ngh",
        "nh", "p", "ph", "qu", "r", "s", "t", "th", "tr", "v", "x",
        // Loanwords (Zalo, fan, jeans).
        "f", "j", "z",
    ]

    private static let finals: Set<String> = ["c", "ch", "m", "n", "ng", "nh", "p", "t"]

    /// Finals after which only sắc and nặng are possible (`các`, `cạc`).
    private static let stopFinals: Set<String> = ["c", "ch", "p", "t"]

    private static let nuclei: [Nucleus] = {
        let withFinal = [
            "a", "ă", "â", "e", "ê", "i", "o", "ô", "ơ", "u", "ư", "oa", "oă", "oe", "oo", "uâ", "uê",
            "uô", "uy", "ươ", "iê", "yê", "uyê",
        ]
        let withoutFinal = [
            "y", "ai", "ao", "au", "ay", "âu", "ây", "eo", "êu", "ia", "iu", "oi", "ôi", "ơi", "ua",
            "ui", "ưa", "ưi", "ưu", "uơ", "oai", "oay", "oeo", "uây", "uôi", "uya", "uyu", "ươi",
            "ươu", "iêu", "yêu",
        ]
        return withFinal.map { Nucleus(shapes: $0.map(VowelShape.init), takesFinal: true) }
            + withoutFinal.map { Nucleus(shapes: $0.map(VowelShape.init), takesFinal: false) }
    }()

    private struct Word {
        var letters: [Letter] = []
        var tone: Tone = .none
        /// Where the tone stays once the word is typed literally (`đìii`, not `điìi`).
        var pinnedToneIndex: Int?

        enum Step {
            case changed(Word)
            /// A mark key pressed twice: the mark is removed and the key typed.
            case undone(Word)
            case literal
        }

        mutating func append(_ key: Character) {
            letters.append(Letter(key: key))
        }

        mutating func pinTone() {
            pinnedToneIndex = toneIndex(parts: parts)
        }

        /// ưo or uơ with more letters after it is ươ (`dduwong` → `đương`).
        mutating func completeHornedUO() {
            guard let nucleus = parts?.nucleus,
                  let u = nucleus.first(where: { letters[$0].base == "u" }),
                  nucleus.contains(u + 1), letters[u + 1].base == "o", u + 2 < letters.count else { return }
            let marks = (letters[u].mark, letters[u + 1].mark)
            if marks == (.horn, .none) || marks == (.none, .horn) {
                letters[u].mark = .horn
                letters[u + 1].mark = .horn
            }
        }

        func applying(_ key: Character) -> Step {
            let lower = Character(key.lowercased())
            let nucleus = parts?.nucleus ?? letters.indices.filter { letters[$0].isVowel }
            var word = self

            if let tone = Tone(key: lower), !nucleus.isEmpty {
                guard self.tone != tone else {
                    word.tone = .none
                    word.append(key)
                    return .undone(word)
                }
                word.tone = tone
                return .changed(word)
            }

            switch lower {
            case "z" where tone != .none:
                word.tone = .none
                return .changed(word)

            case "a", "e", "o":
                guard let index = nucleus.last(where: { letters[$0].base == lower }) else { return .literal }
                if letters[index].mark == .circumflex {
                    word.letters[index].mark = .none
                    word.pinTone()
                    word.append(key)
                    // `quấ` + a is `quáaa`: the a's stretch the word.
                    if index == letters.count - 1, tone != .none { word.append(key) }
                    return .undone(word)
                }
                word.letters[index].mark = .circumflex
                return .changed(word)

            // The d can come anywhere in the word: `did` → `đi`, `dieend` → `điên`.
            case "d" where letters.first?.base == "d":
                if letters[0].mark == .stroke {
                    word.letters[0].mark = .none
                    word.pinTone()
                    word.append(key)
                    return .undone(word)
                }
                word.letters[0].mark = .stroke
                return .changed(word)

            case "w":
                return applyingW(key, nucleus: nucleus)

            default:
                return .literal
            }
        }

        private func applyingW(_ key: Character, nucleus: [Int]) -> Step {
            var word = self
            guard !nucleus.isEmpty else {
                // f, j and z only start loanwords, which never go on with ư.
                if letters.contains(where: { "fjz".contains($0.base) }) { return .literal }
                word.letters.append(Letter(base: "u", mark: .horn, isUppercase: key.isUppercase, isBareW: true))
                return .changed(word)
            }

            // uo → ươ, both at once.
            if let u = nucleus.first(where: { letters[$0].base == "u" }),
               nucleus.contains(u + 1), letters[u + 1].base == "o",
               letters[u].mark != .horn || letters[u + 1].mark != .horn {
                word.letters[u].mark = .horn
                word.letters[u + 1].mark = .horn
                return .changed(word)
            }

            let hooked = nucleus.filter { [.horn, .breve].contains(letters[$0].mark) }
            if !hooked.isEmpty {
                word.pinTone()
                var typedW = false
                for index in hooked {
                    if letters[index].isBareW {
                        word.letters[index] = Letter(base: "w", isUppercase: letters[index].isUppercase)
                        typedW = true
                    } else {
                        word.letters[index].mark = .none
                    }
                }
                if !typedW { word.append(key) }
                return .undone(word)
            }

            // Try ă, ơ, ư from the last vowel back, keeping the first that can
            // still be a syllable (`mua` + w is `mưa`, not `muă`).
            for index in nucleus.reversed() where "aou".contains(letters[index].base) {
                var candidate = self
                candidate.letters[index].mark = letters[index].base == "a" ? .breve : .horn
                if candidate.isPossibleSyllable {
                    return .changed(candidate)
                }
            }
            return .literal
        }

        /// Index ranges of the initial consonant, the vowels and the final
        /// consonant; nil when a vowel follows the final consonant.
        var parts: (initial: Range<Int>, nucleus: [Int], final: Range<Int>)? {
            var start = letters.firstIndex(where: \.isVowel) ?? letters.count
            if start < letters.count {
                let initial = String(letters[..<start].map(\.plain))
                // The u of qu, and the i of gi before another vowel, belong to the initial.
                if initial == "q", letters[start].base == "u", letters[start].mark == .none {
                    start += 1
                } else if initial == "g", letters[start].base == "i", letters[start].mark == .none,
                          start + 1 < letters.count, letters[start + 1].isVowel {
                    start += 1
                }
            }
            var end = start
            while end < letters.count, letters[end].isVowel { end += 1 }
            guard !letters[end...].contains(where: \.isVowel) else { return nil }
            return (0..<start, Array(start..<end), end..<letters.count)
        }

        /// Whether this is, or can still grow into, a Vietnamese syllable.
        var isPossibleSyllable: Bool {
            guard let parts else { return false }
            let initial = String(letters[parts.initial].map(\.plain))
            let final = String(letters[parts.final].map(\.plain))
            let vowels = parts.nucleus.map { letters[$0] }

            guard let first = vowels.first else {
                return Telex.initials.contains { $0.hasPrefix(initial) }
            }
            guard Telex.initials.contains(initial) else { return false }
            switch initial {
            case "k", "gh", "ngh": guard "eiy".contains(first.base) else { return false }
            case "c", "ng": guard !"eiy".contains(first.base) else { return false }
            case "g": guard first.base != "e" else { return false }
            default: break
            }

            if !final.isEmpty {
                guard Telex.finals.contains(final) else { return false }
                if Telex.stopFinals.contains(final), ![.none, .acute, .dot].contains(tone) { return false }
            }
            return Telex.nuclei.contains { nucleus in
                if final.isEmpty {
                    guard vowels.count <= nucleus.shapes.count else { return false }
                } else {
                    guard nucleus.takesFinal, vowels.count == nucleus.shapes.count else { return false }
                }
                return zip(nucleus.shapes, vowels).allSatisfy { $0.matches($1) }
            }
        }

        var text: String {
            var letters = letters
            let parts = parts
            // ươ with nothing after it is written uơ (`thuở`); `nguow` still
            // becomes `người` once the i is typed.
            if let parts, parts.final.isEmpty, parts.nucleus.count == 2,
               parts.nucleus.allSatisfy({ letters[$0].mark == .horn }),
               letters[parts.nucleus[0]].base == "u", letters[parts.nucleus[1]].base == "o" {
                letters[parts.nucleus[0]].mark = .none
            }
            let toneIndex = tone == .none ? nil : pinnedToneIndex ?? self.toneIndex(parts: parts)
            return String(letters.indices.map { letters[$0].rendered(tone: $0 == toneIndex ? tone : .none) })
        }

        private func toneIndex(parts: (initial: Range<Int>, nucleus: [Int], final: Range<Int>)?) -> Int? {
            let nucleus = parts?.nucleus ?? letters.indices.filter { letters[$0].isVowel }
            if let marked = nucleus.last(where: { [.circumflex, .breve, .horn].contains(letters[$0].mark) }) {
                return marked
            }
            switch nucleus.count {
            case 0:
                return nil
            case 1:
                return nucleus[0]
            case 2:
                let pair = String(nucleus.map { letters[$0].base })
                let hasFinal = !(parts?.final.isEmpty ?? true)
                return hasFinal || ["oa", "oe", "uy"].contains(pair) ? nucleus[1] : nucleus[0]
            default:
                return nucleus[1]
            }
        }
    }
}

/// Follows the word being typed and works out how to update the screen after
/// each key.
nonisolated struct TelexSession {

    /// Delete `backspaces` characters before the cursor, then type `text`.
    struct Edit: Equatable {
        var backspaces: Int
        var text: String
    }

    /// Longer "words" (URLs, hashes) are left alone.
    static let maxKeys = 32

    private struct TypedWord {
        var keys: [Character] = []
        var text = ""
    }

    /// The current word as it appears on screen.
    var text: String { word.text }

    private var word = TypedWord()
    private var isTracking = true
    /// The word before the spaces just typed: backspacing over the spaces goes
    /// back to editing it (`viet␣` ⌫ `j` → `việt`).
    private var previous: TypedWord?
    private var spacesAfterPrevious = 0

    /// Returns the edit for a typed character, or nil to let the key through
    /// as is. Anything but a letter ends the word.
    mutating func type(_ key: Character) -> Edit? {
        if key == " " {
            if isTracking, !word.text.isEmpty {
                previous = word
                spacesAfterPrevious = 1
            } else if previous != nil, word.text.isEmpty {
                spacesAfterPrevious += 1
            } else {
                previous = nil
            }
            word = TypedWord()
            isTracking = true
            return nil
        }
        guard key.isASCII, key.isLetter else {
            reset()
            return nil
        }
        guard isTracking, word.keys.count < Self.maxKeys else {
            isTracking = false
            return nil
        }
        word.keys.append(key)
        let composed = Telex.compose(word.keys)
        let edit = Self.edit(from: word.text, to: composed)
        word.text = composed
        return edit
    }

    /// Call for a backspace. Returns nil when the backspace can go through,
    /// or the edit to make instead. The rest of the word can still get marks
    /// (`tiếng` ⌫ `tiến` + `j` → `tiện`).
    mutating func deleteBackward() -> Edit? {
        guard isTracking else {
            reset()
            return nil
        }
        guard !word.text.isEmpty else {
            guard let previous, spacesAfterPrevious > 0 else {
                reset()
                return nil
            }
            spacesAfterPrevious -= 1
            if spacesAfterPrevious == 0 {
                word = previous
                self.previous = nil
            }
            return nil
        }
        let remaining = String(word.text.dropLast())
        let keys = Telex.keys(for: remaining)
        if Telex.compose(keys) == remaining {
            word = TypedWord(keys: keys, text: remaining)
            return nil
        }
        // A word shown as typed (`vieetjn`): drop its last key and compose
        // again (`việt`).
        word.keys.removeLast()
        let composed = Telex.compose(word.keys)
        let edit = Self.edit(from: word.text, to: composed)
        word.text = composed
        return edit == Edit(backspaces: 1, text: "") ? nil : edit
    }

    mutating func reset() {
        word = TypedWord()
        isTracking = true
        previous = nil
        spacesAfterPrevious = 0
    }

    static func edit(from old: String, to new: String) -> Edit {
        let common = zip(old, new).prefix { $0 == $1 }.count
        return Edit(backspaces: old.count - common, text: String(new.dropFirst(common)))
    }
}
