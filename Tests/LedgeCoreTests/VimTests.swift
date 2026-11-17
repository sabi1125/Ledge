import Foundation
import LedgeCore
import XCTest

final class VimTests: XCTestCase {
    /// Types `keys` into `start` and returns the text afterwards. In both, "|" is the cursor and
    /// «…» a selection. Special keys go in angle brackets: "<Esc>", "<CR>", "<C-r>".
    /// Undo is played back from the edits; insert mode types the keys as text.
    private func type(_ start: String, _ keys: String, vim: inout Vim) -> String {
        var text = start.replacingOccurrences(of: "|", with: "") as NSString
        var selection = NSRange(location: (start as NSString).range(of: "|").location, length: 0)
        var history: [(String, NSRange)] = []
        var future: [(String, NSRange)] = []
        for key in Self.keys(keys) {
            switch vim.handle(key, text: text as String, selection: selection) {
            case .pass:
                history.append((text as String, selection))
                let typed = key == "<CR>" ? "\n" : key
                text = text.replacingCharacters(in: selection, with: typed) as NSString
                selection = NSRange(location: selection.location + (typed as NSString).length, length: 0)
            case .wait:
                break
            case .apply(let edit, let range):
                if let edit {
                    history.append((text as String, selection))
                    future = []
                    text = text.replacingCharacters(in: edit.range, with: edit.text) as NSString
                }
                selection = range
            case .undo:
                guard let (old, oldSelection) = history.popLast() else { break }
                future.append((text as String, selection))
                text = old as NSString
                selection = NSRange(location: oldSelection.location, length: 0)
            case .redo:
                guard let (new, newSelection) = future.popLast() else { break }
                history.append((text as String, selection))
                text = new as NSString
                selection = NSRange(location: newSelection.location, length: 0)
            }
        }
        let shown = NSMutableString(string: text)
        if selection.length > 0 {
            shown.insert("»", at: selection.upperBound)
            shown.insert("«", at: selection.location)
        } else {
            shown.insert("|", at: selection.location)
        }
        return shown as String
    }

    private func type(_ start: String, _ keys: String) -> String {
        var vim = Vim()
        return type(start, keys, vim: &vim)
    }

    private static func keys(_ text: String) -> [String] {
        var keys: [String] = []
        var rest = Substring(text)
        while let first = rest.first {
            if first == "<", let close = rest.firstIndex(of: ">"), rest.distance(from: rest.startIndex, to: close) > 1 {
                keys.append(String(rest[...close]))
                rest = rest[rest.index(after: close)...]
            } else {
                keys.append(String(first))
                rest = rest.dropFirst()
            }
        }
        return keys
    }

    // MARK: Motions

    func testLeftRightStayOnTheLine() {
        XCTAssertEqual(type("a|bc\ndef", "l"), "ab|c\ndef")
        XCTAssertEqual(type("a|bc\ndef", "5l"), "ab|c\ndef")
        XCTAssertEqual(type("abc\nd|ef", "5h"), "abc\n|def")
    }

    func testUpDownKeepTheColumn() {
        XCTAssertEqual(type("abc|d\nx\nabcdef", "j"), "abcd\n|x\nabcdef")
        XCTAssertEqual(type("abc|d\nx\nabcdef", "jj"), "abcd\nx\nabc|def")
        XCTAssertEqual(type("ab|c\nxy", "jk"), "ab|c\nxy")
        XCTAssertEqual(type("a|bc\nxyz\nlong line", "$jj"), "abc\nxyz\nlong lin|e")
    }

    func testWords() {
        XCTAssertEqual(type("|foo bar.baz", "w"), "foo |bar.baz")
        XCTAssertEqual(type("|foo bar.baz", "ww"), "foo bar|.baz")
        XCTAssertEqual(type("|foo bar.baz", "W"), "foo |bar.baz")
        XCTAssertEqual(type("|foo bar", "e"), "fo|o bar")
        XCTAssertEqual(type("|foo bar", "ee"), "foo ba|r")
        XCTAssertEqual(type("foo ba|r", "b"), "foo |bar")
        XCTAssertEqual(type("foo |bar", "b"), "|foo bar")
        XCTAssertEqual(type("|foo\n\nbar", "w"), "foo\n|\nbar")
        XCTAssertEqual(type("|foo\n\nbar", "ww"), "foo\n\n|bar")
    }

    func testJapaneseWordsSplitByScript() {
        XCTAssertEqual(type("|日本語のテキスト", "w"), "日本語|のテキスト")
        XCTAssertEqual(type("|日本語のテキスト", "ww"), "日本語の|テキスト")
        XCTAssertEqual(type("|日本語のテキスト", "e"), "日本|語のテキスト")
        XCTAssertEqual(type("日本語のテキス|ト", "b"), "日本語の|テキスト")
    }

