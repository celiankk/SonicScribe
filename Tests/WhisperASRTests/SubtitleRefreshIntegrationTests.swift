import XCTest
@testable import WhisperASR

/// 字幕刷新链路的**集成回归**（ViewModel 级）：把 docs/字幕刷新优化项.md 的三条 P0
/// 用"真实调用路径"钉住——纯策略单测在 SubtitleDisplayPolicyTests.swift，
/// 这里验的是"接进 ViewModel 之后确实生效"。
///
/// 覆盖：
///   • R1 长句尾巴可见（旧 `.prefix(maxLines)` 会让末尾永远不上屏）
///   • R1 长译文尾巴可见
///   • R2 小幅改写不擦除已显示内容
///   • R1 排队中的句子不被顶掉（旧实现 `cancel()` 掉排队句 = 整句没显示过）
final class SubtitleRefreshIntegrationTests: XCTestCase {

    private func makeViewModel() -> FloatingLetterViewModel {
        let vm = FloatingLetterViewModel()
        vm.maxLines = 2
        vm.subtitleClearDelay = 30      // 测试期间不要被空闲清除打断
        return vm
    }

    private func line(_ id: String, _ text: String, start: Double) -> FloatingLetterViewModel.SubtitleLine {
        FloatingLetterViewModel.SubtitleLine(id: id, text: text, translation: nil, start: start)
    }

    /// 泵主运行循环：队列推进用的是 MainActor Task，必须让运行循环转起来。
    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    // MARK: R1 尾巴可见

    func testLongSentenceTailIsVisibleOnScreen() {
        let vm = makeViewModel()
        // 105 个互不相同的汉字（避免周期性文本让 prefix/suffix 断言失效）、无标点：
        // 长度兜底会把它整句交给 handleSentenceCompleted → renderText
        //（正是旧实现 prefix 截断的那条路径）。
        let text = String((0..<105).map { Character(UnicodeScalar(0x4E00 + $0)!) })
        XCTAssertEqual(text.count, 105)

        vm.updateSubtitleState(final: [line("s1", text, start: 0)],
                               interimText: "", interimTranslation: nil, isPlaying: true)

        let displayed = vm.stream.renderer.text
        XCTAssertFalse(displayed.isEmpty, "长句必须上屏")
        XCTAssertTrue(displayed.hasSuffix(String(text.suffix(15))),
                      "最新的话（末尾）必须可见；实际末尾：\(displayed.suffix(20))")
        // 旧 prefix 语义下显示的是开头，末尾 45 字永远不上屏。
        XCTAssertFalse(displayed.hasPrefix(String(text.prefix(30))),
                       "显示窗口应该滚动到末尾，而不是停在开头")
    }

    func testLongTranslationTailIsVisibleOnScreen() {
        let vm = makeViewModel()
        let source = "第一句话。"
        vm.updateSubtitleState(final: [line("s1", source, start: 0)],
                               interimText: "", interimTranslation: nil, isPlaying: true)
        XCTAssertEqual(vm.stream.renderer.text, source)

        // 中文→英文会变长：60 个词的译文远超 2 行（80 字符/行）。
        let translation = (1...60).map { "word\($0)" }.joined(separator: " ")
        vm.setTranslationResult(for: source, translation: translation)

        let shown = vm.stream.translationRenderer.text
        XCTAssertFalse(shown.isEmpty, "译文必须上屏")
        XCTAssertTrue(shown.hasSuffix("word60"),
                      "译文最新部分必须可见；实际末尾：\(shown.suffix(20))")
        XCTAssertFalse(shown.hasPrefix("word1 "),
                       "译文窗口应滚动到末尾，而不是停在开头")
    }

    // MARK: R2 不回改

