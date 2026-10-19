import AppKit
import SwiftUI

// MARK: - 管线延迟条（按参考图重做）
//
// 视觉口径来自参考图（1416×238px，按 @2x 折算 pt，数值为独立像素测量所得）：
//
//   • 外层是一张「轨道卡片」：圆角 12pt（最小二乘拟合 R = 24.1px）、填充
//     primary.opacity(0.06)（深色下 = 参考图的 #161619 落在 #080809 上）、
//     1 物理像素描边 ≈ primary.opacity(0.2)（实测 #3B3B3C）。卡片里只有那条分段条，
//     没有文字——参考图整张卡片区域内除蓝条外无任何文字像素（只有圆角抗锯齿）。
//   • 卡片里躺一条 12pt 高的胶囊形分段条（实测 24.0px，覆盖率加权积分）：
//     四段按各自耗时占比分宽，段间留 1pt 缝（实测 1.92px，缝里露出卡片底色），
//     整条被裁成胶囊——**只有整条的两个外端是圆的，段间是竖直直切口**；
//     实现上必须整体 clipShape(Capsule()) 而不是每段各自 Capsule()，否则短段会
//     被切成透镜形，与参考图明显不符。
//   • 段色：正常态是同一蓝色的明度梯度，左亮右深（参考图三段 #2971E4 / #1754DC /
//     #1541CA），因此即使某两段等宽也能看出「识别 → 发送 → 翻译 → 刷新」的先后；
//     接近阈值/越界的那段整段换成橙/红，异常段从蓝色底里跳出来，语义不靠明度猜。
//
// 两处刻意不照抄参考图的地方（都是「参考图是 3 段的示意稿」导致的）：
//   ① 段数固定 4 段：参考图只画了 3 段（2 条缝），但本 App 的管线就是 4 段；
//      少画一段会让「哪一段慢」在两次刷新之间跳变。零耗时的段也保留（minShare 保底），
//      位置稳定比「像示意图」更重要。
//   ② 段色用端点线性插值：参考图三色并不是等距插值（R 步进 -18/-2、G -29/-19、
//      B -8/-18，像是手挑的三个蓝）。这里只钉住首尾两端（与参考图完全一致）并
//      在中间线性插值——段数变化时首尾不变、明度单调变深，中间那一段与参考图
//      差 (11,13,1)/255，肉眼不可辨。
//
// 口径是同一句、同一条链路上的四段相邻区间（详见 PipelineLatencyStore 顶部）：
//
//   音频段结束 ──[识别]──▶ ASR 结果就绪 ──[发送]──▶ 请求真正发出
//                        ──[翻译]──▶ 译文返回 ──[刷新]──▶ 字幕渲染提交
//
// 结构：`LatencySegmentBar`（有状态，0.5s 轮询共享存储）只负责取数与迟滞，
// 展示全在 `LatencyBarContent`（纯吃 data，不读全局）——离屏渲染/预览因此可以直接
// 喂一份样例快照，不必先把真管线跑起来。
//
// 稳定性：① 数值取最近 20 次采样均值（PipelineLatencyStore 窗口），单次毛刺不翻色；
// ② 迟滞——越界即锁存为红，回落到 80% 阈值以下才解除，避免相邻刷新间红/灰闪烁；
// ③ 悬停任一段可看到该段名称、数值与口径。

// MARK: 分区定义

enum LatencyStage: String, CaseIterable, Identifiable {
    case asr, send, translate, refresh

    var id: String { rawValue }

    var title: String {
        switch self {
        case .asr: return "识别"
        case .send: return "发送"
        case .translate: return "翻译"
        case .refresh: return "字幕刷新"
        }
    }

    /// 越界阈值（毫秒）。四段的合理量级差一个数量级，故各自一个常量；
    /// 想统一松紧只改这里。
    var thresholdMs: Double {
        switch self {
        case .asr: return 500
        case .send: return 300
        case .translate: return 800
        case .refresh: return 100
        }
    }

    /// 口径说明（悬停提示）：不让「发送」这类段含义含糊。
    var hint: String {
        switch self {
        case .asr: return "识别：音频段结束 → ASR 出结果（引擎推理）"
        case .send: return "发送：识别结果就绪 → 翻译请求真正发出"
        case .translate: return "翻译：请求发出 → 译文返回"
        case .refresh: return "字幕刷新：译文返回 → 字幕渲染提交"
        }
    }

    func avgMs(_ d: PipelineLatencyStore.LatencyData) -> Double {
        switch self {
        case .asr: return d.asrAvgMs
        case .send: return d.sendAvgMs
        case .translate: return d.translateAvgMs
        case .refresh: return d.refreshAvgMs
        }
    }

