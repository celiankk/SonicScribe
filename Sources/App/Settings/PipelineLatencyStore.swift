import Foundation
import Observation
import os

// MARK: - 管线延迟聚合器（共享延迟存储）
//
// 转录管线各阶段的最新耗时，供状态页仪表盘、延迟分区条与浮层 debug 双端读写。
//
// 分区条口径（同一句、同一条链路上的四段相邻区间）：
//
//   音频段结束 ──[识别]──▶ ASR 结果就绪 ──[发送]──▶ 请求真正发出
//                        ──[翻译]──▶ 译文返回 ──[刷新]──▶ 字幕渲染提交
//
// - 识别：ASR 引擎推理耗时（ASRManager 在 transcribeChunk 前后插桩）
// - 发送：该句识别结果就绪 → 翻译请求真正发出（含排队/守卫/提示词构建）
// - 翻译：请求发出 → 译文返回（纯往返，不含排队）
// - 刷新：译文返回 → 字幕渲染提交（视图层真正画上屏）
// - 端到端（附带）：识别结果就绪 → 字幕上屏，= 发送 + 翻译 + 刷新
//
// 计时统一用单调时钟（DispatchTime.uptimeNanoseconds）：Date() 会随系统
// 对时跳变，跨阶段做差可能出负数。写入侧线程不定（翻译回调可能来自
// provider 的 @Sendable 闭包），故全部经 OSAllocatedUnfairLock 串行。

@Observable
final class PipelineLatencyStore {

    static let shared = PipelineLatencyStore()

    // MARK: 数据

    struct LatencyData {
        /// 识别：引擎推理耗时。
        var asrMs: Double = 0
        var asrAvgMs: Double = 0
        var asrWindow: [Double] = []
        /// 发送：识别结果就绪 → 翻译请求发出。
        var sendMs: Double = 0
        var sendAvgMs: Double = 0
        var sendWindow: [Double] = []
        /// 翻译：请求发出 → 译文返回（纯往返）。
        var translateMs: Double = 0
        var translateAvgMs: Double = 0
        var translateWindow: [Double] = []
        /// 字幕刷新：译文返回 → 渲染提交。
        var refreshMs: Double = 0
        var refreshAvgMs: Double = 0
        var refreshWindow: [Double] = []
        /// 端到端：识别结果就绪 → 字幕上屏（= 发送 + 翻译 + 刷新）。
        var displayMs: Double = 0
        var displayAvgMs: Double = 0
        var displayWindow: [Double] = []
        var lastUpdated = Date.distantPast

        /// 是否已有任何采样（分区条据此区分「无数据」与「0ms」）。
        var hasSamples: Bool {
            !asrWindow.isEmpty || !sendWindow.isEmpty
                || !translateWindow.isEmpty || !refreshWindow.isEmpty
        }
    }

    /// 一句的绝对时间戳（单调时钟，纳秒）。
    private struct Span {
        var recognizedAt: UInt64?
        var sentAt: UInt64?
        var receivedAt: UInt64?
    }

    private let lock = OSAllocatedUnfairLock<LatencyData>(initialState: LatencyData())
    private let spanLock = OSAllocatedUnfairLock<Span>(initialState: Span())

    private static let windowSize = 20

    private init() {}

    // MARK: 读取（仪表盘/分区条 tick 调用）

    var snapshot: LatencyData {
        lock.withLock { $0 }
    }

    // MARK: 写入 —— 识别（ASRManager 调用）

    /// 识别引擎推理耗时。
    func recordASR(ms: Double) {
        lock.withLock { data in
            data.asrMs = ms
            Self.push(ms, into: &data.asrWindow)
            data.asrAvgMs = Self.average(data.asrWindow)
            data.lastUpdated = Date()
        }
    }

    // MARK: 写入 —— 一句的四段 span（字幕层 + 翻译层调用）
    //
    // 顺序固定：markRecognized → markRequestSent → markTranslationReceived
    // → markSubtitleRendered。任一段缺失（例如翻译被暂停、该句未触发翻译）
    // 只跳过该段，不产生假值。

    /// 该句识别结果就绪（字幕层判定「一句完成」处）。
    /// 同时开启一个新的 span：上一句未走完的残留时间戳全部作废。
    func markRecognized() {
        let t = Self.nowNs()
        spanLock.withLock { $0 = Span(recognizedAt: t, sentAt: nil, receivedAt: nil) }
    }

    /// 翻译请求真正发出（TranslationManager 调 provider 之前）。
    func markRequestSent() {
        let t = Self.nowNs()
        let elapsed = spanLock.withLock { span -> Double? in
            guard let start = span.recognizedAt else { return nil }
            span.sentAt = t
            return Self.ms(from: start, to: t)
        }
        guard let elapsed else { return }
        lock.withLock { data in
            data.sendMs = elapsed
            Self.push(elapsed, into: &data.sendWindow)
            data.sendAvgMs = Self.average(data.sendWindow)
            data.lastUpdated = Date()
        }
    }

    /// 译文返回（字幕层收到该句译文）。
    func markTranslationReceived() {
        let t = Self.nowNs()
        let elapsed = spanLock.withLock { span -> Double? in
            guard let sent = span.sentAt else { return nil }
            span.receivedAt = t
            return Self.ms(from: sent, to: t)
        }
        guard let elapsed else { return }
        lock.withLock { data in
            data.translateMs = elapsed
            Self.push(elapsed, into: &data.translateWindow)
            data.translateAvgMs = Self.average(data.translateWindow)
            data.lastUpdated = Date()
        }
    }

    /// 字幕渲染提交（视图层真正画上屏）。
    func markSubtitleRendered() {
        let t = Self.nowNs()
        let (refresh, total) = spanLock.withLock { span -> (Double?, Double?) in
            let refresh = span.receivedAt.map { Self.ms(from: $0, to: t) }
            let total = span.recognizedAt.map { Self.ms(from: $0, to: t) }
            span.receivedAt = nil
            return (refresh, total)
        }
        lock.withLock { data in
            if let refresh {
                data.refreshMs = refresh
                Self.push(refresh, into: &data.refreshWindow)
                data.refreshAvgMs = Self.average(data.refreshWindow)
                data.lastUpdated = Date()
            }
            if let total {
                data.displayMs = total
                Self.push(total, into: &data.displayWindow)
                data.displayAvgMs = Self.average(data.displayWindow)
                data.lastUpdated = Date()
            }
        }
    }

    /// 全量重置（新录制会话）。
    func reset() {
        lock.withLock { $0 = LatencyData() }
        spanLock.withLock { $0 = Span() }
    }

    // MARK: 内部

    private static func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    private static func ms(from: UInt64, to: UInt64) -> Double {
        Double(to &- from) / 1_000_000
    }

    private static func push(_ value: Double, into window: inout [Double]) {
        window.append(value)
        if window.count > windowSize { window.removeFirst() }
    }

    private static func average(_ window: [Double]) -> Double {
        guard !window.isEmpty else { return 0 }
        return window.reduce(0, +) / Double(window.count)
    }
}
