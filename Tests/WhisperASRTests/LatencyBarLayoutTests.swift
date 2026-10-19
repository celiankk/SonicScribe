import XCTest
import SwiftUI
@testable import WhisperASR

/// 延迟条布局与配色的纯函数回归测试。
///
/// 条本身是「按耗时占比分宽的胶囊」：宽度的算法一旦退化成等宽，条就不再表达
/// 「哪一段慢」；一旦漏算缝隙，条又会溢出容器。这两点都是肉眼难查、但会直接
/// 让状态页说谎的回归，故用数值钉住。
final class LatencyBarLayoutTests: XCTestCase {

    private let gap = LatencyBarMetrics.gap
    private let minShare = LatencyBarMetrics.minShare

    private func widths(_ values: [Double], total: CGFloat) -> [CGFloat] {
        LatencyBarLayout.widths(values: values, total: total, gap: gap, minShare: minShare)
    }

    private func usedWidth(_ ws: [CGFloat]) -> CGFloat {
        ws.reduce(0, +) + gap * CGFloat(max(0, ws.count - 1))
    }

    // MARK: 容器占用

    func testWidthsFillContainerExactly() {
        let total: CGFloat = 640
        for values in [[500, 1, 300, 5], [0, 0, 0, 0], [1000, 0, 0, 0], [1, 1, 1, 1]] {
            let ws = widths(values.map(Double.init), total: total)
            XCTAssertEqual(ws.count, 4)
            XCTAssertEqual(usedWidth(ws), total, accuracy: 0.01,
                           "四段宽 + 三条缝必须正好等于容器宽（values=\(values)）")
        }
    }

    func testEmptyInputProducesNoSegments() {
        XCTAssertTrue(widths([], total: 640).isEmpty)
    }

    func testTooNarrowContainerDoesNotProduceNegativeWidths() {
        // 容器比缝隙总和还窄：只能是全 0，绝不能出负宽（负宽会让 SwiftUI 报布局错）。
        let ws = widths([100, 200, 300, 400], total: 3)
        XCTAssertEqual(ws.count, 4)
        XCTAssertTrue(ws.allSatisfy { $0 >= 0 }, "不得出现负宽：\(ws)")
    }

    // MARK: 占比

    func testWidthsAreProportionalToLatency() {
        // 识别 400 / 发送 100 / 翻译 400 / 刷新 100 → 2 : 1 : 2 : 1
        let ws = widths([400, 100, 400, 100], total: 610)
        XCTAssertEqual(ws[0] / ws[1], 4, accuracy: 0.02)
        XCTAssertEqual(ws[0], ws[2], accuracy: 0.01)
        XCTAssertEqual(ws[1], ws[3], accuracy: 0.01)
        XCTAssertGreaterThan(ws[0], ws[1])
    }

    func testDominantSegmentTakesMostOfTheBar() {
        // 参考图那种形态：一段主导 + 三段细缝（26 / 30 / 1224px）。
        let ws = widths([2000, 0.2, 0.2, 0.2], total: 1284)
        XCTAssertGreaterThan(ws[0], 1284 * 0.85, "主导段应占绝大部分宽度")
        XCTAssertTrue(ws.dropFirst().allSatisfy { $0 > 0 }, "其余段必须仍可见（minShare 保底）")
    }

    func testMinShareKeepsTinySegmentsVisible() {
        // 亚毫秒段（本地链路的「发送」常 <1ms）不能被秒级段挤成 0。
        let ws = widths([5000, 0.05, 0.05, 0.05], total: 600)
        for (index, w) in ws.dropFirst().enumerated() {
            XCTAssertGreaterThan(w, 0, "第 \(index + 1) 段被挤没了")
        }
        // 保底宽度 ≈ usable × minShare / (1 + 3 × minShare)
        let usable = 600 - gap * 3
        let expected = usable * CGFloat(minShare / (1 + 3 * minShare))
        XCTAssertEqual(ws[1], expected, accuracy: 0.5)
    }

    func testZeroSamplesFallBackToEqualWidths() {
        let ws = widths([0, 0, 0, 0], total: 600)
        let usable = 600 - gap * 3
        for w in ws {
            XCTAssertEqual(w, usable / 4, accuracy: 0.01, "无采样时应等宽占位（灰条）")
        }
    }

    func testMissingSampleStillGetsAVisibleSlot() {
        // 有采样但某段没有（例如该句没触发翻译）：给 0 权重，仍由 minShare 保底。
        let ws = widths([300, 0, 250, 0], total: 600)
        XCTAssertGreaterThan(ws[1], 0)
        XCTAssertGreaterThan(ws[3], 0)
        XCTAssertGreaterThan(ws[0], ws[1])
    }

    // MARK: 参考图几何（防止「改着改着就不像参考图了」）

