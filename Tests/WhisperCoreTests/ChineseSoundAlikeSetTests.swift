import Foundation
import Testing
@testable import WhisperCore

// The Wave 5 review's measurement of F817 (`.claude/wave5/rev-T-logs/probes-1-revt.txt`): 40 everyday
// Chinese sentences that contain words sounding like one of 30 terms, with the app's evidence. It
// gave 15 wrong rows, none a mishearing. F921 and F916 were measured on it with this Mac's real
// NLTokenizer (`.claude/wave7/gates/F921-probe-*.log`, `F916-green.log`): 15 → 10 (no row for a
// two-character person's name) → 13 (near-homophones admitted, three more rows on sentences that
// already had one). This pins that trade-off, so a change to the sound rules moves it on purpose.
//
// NLTokenizer's segmentation of every sentence and term, as recorded, drives a dictionary segmenter
// here, so the pin holds on any machine (the real tokenizer's dictionary differs by macOS version).

private let vocabulary = [
    "经理", "上线", "主任", "公式", "公司", "原因", "市场", "刘洋", "会议", "项目",
    "客户", "预算", "周五", "合同", "李明", "数据", "测试", "方案", "部门", "进度",
    "需求", "系统", "版本", "发布", "权限", "报告", "王芳", "张伟", "期限", "时间",
]

private let sentences = [
    "他的工作经历很丰富", "这个项目有上限", "这只狗的主人很友好", "这是公事公办", "公私要分明",
    "这段录音是原音", "市长今天来视察", "他年轻时留洋多年", "黎明时分我们出发", "邮件发不出去",
    "张薇明天来开会", "刘阳出差了", "王方负责财务", "我们事件处理完了", "全线停运了",
    "这件事情很急", "他是这里的主人", "预计下周完成", "我们计算一下成本", "大家都同意这个想法",
    "请把文件发给我", "这个问题需要讨论", "我们下午三点见", "其实这个不难", "今天天气很好",
    "他说得很有道理", "这个时候不要急", "数一数有多少人", "我们要提高效率", "这周五之前要交",
    "会意了吗", "这个公事包是谁的", "部分内容需要修改", "版面设计还要调整", "报告已经写好了",
    "进度有点慢", "期待你的回复", "时常有人来问", "试一试再说", "市场部的同事",
]

/// Every word NLTokenizer found in the sentences and the terms (gates/F921-probe-seg40.log): the
/// names 张伟, 刘洋, 王芳 and 李明 as surname | given name, 周五 and the other words whole.
private let recordedWords: Set<String> = [
    "一", "一下", "三点", "上线", "上限", "下午", "下周", "不", "不要", "丰富", "主人", "主任", "之前", "了", "事件", "事情",
    "交", "人", "今天", "他", "件", "会意", "会议", "伟", "你", "修改", "停运", "全线", "公事", "公办", "公司", "公式", "公私",
    "其实", "内容", "再说", "写", "出去", "出发", "出差", "分明", "刘", "包", "原", "原因", "友好", "发", "发布", "发给", "只",
    "合同", "同事", "同意", "吗", "周五", "回复", "处理", "多少", "多年", "大家", "天气", "好", "完", "完成", "客户", "工作",
    "已经", "市场", "市场部", "市长", "年轻", "开会", "张", "录音", "很", "得", "急", "想法", "慢", "成本", "我", "我们", "把",
    "报告", "提高", "效率", "数", "数据", "文件", "方", "方案", "时", "时候", "时分", "时常", "时间", "明", "明天", "是", "有",
    "有人", "有点", "期待", "期限", "权限", "李", "来", "段", "洋", "测试", "版本", "版面", "狗", "王", "留洋", "的", "系统",
    "经历", "经理", "芳", "薇", "要", "见", "视察", "计算", "讨论", "设计", "试", "说", "请", "谁", "调整", "负责", "财务",
    "还要", "这", "这个", "这里", "进度", "道理", "邮件", "部分", "部门", "都", "问", "问题", "阳", "难", "需求", "需要", "音",
    "项目", "预算", "预计", "黎明",
]

private func seg(_ text: String) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: 0, end: 1, text: text)
}

@Test("The Wave 5 review's 40 everyday sentences give the measured sound-alike rows and never rename a person (F921, F916)")
func everydaySentencesGiveTheMeasuredSoundAlikeRows() {
    let segmenter = dictionarySegmenter(recordedWords)
    // The premise: the dictionary reads the names and the words as NLTokenizer was recorded to.
    for name in ["张伟", "刘洋", "王芳", "李明"] {
        #expect(segmenter(name).count == 2, "\(name) must read as surname | given name")
    }
    for word in ["周五", "会议", "预算", "经理"] {
        #expect(segmenter(word).count == 1, "\(word) must read whole")
    }
    let evidence = CJKWordEvidence(segmenter: segmenter, knownTerms: vocabulary)
    let rows = GlossaryCorrector.corrections(vocabulary: vocabulary, segments: sentences.map(seg), evidence: evidence)
    let shown = rows.map { "\(sentences[$0.segmentIndex]): \($0.from) → \($0.to)" }
    // 15 before F921; the five that renamed a person (张薇 → 张伟, 刘阳 → 刘洋, 王方 → 王芳, 黎明 → 李明,
    // 留洋 → 刘洋) are gone; F916's near-homophones add 公事 → 公司 (twice) and 公私 → 公式.
    #expect(shown == [
        "他的工作经历很丰富: 经历 → 经理",
        "这个项目有上限: 上限 → 上线",
        "这只狗的主人很友好: 主人 → 主任",
        "这是公事公办: 公事 → 公式",
        "这是公事公办: 公事 → 公司",
        "公私要分明: 公私 → 公式",
        "公私要分明: 公私 → 公司",
        "这段录音是原音: 原音 → 原因",
        "邮件发不出去: 发不 → 发布",
        "他是这里的主人: 主人 → 主任",
        "会意了吗: 会意 → 会议",
        "这个公事包是谁的: 公事 → 公式",
        "这个公事包是谁的: 公事 → 公司",
    ])
    #expect(!rows.contains { ["张伟", "刘洋", "王芳", "李明"].contains($0.to) }, "a sound-alike row must never rename a person")
    // Every row is a Chinese near-miss, so the sheet leaves it unticked and out of Select All (F817).
    #expect(GlossaryReviewDefaults.chineseSpans(rows) == Set(rows.indices))
}
