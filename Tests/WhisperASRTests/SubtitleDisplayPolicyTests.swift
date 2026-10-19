import XCTest
@testable import WhisperASR

/// 字幕显示策略单测（docs/字幕刷新优化项.md 的 R1/R2/R3 与 §5 P0/P1）。
///
/// 这些规则以前散在 ViewModel 的异步路径里、且**没有任何单测**：
/// 尾巴被 prefix 截掉、停留固定 1.5s、排队后到顶替——三条都靠肉眼看不出，
/// 只能靠数值钉住。
final class SubtitleDisplayPolicyTests: XCTestCase {

    // MARK: R3 阅读速度

    func testReadingTimeFollowsReadingSpeed() {
        // Netflix 成人 20 CPS：42 字 ≈ 2.1s、60 字 = 3.0s。
        XCTAssertEqual(SubtitleReadingSpeed.requiredSeconds(chars: 42), 2.1, accuracy: 0.001)
        XCTAssertEqual(SubtitleReadingSpeed.requiredSeconds(chars: 60), 3.0, accuracy: 0.001)
        XCTAssertEqual(SubtitleReadingSpeed.requiredSeconds(chars: 84), 4.2, accuracy: 0.001)
    }

    func testReadingTimeIsClamped() {
        // 下限取 Netflix 单条最短 5/6s；上限 Netflix 单条最长 7s。
        XCTAssertEqual(SubtitleReadingSpeed.requiredSeconds(chars: 5), 5.0 / 6.0, accuracy: 0.001)
        XCTAssertEqual(SubtitleReadingSpeed.requiredSeconds(chars: 0), 5.0 / 6.0, accuracy: 0.001)
        XCTAssertEqual(SubtitleReadingSpeed.requiredSeconds(chars: 10_000), 7.0, accuracy: 0.001)
    }

    func testChildReadingSpeedIsSlower() {
        XCTAssertEqual(SubtitleReadingSpeed.requiredSeconds(chars: 34, cps: SubtitleReadingSpeed.childCPS),
                       2.0, accuracy: 0.001)
    }

    func testOldFixedOnePointFiveSecondsWasTooShortForLongLines() {
        // 回归：旧的固定 1.5s 对 42 字以上的句子必然读不完。
        for chars in [42, 60, 84] {
            XCTAssertGreaterThan(SubtitleReadingSpeed.requiredSeconds(chars: chars), 1.5,
                                 "\(chars) 字在 20CPS 下需要的停留时间应超过旧的固定 1.5s")
        }
    }

    // MARK: R1 滚动窗口

    func testRollingWindowKeepsNewestLines() {
        let lines = ["一", "二", "三", "四"]
        XCTAssertEqual(SubtitleRollingWindow.tail(lines, limit: 2), ["三", "四"])
        XCTAssertEqual(SubtitleRollingWindow.tail(lines, limit: 1), ["四"])
        XCTAssertEqual(SubtitleRollingWindow.tail(lines, limit: 9), lines)
        XCTAssertTrue(SubtitleRollingWindow.tail(lines, limit: 0).isEmpty)
    }

    func testRollingWindowIsTheOppositeOfTheOldPrefixBehaviour() {
        // 旧实现 prefix(2) 会保留最早两行——长句尾巴永远不上屏。
        let lines = ["一", "二", "三", "四"]
        XCTAssertEqual(Array(lines.prefix(2)), ["一", "二"])
        XCTAssertNotEqual(SubtitleRollingWindow.tail(lines, limit: 2), Array(lines.prefix(2)))
    }