    func testGeometryStaysWithinReferenceProportions() {
        // 参考图实测（@2x）：条 24.0px、卡片 98.0px、圆角 R=24.1px、缝 1.92px、
        // 描边 1 物理像素。这组断言只锁「量级」——允许调视觉，不允许走形。
        XCTAssertEqual(LatencyBarMetrics.barHeight, 12, accuracy: 0.5, "条高应 ≈ 12pt")
        XCTAssertEqual(LatencyBarMetrics.cardRadius, 12, accuracy: 0.5, "卡片圆角应 ≈ 12pt")
        XCTAssertEqual(LatencyBarMetrics.gap, 1, accuracy: 0.25, "段间缝应 ≈ 1pt")
        XCTAssertEqual(LatencyBarMetrics.cardBorder, 0.5, accuracy: 0.01, "描边应为 1 物理像素")
        let cardHeight = LatencyBarMetrics.barHeight + 2 * LatencyBarMetrics.cardPaddingV
        XCTAssertEqual(cardHeight, 49, accuracy: 3, "卡片高应 ≈ 参考图 98px/2 = 49pt")
    }

    func testShortSegmentsMatchReferenceShare() {
        // 参考图两个短段占全宽 2.07% / 2.35%，主导段 95.58%：
        // 本实现（固定 4 段 + minShare 保底）下短段占比应落在同一量级——
        // 既不能细到看不见，也不能胖到跟主导段一样宽。
        let ws = widths([2000, 0.2, 0.2, 0.2], total: 1284)
        let total = ws.reduce(0, +) + gap * CGFloat(ws.count - 1)
        for w in ws.dropFirst() {
            let share = Double(w / total)
            XCTAssertGreaterThan(share, 0.015, "短段占比 \(share) 比参考图（2%）还细")
            XCTAssertLessThan(share, 0.04, "短段占比 \(share) 明显胖于参考图（2%）")
        }
        XCTAssertGreaterThan(Double(ws[0] / total), 0.9, "主导段应占九成以上")
    }

    // MARK: 段色

    func testRampEndpointsMatchReferenceImage() {
        // 参考图实测：最左段 #2971E4，最右段 #1541CA。
        let bright = LatencyBarPalette.components(LatencyBarPalette.ramp(index: 0, count: 4))
        let deep = LatencyBarPalette.components(LatencyBarPalette.ramp(index: 3, count: 4))
        XCTAssertEqual(bright.0, 0x29 / 255, accuracy: 0.01)
        XCTAssertEqual(bright.1, 0x71 / 255, accuracy: 0.01)
        XCTAssertEqual(bright.2, 0xE4 / 255, accuracy: 0.01)
        XCTAssertEqual(deep.0, 0x15 / 255, accuracy: 0.01)
        XCTAssertEqual(deep.1, 0x41 / 255, accuracy: 0.01)
        XCTAssertEqual(deep.2, 0xCA / 255, accuracy: 0.01)
    }

    func testRampDarkensMonotonicallyLeftToRight() {
        let lum = (0..<LatencyStage.allCases.count).map { index -> Double in
            let (r, g, b) = LatencyBarPalette.components(
                LatencyBarPalette.ramp(index: index, count: LatencyStage.allCases.count))
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        for i in 1..<lum.count {
            XCTAssertLessThan(lum[i], lum[i - 1],
                              "梯度必须左亮右深（第 \(i) 段没有比上一段更暗）")
        }
    }

    func testRampClampsOutOfRangeIndex() {
        let first = LatencyBarPalette.components(LatencyBarPalette.ramp(index: -5, count: 4))
        let last = LatencyBarPalette.components(LatencyBarPalette.ramp(index: 99, count: 4))
        XCTAssertEqual(first.0, 0x29 / 255, accuracy: 0.01, "越界索引应钳到亮端")
        XCTAssertEqual(last.2, 0xCA / 255, accuracy: 0.01, "越界索引应钳到深端")
    }

    func testSingleStageRampIsBrightEndpoint() {
        let only = LatencyBarPalette.components(LatencyBarPalette.ramp(index: 0, count: 1))
        XCTAssertEqual(only.0, 0x29 / 255, accuracy: 0.01)
    }

    // MARK: 四态仍可区分

    func testFourLevelsRemainDistinguishable() {
        var data = PipelineLatencyStore.LatencyData()
        let threshold = LatencyStage.asr.thresholdMs

        XCTAssertEqual(LatencyLatch.level(for: .asr, data: data, latched: []), .idle)

        data.asrWindow = [threshold * 0.5]
        data.asrAvgMs = threshold * 0.5
        XCTAssertEqual(LatencyLatch.level(for: .asr, data: data, latched: []), .normal)

        data.asrAvgMs = threshold * 0.85
        XCTAssertEqual(LatencyLatch.level(for: .asr, data: data, latched: []), .warn)

        data.asrAvgMs = threshold * 1.2
        XCTAssertEqual(LatencyLatch.level(for: .asr, data: data, latched: [.asr]), .over)
    }
}