    func hasSample(_ d: PipelineLatencyStore.LatencyData) -> Bool {
        switch self {
        case .asr: return !d.asrWindow.isEmpty
        case .send: return !d.sendWindow.isEmpty
        case .translate: return !d.translateWindow.isEmpty
        case .refresh: return !d.refreshWindow.isEmpty
        }
    }
}

// MARK: 判级与迟滞（纯函数，便于单测）

enum LatencyStageLevel {
    case idle    // 无采样
    case normal  // < 80% 阈值
    case warn    // ≥ 80% 阈值，未越界
    case over    // 越界（锁存中）
}

enum LatencyLatch {

    /// 迟滞更新：越界即锁存为 over；只有回落到 80% 阈值以下才解除。
    /// 这样相邻两次刷新之间不会红/灰闪烁；无采样的分区直接解除锁存。
    static func updated(previous: Set<LatencyStage>,
                        data: PipelineLatencyStore.LatencyData) -> Set<LatencyStage> {
        var latched = previous
        for stage in LatencyStage.allCases {
            guard stage.hasSample(data) else {
                latched.remove(stage)
                continue
            }
            let avg = stage.avgMs(data)
            if avg >= stage.thresholdMs {
                latched.insert(stage)
            } else if avg < stage.thresholdMs * 0.8 {
                latched.remove(stage)
            }
        }
        return latched
    }

    static func level(for stage: LatencyStage,
                      data: PipelineLatencyStore.LatencyData,
                      latched: Set<LatencyStage>) -> LatencyStageLevel {
        guard stage.hasSample(data) else { return .idle }
        if latched.contains(stage) { return .over }
        if stage.avgMs(data) >= stage.thresholdMs * 0.8 { return .warn }
        return .normal
    }
}

// MARK: 尺寸（参考图实测值，改视觉只改这里）

enum LatencyBarMetrics {
    /// 分段条高度：参考图 24.0px @2x（覆盖率加权积分，plateau 24.01）= 12pt。
    static let barHeight: CGFloat = 12
    /// 卡片左右内边距：参考图实测左 23.5px = 11.7pt（右侧 39.6px 是截图偏心，
    /// 不照抄——真按左右不等做，条在卡片里会肉眼可见地偏）。
    static let cardPaddingH: CGFloat = 12
    /// 卡片上下内边距：参考图实测上 40.75px / 下 32.75px（条偏下 4px）。
    /// 取对称 18pt → 卡片高 = 12 + 36 = 48pt，与参考图 98px ≈ 49pt 基本一致，
    /// 比例（条:卡片 ≈ 0.25）也与参考图 24:98 对齐。
    static let cardPaddingV: CGFloat = 18
    /// 卡片圆角：参考图最小二乘拟合 R = 24.1px（rmse 0.36）@2x = 12pt，
    /// 正好是设计令牌的浮层卡片档（Corner.medium）。
    static let cardRadius: CGFloat = Corner.medium
    /// 段间缝：参考图两处缺失覆盖率质心测得 1.92px ≈ 1pt @2x。
    static let gap: CGFloat = 1
    /// 卡片描边：参考图 1 物理像素 @2x = 0.5pt。
    static let cardBorder: CGFloat = 0.5
    /// 每段最小占比：参考图里两个短段占全宽 13.3/15.1pt（2.07% / 2.35%），
    /// 主导段 95.58%。按 4 段反解 minShare ≈ 0.025 时短段占 2.3%——
    /// 与参考图同量级；亚毫秒的段因此不会被秒级的段挤成一条线。
    static let minShare: Double = 0.025
    /// 主窗口底部细条（compact）的高度。
    static let compactHeight: CGFloat = 8
}

// MARK: 段宽布局（纯函数：只吃数值，不碰视图，便于单测）

enum LatencyBarLayout {

    /// 各段宽度（pt）。
    ///
    /// - 与自身耗时成正比，但每段保底 `minShare` 的权重——亚毫秒的段也要看得见，
    ///   否则会被秒级的段挤成一条线；
    /// - 全部为 0（无采样）时四段等宽；
    /// - 保证 `sum(宽度) + gap × (段数 - 1) == total`，容器多宽就画多宽。
    static func widths(values: [Double],
                       total: CGFloat,
                       gap: CGFloat,
                       minShare: Double) -> [CGFloat] {
        guard !values.isEmpty else { return [] }
        let usable = max(0, total - gap * CGFloat(values.count - 1))
        guard usable > 0 else { return values.map { _ in 0 } }

        let sum = values.reduce(0, +)
        guard sum > 0 else {
            // 无采样：等宽占位（灰条），仍然遵守 sum + gaps == total。
            return values.map { _ in usable / CGFloat(values.count) }
        }

        let floorWeight = sum * minShare
        let weights = values.map { max($0, floorWeight) }
        let weightSum = weights.reduce(0, +)
        guard weightSum > 0 else {
            return values.map { _ in usable / CGFloat(values.count) }
        }
        return weights.map { CGFloat(usable) * CGFloat($0 / weightSum) }
    }
}

