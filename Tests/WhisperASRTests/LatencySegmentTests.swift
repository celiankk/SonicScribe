import XCTest
@testable import WhisperASR

/// 管线延迟分区条回归测试（识别 / 发送 / 翻译 / 字幕刷新）。
///
/// 覆盖三件事：
/// 1. 一句的 span 只在该句走完的相邻两点之间产生采样，缺 mark 不产生假值；
/// 2. 采样窗口有上限，均值是窗口均值而非全局均值；
/// 3. 判红带迟滞：越界才红，回落到 80% 阈值以下才解除（防红/灰闪烁）。
final class LatencySegmentTests: XCTestCase {

    private let store = PipelineLatencyStore.shared

    override func setUp() {
        super.setUp()
        store.reset()
    }

    override func tearDown() {
        store.reset()
        super.tearDown()
    }

    // MARK: span

    func testCompleteSpanProducesAllSegments() {
        store.markRecognized()
        store.markRequestSent()
        store.markTranslationReceived()
        store.markSubtitleRendered()

        let snap = store.snapshot
        XCTAssertEqual(snap.sendWindow.count, 1, "发送段应有 1 个采样")
        XCTAssertEqual(snap.translateWindow.count, 1, "翻译段应有 1 个采样")
        XCTAssertEqual(snap.refreshWindow.count, 1, "刷新段应有 1 个采样")
        XCTAssertEqual(snap.displayWindow.count, 1, "端到端应有 1 个采样")
        XCTAssertTrue(snap.hasSamples)
        // 同一 span 内的单调时钟做差，均为非负且量级在毫秒内。
        XCTAssertGreaterThanOrEqual(snap.sendMs, 0)
        XCTAssertGreaterThanOrEqual(snap.translateMs, 0)
        XCTAssertGreaterThanOrEqual(snap.refreshMs, 0)
        XCTAssertLessThan(snap.sendMs + snap.translateMs + snap.refreshMs, 1000,
                          "纯内存路径的三段和不应达到秒级")
    }

    /// 不变量：四段之和 ≈ 端到端（发送 + 翻译 + 刷新 = 识别结果就绪 → 上屏）。
    /// 任一格打点错位/漏打，这个等式立刻不成立。
    func testSegmentSumEqualsEndToEnd() {
        for _ in 0..<3 {
            store.markRecognized()
            Thread.sleep(forTimeInterval: 0.002)
            store.markRequestSent()
            Thread.sleep(forTimeInterval: 0.010)
            store.markTranslationReceived()
            Thread.sleep(forTimeInterval: 0.003)
            store.markSubtitleRendered()
        }
        let snap = store.snapshot
        XCTAssertGreaterThan(snap.translateAvgMs, 5, "测试自身要有非平凡数值，否则等式恒成立")
        let sum = snap.sendAvgMs + snap.translateAvgMs + snap.refreshAvgMs
        XCTAssertEqual(sum, snap.displayAvgMs, accuracy: 0.5,
                       "发送 + 翻译 + 刷新 必须等于端到端（同一 span 的相邻区间）")
    }

    func testMissingSendMarkSkipsTranslateSegment() {
        store.markRecognized()
        // 未 markRequestSent：翻译段缺少起点，不应产出采样（不产生假值）。
        store.markTranslationReceived()
        store.markSubtitleRendered()

        let snap = store.snapshot
        XCTAssertTrue(snap.sendWindow.isEmpty, "没有 t1 就不该有发送段采样")
        XCTAssertTrue(snap.translateWindow.isEmpty, "没有 t1 就不该有翻译段采样")
        XCTAssertTrue(snap.refreshWindow.isEmpty, "没有 t2 就不该有刷新段采样")
        XCTAssertEqual(snap.displayWindow.count, 1, "端到端只看 t0 → t3，仍然成立")
    }