    func testLongSentenceTailSurvivesSplitting() {
        // 105 字中文 → 断行 4 块；滚动窗口必须让**最后一块**可见。
        let splitter = SubtitleSentenceSplitter()
        let text = String(repeating: "这是一段连续的中文测试语音内容", count: 7)   // 105 字
        let chunks = splitter.split(text, language: .chinese)
        XCTAssertGreaterThan(chunks.count, 2, "长文本必须被切成多于 2 块，否则这条测试没意义")
        let shown = SubtitleRollingWindow.tail(chunks, limit: 2).joined()
        XCTAssertTrue(shown.hasSuffix(chunks.last!), "最后一块（最新的话）必须在窗口里")
        let droppedByOldPrefix = chunks.dropFirst(2).joined()
        XCTAssertFalse(droppedByOldPrefix.isEmpty, "旧 prefix 语义确实会丢内容")
    }

    // MARK: R1 句子队列（不丢句）

    func testQueueIsFIFO() {
        var q = SubtitleSentenceQueue()
        XCTAssertNil(q.push("一"))
        XCTAssertNil(q.push("二"))
        XCTAssertEqual(q.pop(), "一")
        XCTAssertEqual(q.pop(), "二")
        XCTAssertNil(q.pop())
    }

    func testQueueOverflowReportsOldestForMerging() {
        var q = SubtitleSentenceQueue(capacity: 2)
        XCTAssertNil(q.push("一"))
        XCTAssertNil(q.push("二"))
        XCTAssertEqual(q.push("三"), "一", "溢出时必须把最旧的交出来（调用方合并回去，不丢内容）")
        XCTAssertEqual(q.pending, ["二", "三"])
    }

    func testQueueMergeKeepsBothSentences() {
        // 中日韩直接相接，西文补空格（否则两个词会粘在一起）。
        XCTAssertEqual(SubtitleSentenceQueue.merged("今天天气不错", "我们走吧"), "今天天气不错我们走吧")
        XCTAssertEqual(SubtitleSentenceQueue.merged("hello", "world"), "hello world")
        XCTAssertEqual(SubtitleSentenceQueue.merged("", "世界"), "世界")

        var q = SubtitleSentenceQueue(capacity: 2)
        _ = q.push("一")
        _ = q.push("二")
        let oldest = q.push("三")
        q.replaceFirst(with: SubtitleSentenceQueue.merged(oldest!, q.pending.first!))
        XCTAssertEqual(q.pending, ["一二", "三"], "被挤出的句子必须并入队首，而不是消失")
    }

    func testQueueMergeIsCappedAndKeepsNewestContent() {
        // 复查反例（task-8 缺陷 3）：合并文本无上限会随溢出线性增长（实测 20 句 → 126 字）。
        // 滚动窗口本来就只显示末尾，所以保留末尾并封顶。
        let long = String(repeating: "测", count: 100)
        let merged = SubtitleSentenceQueue.merged(long, long)
        XCTAssertEqual(merged.count, SubtitleSentenceQueue.mergeCharLimit, "合并文本必须有上限")
        XCTAssertTrue(merged.hasSuffix("测"), "封顶时保留末尾（最新内容）")
    }

    func testQueueSpeedsUpWhenBackloggedButNeverBelowFloor() {
        var q = SubtitleSentenceQueue()
        XCTAssertEqual(q.holdSeconds(chars: 60), 3.0, accuracy: 0.001)
        _ = q.push("一")
        XCTAssertEqual(q.holdSeconds(chars: 60), 3.0, accuracy: 0.001, "只有一句积压时不加速")
        _ = q.push("二")
        XCTAssertEqual(q.holdSeconds(chars: 60), 1.5, accuracy: 0.001, "两句积压时减半追赶")
        XCTAssertEqual(q.holdSeconds(chars: 4), 5.0 / 6.0, accuracy: 0.001, "加速不得低于下限（防闪读）")
    }

    // MARK: R2 LocalAgreement 稳定化

    func testFirstHypothesisIsCommittedOptimistically() {
        var s = LocalAgreementStabilizer()
        // 首轮没有第二次假设可比对：乐观提交，但尾部 holdback 仍不显示。
        XCTAssertEqual(s.candidate(for: "今天天气不错"), "今天天气")
        XCTAssertEqual(s.committed, "今天天气不错")
    }