    func testLineEndsAndFileEnds() {
        XCTAssertEqual(type("  ab|c", "0"), "|  abc")
        XCTAssertEqual(type("  ab|c", "^"), "  |abc")
        XCTAssertEqual(type("|abc", "$"), "ab|c")
        XCTAssertEqual(type("one\ntwo\n  thr|ee", "gg"), "|one\ntwo\n  three")
        XCTAssertEqual(type("|one\ntwo\n  three", "G"), "one\ntwo\n  |three")
        XCTAssertEqual(type("|one\ntwo\nthree", "2G"), "one\n|two\nthree")
    }

    func testFindOnTheLine() {
        XCTAssertEqual(type("|a,b,c", "f,"), "a|,b,c")
        XCTAssertEqual(type("|a,b,c", "2f,"), "a,b|,c")
        XCTAssertEqual(type("|a,b,c", "t,"), "|a,b,c")
        XCTAssertEqual(type("|a,b,c", "lt,"), "a,|b,c")
        XCTAssertEqual(type("a,b,|c", "F,"), "a,b|,c")
        XCTAssertEqual(type("a,b,|c", "T,"), "a,b,|c")
        XCTAssertEqual(type("|a,b\nx,y", "3f,"), "|a,b\nx,y")
    }

    // MARK: Changes

    func testDeleteWithMotions() {
        XCTAssertEqual(type("|foo bar baz", "dw"), "|bar baz")
        XCTAssertEqual(type("|foo bar baz", "d2w"), "|baz")
        XCTAssertEqual(type("|foo bar baz", "2dw"), "|baz")
        XCTAssertEqual(type("foo |bar\nbaz", "dw"), "foo| \nbaz")
        XCTAssertEqual(type("fo|o bar", "d$"), "f|o")
        XCTAssertEqual(type("fo|o bar", "D"), "f|o")
        XCTAssertEqual(type("foo b|ar", "d0"), "|ar")
        XCTAssertEqual(type("a|bc", "x"), "a|c")
        XCTAssertEqual(type("ab|c", "x"), "a|b")
        XCTAssertEqual(type("a|bcd", "2x"), "a|d")
        XCTAssertEqual(type("ab|c", "X"), "a|c")
    }

    func testDeleteLines() {
        XCTAssertEqual(type("one\nt|wo\nthree", "dd"), "one\n|three")
        XCTAssertEqual(type("one\ntwo\nth|ree", "dd"), "one\n|two")
        XCTAssertEqual(type("o|ne\ntwo\nthree", "2dd"), "|three")
        XCTAssertEqual(type("o|ne\ntwo\nthree", "dj"), "|three")
        XCTAssertEqual(type("one\ntwo\nth|ree", "dk"), "|one")
        XCTAssertEqual(type("o|nly", "dd"), "|")
    }

    func testChangeGoesToInsertMode() {
        XCTAssertEqual(type("|foo bar", "cwnew<Esc>"), "ne|w bar")
        XCTAssertEqual(type("fo|o bar", "ciwx<Esc>"), "|x bar")
        XCTAssertEqual(type("a \"qu|ote\" b", "ci\"z<Esc>"), "a \"|z\" b")
        XCTAssertEqual(type("f(a, |b)", "ca(x<Esc>"), "f|x")
        XCTAssertEqual(type("one\n  t|wo\nthree", "ccx<Esc>"), "one\n|x\nthree")
        XCTAssertEqual(type("fo|o bar", "Cz<Esc>"), "fo|z")
        XCTAssertEqual(type("|abc", "sx<Esc>"), "|xbc")
    }

    func testTextObjects() {
        XCTAssertEqual(type("one tw|o three", "diw"), "one | three")
        XCTAssertEqual(type("one tw|o three", "daw"), "one |three")
        XCTAssertEqual(type("say \"hi |there\" now", "di\""), "say \"|\" now")
        XCTAssertEqual(type("say \"hi |there\" now", "da\""), "say |now")
        XCTAssertEqual(type("f(a, (b|), c)", "di("), "f(a, (|), c)")
        XCTAssertEqual(type("f(a, (b), |c)", "di("), "f(|)")
        XCTAssertEqual(type("x = [1, |2]", "di]"), "x = [|]")
        XCTAssertEqual(type("{\n  a|b\n}", "di{"), "{|}")
    }

