import Foundation

/// Whether a two-character Chinese vocabulary term is a person's name (F921), as far as text can
/// tell: a common surname followed by one character that the caller's segmenter does not read as
/// one word with it.
///
/// Correct Toward Vocabulary proposes a Chinese window that differs from a term in one character
/// that sounds the same (F817). For a name that is as likely another person as a mishearing — the
/// Wave 5 review measured 张薇 → 张伟, 刘阳 → 刘洋, 王方 → 王芳, 黎明 → 李明 and 留洋 → 刘洋 among 15
/// wrong rows in 40 everyday sentences — and renaming a person in a transcript is worse than a
/// missed row (F244, F245). The text cannot tell the two apart, so no row is made for a name.
///
/// A name is told from a word by the segmenter the app passes (`CJKWordEvidence.segmenter`,
/// NLTokenizer): it reads a two-character name as surname | given name (张 | 伟, 刘 | 洋, 王 | 芳,
/// 李 | 明) and a word that begins with a surname character whole (周五, 王国, 李子, 马上, 高兴).
/// Measured before this was written (`.claude/wave7/gates/F921-probe-terms.log`). A three-character
/// name does not separate so — NLTokenizer reads 伟明 in 张伟明 as one word, as it reads 经理 in
/// 张经理 — so this is for two characters only. With no segmenter nothing can tell, and no term is
/// a name.
enum ChinesePersonName {
    /// The hundred or so most common surnames, each one character.
    static let surnames: Set<Character> = Set(
        "王李张刘陈杨黄赵吴周徐孙马朱胡郭何高林罗郑梁谢宋唐许韩冯邓曹彭曾萧田董袁潘于蒋蔡余杜叶程苏魏吕丁任沈姚卢姜崔钟谭陆汪范金石廖贾夏韦付方白邹孟熊秦邱江尹薛闫段雷侯龙史陶黎贺顾毛郝龚邵万钱严覃武戴莫孔向汤"
    )

    /// True when `term` is two Han characters, the first a common surname, and `segmenter` reads
    /// them as two words rather than one.
    static func isLikely(_ term: String, segmenter: CJKWordEvidence.Segmenter?) -> Bool {
        guard let segmenter, term.count == 2, let first = term.first, surnames.contains(first),
              ReplacementBoundary.hasCJK(term), term.allSatisfy({ ReplacementBoundary.hasCJK(String($0)) }) else { return false }
        let words = segmenter(term)
        return !words.contains { $0 == term.startIndex..<term.endIndex }
    }
}