    func testCommittedPrefixOnlyGrowsWhenTwoHypothesesAgree() {
        var s = LocalAgreementStabilizer()
        let t0 = Date()
        XCTAssertEqual(s.candidate(for: "今天天气", now: t0), "今天")
        // 第二次假设更长，但两次假设的公共前缀仍只有 4 字 → 不推进。
        XCTAssertEqual(s.candidate(for: "今天天气不错", now: t0), "今天")
        // 第三次假设与上一次一致 → 公共前缀 6 字 → 推进到 6 - 2 holdback。
        XCTAssertEqual(s.candidate(for: "今天天气不错", now: t0), "今天天气")
        XCTAssertEqual(s.committed, "今天天气不错")
    }

    func testMidSentenceRewriteDoesNotRetreatCommittedPrefix() {
        // 复查反例（D）：中段改写曾让 committed 从 14 字回退到公共前缀 4 字。
        var s = LocalAgreementStabilizer()
        let t0 = Date()
        _ = s.candidate(for: "今天天气真不错我们一起去公园", now: t0)          // 14 字提交
        XCTAssertEqual(s.committed, "今天天气真不错我们一起去公园")

        // 中段改一个字（真→很）：公共前缀 4，但已提交前缀**不得回退**（R2）。
        let still = s.candidate(for: "今天天气很不错我们一起去公园", now: t0.addingTimeInterval(0.3))
        XCTAssertEqual(s.committed, "今天天气真不错我们一起去公园", "已提交前缀不得回退")
        XCTAssertEqual(still, "今天天气真不错我们一起去", "画面保持 12 字（14 − holdback 2）")
    }

    func testMidSentenceRewriteIsAcceptedAfterBoundedWait() {
        var s = LocalAgreementStabilizer()
        s.divergenceAcceptSeconds = 1.5
        let t0 = Date()
        _ = s.candidate(for: "今天天气真不错我们一起去公园", now: t0)
        _ = s.candidate(for: "今天天气很不错我们一起去公园", now: t0.addingTimeInterval(0.3))
        // 分叉持续超过窗口 → 采信新假设（有界，不永久冻结）
        let later = t0.addingTimeInterval(2.0)
        XCTAssertEqual(s.candidate(for: "今天天气很不错我们一起去公园", now: later), "今天天气很不错我们一起去")
        XCTAssertEqual(s.committed, "今天天气很不错我们一起去公园")
        XCTAssertEqual(s.forcedCommitCount, 1)
    }

    func testReconvergingHypothesisCancelsTheDivergenceTimer() {
        // 复查反例（task-8 缺陷 1）：早期实现只在"前缀前进"时清计时，
        // 于是保护窗口变成"距**首次**分叉 1.5s"，抖动输入下画面会倒向少数派假设。
        var s = LocalAgreementStabilizer()
        s.divergenceAcceptSeconds = 1.5
        let t0 = Date()
        let a = "今天天气真不错我们一起去公园"
        let b = "今天天气很不错我们一起去公园"      // 与 a 公共前缀 4

        _ = s.candidate(for: a, now: t0)
        _ = s.candidate(for: b, now: t0.addingTimeInterval(0.2))          // 分叉一下

        // 收敛：持续喂 a 超过一个窗口（2s）
        var t = t0.addingTimeInterval(0.4)
        for _ in 0..<8 {
            _ = s.candidate(for: a, now: t)
            t = t.addingTimeInterval(0.25)
        }
        XCTAssertEqual(s.committed, a, "收敛之后不得倒向少数派假设")

        // 再次分叉：必须**重新**起 1.5s 计时，而不是"距首次分叉已超时"就立刻采信。
        XCTAssertEqual(s.candidate(for: b, now: t), "今天天气真不错我们一起去",
                       "单次分叉不得被立刻采信")
        XCTAssertEqual(s.committed, a)

        // 持续分叉满一个窗口后才采信（有界，不冻结）
        _ = s.candidate(for: b, now: t.addingTimeInterval(1.6))
        XCTAssertEqual(s.committed, b)
    }