    func testInsertCommands() {
        XCTAssertEqual(type("a|bc", "iX<Esc>"), "a|Xbc")
        XCTAssertEqual(type("a|bc", "aX<Esc>"), "ab|Xc")
        XCTAssertEqual(type("  a|bc", "IX<Esc>"), "  |Xabc")
        XCTAssertEqual(type("a|bc", "AX<Esc>"), "abc|X")
        XCTAssertEqual(type("o|ne\ntwo", "oX<Esc>"), "one\n|X\ntwo")
        XCTAssertEqual(type("one\nt|wo", "OX<Esc>"), "one\n|X\ntwo")
        // O on a list line opens an item of it above, at the same indent.
        XCTAssertEqual(type("- [x] d|one", "OX<Esc>"), "- [ ] |X\n- [x] done")
        XCTAssertEqual(type("    - b|ullet", "OX<Esc>"), "    - |X\n    - bullet")
        XCTAssertEqual(type("a|bc", "i<Esc>"), "|abc")
    }

    func testYankAndPut() {
        XCTAssertEqual(type("o|ne\ntwo", "yyp"), "one\n|one\ntwo")
        XCTAssertEqual(type("one\nt|wo", "yyp"), "one\ntwo\n|two")
        XCTAssertEqual(type("one\nt|wo", "yyP"), "one\n|two\ntwo")
        XCTAssertEqual(type("o|ne\ntwo", "ddp"), "two\n|one")
        XCTAssertEqual(type("|ab", "xp"), "b|a")
        XCTAssertEqual(type("|foo bar", "yiwP"), "fo|ofoo bar")
        XCTAssertEqual(type("|foo bar", "yw$p"), "foo barfoo| ")
        XCTAssertEqual(type("|ab", "x3p"), "baa|a")
    }

    func testReplaceAndJoin() {
        XCTAssertEqual(type("a|bc", "rx"), "a|xc")
        XCTAssertEqual(type("a|bcd", "2rx"), "ax|xd")
        XCTAssertEqual(type("a|bc", "5rx"), "a|bc")
        XCTAssertEqual(type("o|ne\n   two\nthree", "J"), "one| two\nthree")
        XCTAssertEqual(type("o|ne\ntwo\nthree", "3J"), "one two| three")
    }

    func testUndoAndRedo() {
        XCTAssertEqual(type("|one two", "dwu"), "|one two")
        XCTAssertEqual(type("|one two", "dwu<C-r>"), "|two")
    }

    // MARK: Visual mode

    func testVisualSelectsAndDeletes() {
        XCTAssertEqual(type("a|bcd", "vl"), "a«bc»d")
        XCTAssertEqual(type("a|bcd", "vld"), "a|d")
        XCTAssertEqual(type("ab|cd", "vhho"), "«abc»d")
        XCTAssertEqual(type("one\nt|wo\nthree", "Vj"), "one\n«two\nthree»")
        XCTAssertEqual(type("one\nt|wo\nthree", "Vd"), "one\n|three")
        XCTAssertEqual(type("one t|wo", "viw"), "one «two»")
        XCTAssertEqual(type("a|bcd", "vl<Esc>"), "ab|cd")
    }

    func testVisualYankPutAndChange() {
        XCTAssertEqual(type("|abc", "vly$p"), "abca|b")
        XCTAssertEqual(type("|abc def", "vecX<Esc>"), "|X def")
        XCTAssertEqual(type("one\nt|wo", "Vyggp"), "one\n|two\ntwo")
    }

    // MARK: Modes

    func testInsertModePassesKeysThrough() {
        var vim = Vim()
        XCTAssertEqual(type("|", "i", vim: &vim), "|")
        XCTAssertEqual(vim.mode, .insert)
        XCTAssertEqual(vim.handle("x", text: "", selection: NSRange(location: 0, length: 0)), .pass)
        XCTAssertTrue(vim.wantsEscape)
    }

    func testEscapeIsFreeInNormalMode() {
        var vim = Vim()
        XCTAssertFalse(vim.wantsEscape)
        _ = vim.handle("d", text: "abc", selection: NSRange(location: 0, length: 0))
        XCTAssertTrue(vim.wantsEscape)
        _ = vim.handle("<Esc>", text: "abc", selection: NSRange(location: 0, length: 0))
        XCTAssertFalse(vim.wantsEscape)
    }

    func testUnknownKeysDoNothing() {
        XCTAssertEqual(type("a|bc", "z"), "a|bc")
        XCTAssertEqual(type("a|bc", "Q<Tab>"), "a|bc")
        XCTAssertEqual(type("a|bc", "dz"), "a|bc")
    }

    func testMouseSelectionCarriesOnInVisualMode() {
        var vim = Vim()
        let action = vim.handle("d", text: "abcd", selection: NSRange(location: 1, length: 2))
        XCTAssertEqual(action, .apply(edit: Vim.Edit(range: NSRange(location: 1, length: 2), text: ""),
                                      selection: NSRange(location: 1, length: 0)))
        XCTAssertEqual(vim.mode, .normal)
    }
}
