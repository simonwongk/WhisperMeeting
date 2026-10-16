import Foundation

/// Whether a two- or three-character Chinese vocabulary term is a person's name (F921, F995), as far
/// as text can tell: a common surname followed by a given name that the caller's segmenter does not
/// read as one word with it.
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
/// Measured before this was written (F921's closure).
///
/// **Three characters (F995).** NLTokenizer reads 张伟明 as 张 | 伟明 — exactly as it reads 张经理 as
/// 张 | 经理 — and 王建国, 李小龙, 周杰伦 the same way, while it reads 马拉松, 黄金周, 林业局 whole and
/// 高可用 as 高 | 可 | 用 (F995's closure, gates/F995-probe-terms.log). So a three-character term is
/// a name when it is a surname followed by one two-character word that is not a title (`titles`):
/// 张经理 stays a title term, proposed as before (张经里 → 张经理). A surname before an ordinary
/// two-character word (周报告: 周 | 报告) reads as a name too, and loses its sound-alike rows — a
/// missed row, never a wrong one. With no segmenter nothing can tell, and no term is a name.
enum ChinesePersonName {
    /// The hundred or so most common surnames, each one character.
    static let surnames: Set<Character> = Set(
        "王李张刘陈杨黄赵吴周徐孙马朱胡郭何高林罗郑梁谢宋唐许韩冯邓曹彭曾萧田董袁潘于蒋蔡余杜叶程苏魏吕丁任沈姚卢姜崔钟谭陆汪范金石廖贾夏韦付方白邹孟熊秦邱江尹薛闫段雷侯龙史陶黎贺顾毛郝龚邵万钱严覃武戴莫孔向汤"
    )

    /// Two-character titles and forms of address that follow a surname in a meeting (张经理, 李老师,
    /// 王总监): a closed class, so a closed list (F995). A surname before one of these is someone's
    /// title, not their name.
    static let titles: Set<String> = [
        "经理", "总监", "总裁", "主任", "主管", "主席", "董事", "书记", "秘书", "助理", "顾问",
        "老师", "教授", "博士", "硕士", "同学", "校长", "院长", "医生", "大夫", "护士", "律师",
        "先生", "女士", "小姐", "太太", "师傅", "老板", "阿姨", "叔叔", "大哥", "大姐",
        "部长", "处长", "科长", "局长", "厅长", "省长", "市长", "县长", "所长", "站长", "行长",
        "社长", "会长", "组长", "班长", "队长", "团长",
    ]

    /// True when `term` is a common surname followed by a given name, as `segmenter` reads it: two
    /// Han characters the segmenter does not read as one word, or three that it reads as the surname
    /// and then one two-character word that is no title (F995).
    static func isLikely(_ term: String, segmenter: CJKWordEvidence.Segmenter?) -> Bool {
        guard let segmenter, term.count == 2 || term.count == 3, let first = term.first, surnames.contains(first),
              term.allSatisfy({ ReplacementBoundary.hasCJK(String($0)) }) else { return false }
        let words = segmenter(term)
        if term.count == 2 {
            return !words.contains { $0 == term.startIndex..<term.endIndex }
        }
        let afterSurname = term.index(after: term.startIndex)
        let rest = afterSurname..<term.endIndex
        return words.contains { $0 == term.startIndex..<afterSurname } && words.contains { $0 == rest }
            && !titles.contains(String(term[rest]))
    }
}