// MARK: 段色（纯函数，便于单测）

enum LatencyBarPalette {

    /// 正常态蓝色梯度端点，取自参考图实测：左亮 #2971E4 → 右深 #1541CA。
    static let rampBright = Color(red: 0x29 / 255, green: 0x71 / 255, blue: 0xE4 / 255)
    static let rampDeep = Color(red: 0x15 / 255, green: 0x41 / 255, blue: 0xCA / 255)

    /// idle（无采样）段色：一档实心自适应灰。
    ///
    /// 不能再用 `Color.secondary.opacity(0.22)`：深色下有效 alpha ≈0.12，实测
    /// 条 #313132 落在卡片 #151516 上只有 **1.40:1**——低于 WCAG 1.4.11 对非文本
    /// 图形 3:1 的下限，等于「空轨道」根本看不见。
    /// 下面这两档是在真实窗口底色上量出来的（卡片 = primary.opacity(0.063) 叠窗口底）：
    /// 深色 #808080 on #2A2A2A = 3.60:1；浅色 #828282 on #F1F1F1 = 3.40:1。
    static let idle = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.50, alpha: 1)
            : NSColor(white: 0.51, alpha: 1)
    })

    /// 第 index 段（共 count 段）在明度梯度上的颜色；count == 1 时取亮端。
    static func ramp(index: Int, count: Int) -> Color {
        guard count > 1 else { return rampBright }
        let t = min(max(Double(index) / Double(count - 1), 0), 1)
        return blend(rampBright, rampDeep, t)
    }

    /// 线性混色（sRGB 分量直接插值，够用且可测）。
    static func blend(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let (r1, g1, b1) = components(a)
        let (r2, g2, b2) = components(b)
        return Color(red: r1 + (r2 - r1) * t,
                     green: g1 + (g2 - g1) * t,
                     blue: b1 + (b2 - b1) * t)
    }

    /// sRGB 分量（0…1）；取不到时回落到亮端，避免出现透明段。
    static func components(_ color: Color) -> (Double, Double, Double) {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else {
            return (0x29 / 255, 0x71 / 255, 0xE4 / 255)
        }
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    /// 四态配色：正常态走蓝色明度梯度，其余三态各自一个平色——
    /// 异常段从蓝底里跳出来，比「再换一种蓝」好认。
    static func color(for level: LatencyStageLevel, index: Int, count: Int) -> Color {
        switch level {
        case .idle: return idle
        case .normal: return ramp(index: index, count: count)
        case .warn: return Palette.warn
        case .over: return Palette.danger
        }
    }
}

// MARK: 延迟条（有状态：轮询共享存储）

struct LatencySegmentBar: View {

    enum Style {
        /// 状态页内的完整形态：标题行 + 轨道卡片 + 图例行。
        case full
        /// 主窗口底部的细条：只有分段条本身（无卡片、无文字）。
        case compact
    }

    var style: Style = .full

    @State private var data = PipelineLatencyStore.LatencyData()
    /// 已锁存为「越界」的分区（迟滞用）。
    @State private var overLatched: Set<LatencyStage> = []
    @State private var timer: Timer?

    var body: some View {
        LatencyBarContent(style: style, data: data, latched: overLatched)
            .onAppear {
                refresh()
                // 本视图只改自己的 @State（叶子视图），不会触发宿主页面整树重算；
                // 0.5s 节流足够看出卡顿，又不给被测管线添负担。
                timer?.invalidate()
                timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                    Task { @MainActor in refresh() }
                }
            }
            .onDisappear {
                timer?.invalidate()
                timer = nil
            }
    }

    private func refresh() {
        let snap = PipelineLatencyStore.shared.snapshot
        data = snap

        let latched = LatencyLatch.updated(previous: overLatched, data: snap)
        if latched != overLatched { overLatched = latched }
    }
}

// MARK: 延迟条（纯展示：吃一份快照，不读全局）

struct LatencyBarContent: View {