    func testTotalDivergenceStartsAFreshSegmentImmediately() {
        var s = LocalAgreementStabilizer()
        let t0 = Date()
        _ = s.candidate(for: "今天天气不错", now: t0)
        // 零公共前缀 = 全新一段（新 tail / 换句）：没有可比对的第二次假设，
        // 按首轮乐观提交，否则每次换句都要慢一拍才显示。
        XCTAssertEqual(s.candidate(for: "外面下雨了", now: t0), "外面下")
        XCTAssertEqual(s.committed, "外面下雨了")
    }

    func testHoldbackIsTwoUnitsAndNeverShowsAPartialWord() {
        var s = LocalAgreementStabilizer()
        // 中文按字：7 字 → 显示 5 字。
        XCTAssertEqual(s.candidate(for: "今天天气真不错"), "今天天气真")
        // 太短（≤ holdback）宁可先不显示，也不要闪半个词。
        var short = LocalAgreementStabilizer()
        XCTAssertEqual(short.candidate(for: "好的"), "")
        // 西文按词：保留 holdback 个词不显示。
        var latin = LocalAgreementStabilizer()
        XCTAssertEqual(latin.candidate(for: "hello world foo bar"), "hello world")
    }

    func testStaleHypothesisIsForceCommittedToAvoidFreezing() {
        var s = LocalAgreementStabilizer()
        s.staleCommitSeconds = 5
        let t0 = Date()
        _ = s.candidate(for: "今天天气", now: t0)
        // 长时间没有新提交 → 强制采信当前假设（防冻结），并计数。
        // 6 字提交 - 2 字 holdback = 显示 4 字。
        let later = t0.addingTimeInterval(6)
        XCTAssertEqual(s.candidate(for: "今天天气很好", now: later), "今天天气")
        XCTAssertEqual(s.forcedCommitCount, 1)
        XCTAssertEqual(s.committed, "今天天气很好")
    }

    func testEmptyHypothesisKeepsPreviousCommittedText() {
        var s = LocalAgreementStabilizer()
        _ = s.candidate(for: "今天天气不错")
        let before = s.committed
        XCTAssertEqual(s.candidate(for: "   "), "今天天气")
        XCTAssertEqual(s.committed, before, "空假设不得清掉已提交内容")
    }

    // MARK: R2 显示门（不回改 + 不冻结）

    func testGateShowsGrowth() {
        var g = SubtitleDisplayGate()
        let now = Date()
        XCTAssertEqual(g.decide(current: "今天", candidate: "今天天气", now: now), .show("今天天气"))
    }

    func testGateKeepsDisplayOnSmallDivergenceThenAcceptsAfterTimeout() {
        var g = SubtitleDisplayGate(holdTimeout: 2.0)
        let t0 = Date()
        let current = "abcdefghij"
        let candidate = "abcdefXY"      // 公共前缀 6/10 = 60% ≥ 50%
        XCTAssertEqual(g.decide(current: current, candidate: candidate, now: t0), .keep,
                       "小幅改写不得静默擦掉已显示内容")
        XCTAssertEqual(g.decide(current: current, candidate: candidate, now: t0.addingTimeInterval(1.0)), .keep)
        XCTAssertEqual(g.decide(current: current, candidate: candidate, now: t0.addingTimeInterval(2.5)),
                       .show(candidate), "持有超时后必须接受改写，绝不永久冻结")
    }

    func testGateSwitchesImmediatelyOnLargeDivergence() {
        var g = SubtitleDisplayGate()
        let now = Date()
        XCTAssertEqual(g.decide(current: "abcdefghij", candidate: "abZZZ", now: now), .show("abZZZ"),
                       "分叉很大 = 换句/重开，应立刻切换")
    }