    func testSingleCharacterRewriteDoesNotCollapseDisplay() {
        // 复查反例（B）：只改可见区 1 个字，画面曾从 12 字立即缩到 2 字。
        let vm = makeViewModel()
        let sentence = "今天天气真不错我们一起去公园"        // 14 字 → 显示 12 字（holdback 2）
        vm.updateSubtitleState(final: [], interimText: sentence,
                               interimTranslation: nil, isPlaying: true)
        let shown = vm.stream.renderer.text
        XCTAssertEqual(shown, "今天天气真不错我们一起去")

        pump(0.25)
        // 中段改一个字（真→很）：已显示内容不得缩水、不得记到擦除。
        vm.updateSubtitleState(final: [], interimText: "今天天气很不错我们一起去公园",
                               interimTranslation: nil, isPlaying: true)
        XCTAssertEqual(vm.stream.renderer.text, shown, "单字改写不得让画面缩水")
        XCTAssertEqual(vm.readability.erasures, 0, "不得记到擦除（flicker_rate 应保持 0）")
    }

    func testSmallDivergenceDoesNotEraseDisplayedText() {
        let vm = makeViewModel()
        // 7 字（< 28 字长度兜底）→ 走流式 interim 路径（LocalAgreement + 显示门）。
        vm.updateSubtitleState(final: [], interimText: "今天天气真不错",
                               interimTranslation: nil, isPlaying: true)
        let shown = vm.stream.renderer.text
        XCTAssertEqual(shown, "今天天气真", "首轮乐观提交，但尾部 holdback 2 字不显示")

        pump(0.25)   // 过 interim 节流窗口（0.2s）
        // ASR 改口：与已显示内容只有 2 字公共前缀（小幅分叉）
        vm.updateSubtitleState(final: [], interimText: "今天下雨了",
                               interimTranslation: nil, isPlaying: true)
        XCTAssertEqual(vm.stream.renderer.text, shown,
                       "小幅改写不得擦掉已显示内容（旧实现会整段重画）")
        XCTAssertEqual(vm.readability.erasures, 0, "不得记到擦除")
    }

    func testLargeDivergenceStillSwitchesImmediately() {
        let vm = makeViewModel()
        vm.updateSubtitleState(final: [], interimText: "今天天气真不错",
                               interimTranslation: nil, isPlaying: true)
        pump(0.25)
        // 完全换了一句（公共前缀 ≈ 0）→ 必须立刻切换，不能卡在旧句上。
        vm.updateSubtitleState(final: [], interimText: "外面下雨了",
                               interimTranslation: nil, isPlaying: true)
        XCTAssertTrue(vm.stream.renderer.text.hasPrefix("外面"),
                      "换句应立刻切换；实际：\(vm.stream.renderer.text)")
    }

    // MARK: R1 不丢句

    func testQueuedSentencesAreNotDropped() {
        let vm = makeViewModel()
        var observed: Set<String> = []
        func observe() {
            let text = vm.stream.renderer.text
            if !text.isEmpty { observed.insert(text) }
        }

        vm.updateSubtitleState(final: [line("s1", "第一句话。", start: 0)],
                               interimText: "", interimTranslation: nil, isPlaying: true)
        observe()
        XCTAssertTrue(observed.contains("第一句话。"), "第一句应立即上屏")

        pump(0.3)
        // 第二句到来时第一句还没到阅读时长（5 字 → 下限 0.8s）→ 进队列。
        vm.updateSubtitleState(final: [line("s1", "第一句话。", start: 0),
                                       line("s2", "第二句话。", start: 2)],
                               interimText: "", interimTranslation: nil, isPlaying: true)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !observed.contains("第二句话。") {
            pump(0.05)
            observe()
        }
        XCTAssertTrue(observed.contains("第一句话。"), "第一句必须出现过")
        XCTAssertTrue(observed.contains("第二句话。"),
                      "排队中的第二句也必须上屏（旧实现被 cancel = 一次都没显示）")
        XCTAssertEqual(vm.readability.mergedSentences, 0)
    }
}