    var style: LatencySegmentBar.Style = .full
    var data: PipelineLatencyStore.LatencyData
    var latched: Set<LatencyStage> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if style == .full { header }
            track
            if style == .full { legend }
        }
    }

    // MARK: 轨道卡片

    /// 卡片 + 分段条。compact 形态不画卡片（嵌在别处时不要两层底色）。
    @ViewBuilder
    private var track: some View {
        if style == .full {
            bar
                .padding(.horizontal, LatencyBarMetrics.cardPaddingH)
                .padding(.vertical, LatencyBarMetrics.cardPaddingV)
                .background(Corner.rect(LatencyBarMetrics.cardRadius).fill(Ink.subtle))
                .overlay(
                    Corner.rect(LatencyBarMetrics.cardRadius)
                        .strokeBorder(Ink.divider, lineWidth: LatencyBarMetrics.cardBorder)
                )
        } else {
            bar
        }
    }

    /// 一条被裁成胶囊的分段条：四段按耗时占比分宽，段间细缝即分隔线。
    /// 段宽变化走动画（0.24s 标准曲线），刷新时数值不会「跳」。
    private var bar: some View {
        GeometryReader { geo in
            let widths = LatencyBarLayout.widths(
                values: stageValues,
                total: geo.size.width,
                gap: LatencyBarMetrics.gap,
                minShare: LatencyBarMetrics.minShare
            )
            HStack(spacing: LatencyBarMetrics.gap) {
                ForEach(Array(LatencyStage.allCases.enumerated()), id: \.offset) { index, stage in
                    Rectangle()
                        .fill(levelColor(stage, index: index))
                        .frame(width: widths[index])
                        .help(tooltip(stage))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .clipShape(Capsule(style: .continuous))
        }
        .frame(height: style == .full ? LatencyBarMetrics.barHeight : LatencyBarMetrics.compactHeight)
        .animation(Motion.anim(Motion.standard()), value: animationKey)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: 标题与图例（完整形态）

    private var header: some View {
        HStack(spacing: 8) {
            Text("//")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.secondary.opacity(0.5))
            Text("PIPELINE STAGES")
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(1.2)
            Spacer()
            Text(endToEndText)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// 图例：色点 + 段名 + 数值。色点与条上那一段同色，方便把「哪段是哪段」对上。
    private var legend: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Array(LatencyStage.allCases.enumerated()), id: \.offset) { index, stage in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(levelColor(stage, index: index))
                            .frame(width: 6, height: 6)
                        Text(stage.title)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(valueText(stage))
                        .font(.system(.caption, design: .monospaced, weight: .semibold))
                        // 数值是正文，用 .primary；状态色交给上面那颗色点。
                        // 直接用段色当正文会同时踩两端的对比度：深色下末段 #1541CA
                        // 只有 2.10:1、浅色下橙 #FF9500 只有 2.20:1，都低于 WCAG AA
                        // 正文 4.5:1。
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(stage.hint)
            }
        }
    }

    // MARK: 派生

    /// 各段权重（毫秒；无采样记 0，由 minShare 保底成一条可见的细段）。
    private var stageValues: [Double] {
        LatencyStage.allCases.map { stage in
            stage.hasSample(data) ? max(stage.avgMs(data), 0) : 0
        }
    }

    /// 动画触发键：数值或判级任一变化才动，避免每 0.5s 空转重算动画。
    private var animationKey: [Double] {
        let levels: [Double] = LatencyStage.allCases.map { stage in
            switch level(stage) {
            case .idle: return 0
            case .normal: return 1
            case .warn: return 2
            case .over: return 3
            }
        }
        return stageValues + levels
    }

    private func level(_ stage: LatencyStage) -> LatencyStageLevel {
        LatencyLatch.level(for: stage, data: data, latched: latched)
    }

    private func levelColor(_ stage: LatencyStage, index: Int) -> Color {
        LatencyBarPalette.color(for: level(stage),
                                index: index,
                                count: LatencyStage.allCases.count)
    }

    private func tooltip(_ stage: LatencyStage) -> String {
        "\(stage.hint)\n当前 \(valueText(stage))  ·  阈值 \(Int(stage.thresholdMs)) ms"
    }

    private func valueText(_ stage: LatencyStage) -> String {
        guard stage.hasSample(data) else { return "—" }
        let ms = stage.avgMs(data)
        // 本地/局域网链路下「发送」常 <1ms：显示 <1 而不是 0，
        // 避免被读成「没测到」。
        if ms > 0, ms < 1 { return "<1 ms" }
        return "\(Int(ms.rounded())) ms"
    }

    private var endToEndText: String {
        guard !data.displayWindow.isEmpty else { return "端到端 —" }
        return "端到端 \(Int(data.displayAvgMs.rounded())) ms"
    }

    private var accessibilitySummary: String {
        LatencyStage.allCases
            .map { "\($0.title) \(valueText($0))" }
            .joined(separator: "，")
    }
}