    func testNewSpanDiscardsPreviousResidue() {
        store.markRecognized()
        store.markRequestSent()
        // 上一句没有译文返回就开始了下一句。
        store.markRecognized()
        store.markRequestSent()

        let snap = store.snapshot
        XCTAssertEqual(snap.sendWindow.count, 2, "两次完整发送段")
        XCTAssertTrue(snap.translateWindow.isEmpty, "残留的 t1 不得配到新句上")
    }

    func testResetClearsEverything() {
        store.markRecognized()
        store.markRequestSent()
        store.markTranslationReceived()
        store.markSubtitleRendered()
        store.recordASR(ms: 123)

        store.reset()

        let snap = store.snapshot
        XCTAssertFalse(snap.hasSamples)
        XCTAssertEqual(snap.displayAvgMs, 0)
        XCTAssertEqual(snap.asrAvgMs, 0)
    }

    // MARK: 窗口

    func testWindowIsBoundedAndAveraged() {
        for _ in 0..<25 { store.recordASR(ms: 100) }
        store.recordASR(ms: 500)

        let snap = store.snapshot
        XCTAssertEqual(snap.asrWindow.count, 20, "窗口上限 20，不无限增长")
        // 最近一次 500 + 19 次 100 → 均值 (500 + 1900) / 20 = 120
        XCTAssertEqual(snap.asrAvgMs, 120, accuracy: 0.001)
        XCTAssertEqual(snap.asrMs, 500, "last 值仍是最新一次")
    }

    // MARK: 判级与迟滞

    private func data(asr: Double) -> PipelineLatencyStore.LatencyData {
        var d = PipelineLatencyStore.LatencyData()
        d.asrWindow = [asr]
        d.asrAvgMs = asr
        return d
    }

    func testLevels() {
        let threshold = LatencyStage.asr.thresholdMs
        XCTAssertEqual(LatencyLatch.level(for: .asr, data: PipelineLatencyStore.LatencyData(), latched: []), .idle)
        XCTAssertEqual(LatencyLatch.level(for: .asr, data: data(asr: threshold * 0.5), latched: []), .normal)
        XCTAssertEqual(LatencyLatch.level(for: .asr, data: data(asr: threshold * 0.85), latched: []), .warn)
        XCTAssertEqual(LatencyLatch.level(for: .asr, data: data(asr: threshold * 1.5), latched: [.asr]), .over)
    }

    func testLatchHoldsUntilEightyPercent() {
        let threshold = LatencyStage.asr.thresholdMs
        // 越界 → 锁存
        var latched = LatencyLatch.updated(previous: [], data: data(asr: threshold * 1.2))
        XCTAssertEqual(latched, [.asr])

        // 回落到阈值 90%：仍在迟滞带内，保持红（防闪烁）
        latched = LatencyLatch.updated(previous: latched, data: data(asr: threshold * 0.9))
        XCTAssertEqual(latched, [.asr], "90% 阈值不应解除锁存")

        // 回落到 50%：解除
        latched = LatencyLatch.updated(previous: latched, data: data(asr: threshold * 0.5))
        XCTAssertTrue(latched.isEmpty, "低于 80% 阈值应解除锁存")
    }

    func testLatchReleasedWhenSamplesCleared() {
        let latched = LatencyLatch.updated(previous: [.asr], data: PipelineLatencyStore.LatencyData())
        XCTAssertTrue(latched.isEmpty, "无采样必须解除锁存，否则会话重启后残留红格")
    }

    func testStagesHaveDistinctThresholds() {
        // 四段量级差一个数量级，阈值必须各自独立（共用阈值会让某格永远红）。
        let thresholds = LatencyStage.allCases.map(\.thresholdMs)
        XCTAssertEqual(Set(thresholds).count, thresholds.count, "四段阈值应互不相同")
        XCTAssertTrue(thresholds.allSatisfy { $0 > 0 })
        XCTAssertEqual(LatencyStage.allCases.count, 4)
        XCTAssertEqual(LatencyStage.allCases.map(\.title), ["识别", "发送", "翻译", "字幕刷新"])
    }
}