    func testGateHoldsShrinkingCandidate() {
        // 复查反例（B/C）：候选是当前画面的真前缀（缩回）时，
        // 早期实现按"分叉大"立即切换 → 画面可见地缩水。
        var g = SubtitleDisplayGate(holdTimeout: 1.0)
        let t0 = Date()
        let current = "今天天气真不错我们一起去"       // 12 字
        let shrunk = "今天天气真"                     // 真前缀
        XCTAssertEqual(g.decide(current: current, candidate: shrunk, now: t0), .keep,
                       "缩回候选不得立刻擦屏")
        XCTAssertEqual(g.decide(current: current, candidate: shrunk, now: t0.addingTimeInterval(0.5)), .keep)
        XCTAssertEqual(g.decide(current: current, candidate: shrunk, now: t0.addingTimeInterval(1.2)),
                       .show(shrunk), "持有超时后接受（有界，不永久冻结）")
    }

    func testGateIgnoresEmptyCandidate() {
        var g = SubtitleDisplayGate()
        XCTAssertEqual(g.decide(current: "今天天气", candidate: "", now: Date()), .keep)
    }

    // MARK: R4 容器高度（固定行盒的配套约束）

    func testContainerHeightRequirementGrowsWithMaxLines() {
        // 默认字号（原文 32 / 译文 24）、行间距 0；行高 38 / 29（AppKit 度量）。
        let one = AppState.requiredSubtitleContainerHeight(
            maxLines: 1, sourceFontSize: 32, translationFontSize: 24, lineSpacing: 0)
        let two = AppState.requiredSubtitleContainerHeight(
            maxLines: 2, sourceFontSize: 32, translationFontSize: 24, lineSpacing: 0)
        let three = AppState.requiredSubtitleContainerHeight(
            maxLines: 3, sourceFontSize: 32, translationFontSize: 24, lineSpacing: 0)

        XCTAssertLessThan(one, two)
        XCTAssertLessThan(two, three)
        // 下限是 S + 2T（原文盒居中 + 译文 overlay 挂盒底），不是 S + T + 16：
        // rows=2 → 76 + 2×58 = 192；rows=3 → 114 + 2×87 = 288。
        XCTAssertEqual(two, 192, accuracy: 2)
        XCTAssertEqual(three, 288, accuracy: 2)
        // 默认容器 200pt：2 行装得下、3 行装不下（复查发现的裁切缺陷）。
        XCTAssertLessThanOrEqual(two, 200, "默认容器应能装下 2 行")
        XCTAssertGreaterThan(three, 200, "3 行必须要求更高的容器，否则译文会被裁掉")
    }

    func testContainerHeightGrowsWithFontSizeAndSpacing() {
        let base = AppState.requiredSubtitleContainerHeight(
            maxLines: 2, sourceFontSize: 32, translationFontSize: 24, lineSpacing: 0)
        let biggerFont = AppState.requiredSubtitleContainerHeight(
            maxLines: 2, sourceFontSize: 48, translationFontSize: 24, lineSpacing: 0)
        let spaced = AppState.requiredSubtitleContainerHeight(
            maxLines: 2, sourceFontSize: 32, translationFontSize: 24, lineSpacing: 8)
        XCTAssertGreaterThan(biggerFont, base, "字号变大必须抬高下限")
        XCTAssertGreaterThan(spaced, base, "行间距变大必须抬高下限")
    }

    // MARK: J 可读性指标

    func testFlickerRateCountsErasuresOverPartials() {
        var m = SubtitleReadabilityMetrics()
        XCTAssertEqual(m.flickerRate, 0)
        m.recordPartial(erased: false)
        m.recordPartial(erased: false)
        m.recordPartial(erased: true)
        XCTAssertEqual(m.flickerRate, 1.0 / 3.0, accuracy: 0.0001)
        m.recordMergedSentence()
        m.recordForcedCommit()
        XCTAssertTrue(m.summary.contains("flicker=0.333"))
        XCTAssertTrue(m.summary.contains("合并=1"))
        XCTAssertTrue(m.summary.contains("强制提交=1"))
    }
}
