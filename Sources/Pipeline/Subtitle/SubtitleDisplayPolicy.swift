import Foundation

// MARK: - 字幕显示策略（纯逻辑，可单测）
//
// 落地 docs/字幕刷新优化项.md 的 §1 红线与 §5 P0/P1：
//   • SubtitleReadingSpeed      —— 每屏停留多久：按阅读速度算，不再固定 1.5s（R3）
//   • SubtitleRollingWindow     —— 只保留最新 N 行：长句尾巴不再被截掉（R1）
//   • SubtitleSentenceQueue     —— 排队不丢句：FIFO + 积压加速（R1）
//   • LocalAgreementStabilizer  —— 已提交前缀只增不减：防"回改"（R2）
//   • SubtitleDisplayGate       —— 小改写不回退、但持有超时后接受（R2 + 防冻结）
//   • SubtitleReadabilityMetrics—— 把"看得懂"变成可观测数字（J）
//
// 这里只放纯函数/值类型：不碰视图、不读全局、时间由调用方注入，
// 因此每条规则都能被单测钉住（本仓库既有做法：SubtitleSentenceTrigger /
// StreamingFeedWaterline / LatencyLatch）。

// MARK: 阅读速度

enum SubtitleReadingSpeed {
    /// Netflix Timed Text Style Guide I.14：成人上限 20 CPS、儿童 17 CPS。
    static let adultCPS: Double = 20
    static let childCPS: Double = 17
    /// 停留下限：再短就是闪读。取 Netflix 的单条最短时长 5/6s。
    static let floorSeconds: TimeInterval = 5.0 / 6.0
    /// 停留上限：Netflix 单条最长 7s；到顶说明该句该断句而不是继续占屏。
    static let capSeconds: TimeInterval = 7.0

    /// 一屏文本读完需要多久（秒）。
    /// - 20 CPS 下：42 字 ≈ 2.1s、60 字 = 3.0s、84 字 ≈ 4.2s。
    static func requiredSeconds(chars: Int, cps: Double = adultCPS) -> TimeInterval {
        guard chars > 0 else { return floorSeconds }
        let raw = Double(chars) / max(cps, 1)
        return min(capSeconds, max(floorSeconds, raw))
    }
}

// MARK: 滚动窗口（R1 不丢尾）

enum SubtitleRollingWindow {
    /// 只保留**最新** limit 行。
    ///
    /// 直播字幕的价值是"正在说的话"：旧实现用 `prefix(limit)` 保留最早的
    /// 几行，导致长句尾巴（最新的话）永远不上屏——105 字中文只显示前 60 字，
    /// 后 45 字从头到尾没出现过。这里改成保留末尾。
    static func tail(_ lines: [String], limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        return Array(lines.suffix(limit))
    }
}

// MARK: 句子队列（R1 不丢句）

/// 待渲染句子队列：FIFO 而不是"后到顶替"。
///
/// 旧实现每次新句都 `cancel()` 掉排队中的上一句 → 那句话一次都没显示
/// （翻译却照发）。这里排队，并在积压时**加速**（缩短停留，保底 floor），
/// 既保证每句至少露一次面，又不会无限滞后；
/// 容量溢出时**合并**而不是丢弃（见 `merged(_:_:)`）。
struct SubtitleSentenceQueue {
    /// 队列容量：超过就合并最旧的一句（不丢内容，见 `merged`）。
    var capacity: Int = 4
    private(set) var pending: [String] = []

    var isEmpty: Bool { pending.isEmpty }
    var count: Int { pending.count }

    /// 入队；返回因溢出被挤出的最旧句子（无则 nil）——调用方应把它合并回去。
    mutating func push(_ text: String) -> String? {
        pending.append(text)
        guard pending.count > capacity else { return nil }
        return pending.removeFirst()
    }

    /// 用新文本替换队首（溢出合并时用）。
    mutating func replaceFirst(with text: String) {
        guard !pending.isEmpty else { pending = [text]; return }
        pending[0] = text
    }

    /// 合并上限（字符）：滚动窗口只显示最近 N 行（中文 2×30 字 ≈ 60），
    /// 合并文本超过它就只有尾巴可见——留太长只会让队列项无界增长
    ///（实测连推 20 句可线性涨到 126 字）。保留**末尾**（最新内容）。
    static let mergeCharLimit = 120

    /// 把被挤出的旧句并回新句：内容仍会出现在滚动窗口里，
    /// 而不是"整句从未上屏"（文档 §5 P0-3：合并而不是丢弃）。
    /// 中日韩之间不需要分隔符，西文之间补空格（否则两个词会粘在一起）；
    /// 超出 `limit` 时保留末尾（窗口本来就只显示末尾）。
    static func merged(_ older: String, _ newer: String, limit: Int = mergeCharLimit) -> String {
        let a = older.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = newer.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        let cjkA = a.unicodeScalars.last.map(SubtitleLanguage.isCJK) ?? true
        let cjkB = b.unicodeScalars.first.map(SubtitleLanguage.isCJK) ?? true
        let combined = (cjkA && cjkB) ? a + b : "\(a) \(b)"
        guard limit > 0, combined.count > limit else { return combined }
        return String(combined.suffix(limit))
    }

    mutating func pop() -> String? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    mutating func removeAll() { pending.removeAll() }

    /// 当前屏该停留多久：积压 ≥2 句时减半（下限 floor），追赶但不闪读。
    func holdSeconds(chars: Int, cps: Double = SubtitleReadingSpeed.adultCPS) -> TimeInterval {
        let base = SubtitleReadingSpeed.requiredSeconds(chars: chars, cps: cps)
        guard pending.count >= 2 else { return base }
        return max(SubtitleReadingSpeed.floorSeconds, base * 0.5)
    }
}

// MARK: LocalAgreement-2 稳定化（R2 不回改）

/// 连续两次假设的**最长公共前缀**才算"已提交"。
///
/// 依据：ufal/whisper_streaming 的 `HypothesisBuffer.flush()`
/// （源码注释原文 "the longest common prefix of 2 last inserts"）与
/// Chromium Live Caption 的 `GreedyTextStabilizer`（直方图取稳定前缀）。
/// 本 App 的 whisper 活循环每轮重转写未封口 tail，所以"两次假设一致的部分"
/// 正是可以放心显示的部分。
///
/// 尾部 holdback：最后 N 个单元（中文按字、西文按词）先不显示——最容易被改写；
/// 长时间不增长则强制提交（WhisperLiveKit 的防冻结思路）。
struct LocalAgreementStabilizer {
    /// 尾部 holdback 单元数。
    var holdbackUnits: Int = 2
    /// 超过该时长没有新的提交 → 强制提交当前假设（防冻结）。
    var staleCommitSeconds: TimeInterval = 12
    /// 中段改写（有公共前缀但已提交前缀不再成立）持续多久才采信新假设。
    /// 取 1.5s：短于这个的抖动（whisper 重转写 tail 常见）不回改画面，
    /// 长于这个的改写必须被接受，否则会一直显示旧文本。
    var divergenceAcceptSeconds: TimeInterval = 1.5

    private var lastHypothesis = ""
    private(set) var committed = ""
    private var lastGrowthAt: Date?
    private var divergenceSince: Date?
    private(set) var forcedCommitCount = 0

    var isEmpty: Bool { committed.isEmpty }

    mutating func reset() {
        lastHypothesis = ""
        committed = ""
        lastGrowthAt = nil
        divergenceSince = nil
    }

    /// 喂入一次假设，返回**可作为候选显示**的文本（已去掉尾部 holdback）。
    /// 空串 = 目前还没有可显示内容（调用方保持原画面，不要清屏）。
    mutating func candidate(for hypothesis: String, now: Date = Date()) -> String {
        let h = hypothesis.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { lastHypothesis = h }
        guard !h.isEmpty else { return displayed }

        if committed.isEmpty {
            // 首轮没有第二次假设可比对：乐观提交（否则每句开头都慢一拍）。
            committed = h
            lastGrowthAt = now
            return displayed
        }

        if h.hasPrefix(committed) {
            // 假设重新以已提交前缀开头 = 之前的"分叉"结束了 → **无条件撤销计时**。
            // （早期版本只在"前缀前进"时清，于是保护窗口变成"距首次分叉 1.5s"，
            //   抖动输入下画面会倒向少数派假设。）
            divergenceSince = nil
            // 假设仍在已提交前缀上生长：提交到"两次假设的公共前缀"。
            let lcp = Self.commonPrefixLength(lastHypothesis, h)
            if lcp > committed.count {
                committed = String(h.prefix(lcp))
                lastGrowthAt = now
            } else if let t = lastGrowthAt, now.timeIntervalSince(t) >= staleCommitSeconds {
                committed = h          // 防冻结：长时间没有新提交，直接采信当前假设
                lastGrowthAt = now
                forcedCommitCount += 1
            }
            return displayed
        }

        // 假设不再包含已提交前缀 = ASR 改口。两种情形必须区别对待：
        //
        // ① 零公共前缀 = ASR 换了一段（新 tail / 新句）：没有可比对的东西，
        //    按"首轮"乐观提交，否则每次换句都要慢一拍才显示。
        // ② 有公共前缀但中段被改写（whisper 重转写 tail 时最常见）：
        //    **已提交前缀不回退**（R2：已显示的字不许被静默删掉）——早期实现
        //    这里 `committed = h.prefix(lcp)`，只改一个字就会让画面从 12 字缩到 2 字。
        //    但也不能永久显示 ASR 已不认的旧文本，所以给一个有界的接受窗口：
        //    分叉持续 `divergenceAcceptSeconds` 之后才采信新假设。
        let lcp = Self.commonPrefixLength(lastHypothesis, h)
        if lcp == 0 {
            committed = h
            lastGrowthAt = now
            divergenceSince = nil
            return displayed
        }
        if divergenceSince == nil { divergenceSince = now }
        if let since = divergenceSince, now.timeIntervalSince(since) >= divergenceAcceptSeconds {
            committed = h
            lastGrowthAt = now
            divergenceSince = nil
            forcedCommitCount += 1
        }
        return displayed
    }

    /// 已提交文本去掉尾部 holdback。holdback 跨不过词边界（西文按词、中文按字）。
    var displayed: String {
        guard !committed.isEmpty else { return "" }
        guard holdbackUnits > 0 else { return committed }
        let isCJK = committed.unicodeScalars.contains { SubtitleLanguage.isCJK($0) }
        if isCJK {
            let chars = Array(committed)
            guard chars.count > holdbackUnits else { return "" }
            return String(chars[0..<(chars.count - holdbackUnits)])
        }
        // 西文：按词回退 holdbackUnits 个词，且不吐出半个词。
        let words = committed.split(separator: " ", omittingEmptySubsequences: false)
        guard words.count > holdbackUnits else { return "" }
        return words[0..<(words.count - holdbackUnits)].joined(separator: " ")
    }

    static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        var i = 0
        while i < x.count, i < y.count, x[i] == y[i] { i += 1 }
        return i
    }
}

// MARK: 显示门（R2 不回改 + 防冻结）

enum SubtitleDisplayDecision: Equatable {
    /// 保持当前画面不动（已显示的字不回改）。
    case keep
    /// 换成这个文本。
    case show(String)
}

/// 决定"新候选文本要不要替换当前画面"。
///
/// 规则（对应文档 §5 P1-2 的"只追加不回退"，以及"不能永久冻结"）：
/// 1. 候选是当前显示的增长（前缀延伸）→ 显示（打字感保留）；
/// 2. 候选是当前显示的**真前缀**（缩回，例如整句已上屏后来了个更短的 interim）
///    → 绝不立刻擦屏，持有 `holdTimeout` 后接受；
/// 3. 候选与当前显示分叉：幅度大（公共前缀 < 50%）= 换句/换段 → 立即切换；
///    幅度小（≥ 50%）= 同句中段改写 → 先持有，超时后接受；
/// 4. 候选为空 → 保持（绝不清屏）。
struct SubtitleDisplayGate {
    /// 持有窗口：同句改写 / 缩回候选要等这么久才允许替换画面。
    /// 取 1s：stabilizer 已经先等过 `divergenceAcceptSeconds`(1.5s)，
    /// 这里再等太久就只是把"显示旧文本"的时间拉长。
    var holdTimeout: TimeInterval = 1.0
    private var heldSince: Date?

    mutating func reset() { heldSince = nil }

    mutating func decide(current: String, candidate: String, now: Date = Date()) -> SubtitleDisplayDecision {
        let cur = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty else { return .keep }
        guard !cur.isEmpty else { heldSince = nil; return .show(next) }
        if next == cur { heldSince = nil; return .keep }
        if next.hasPrefix(cur) { heldSince = nil; return .show(next) }

        // 缩回（候选是当前画面的真前缀）：绝不立刻擦掉已显示内容。
        if cur.hasPrefix(next) { return holdOrAccept(next, now: now) }

        let lcp = LocalAgreementStabilizer.commonPrefixLength(cur, next)
        let shared = Double(lcp) / Double(max(cur.count, 1))
        if shared < 0.5 {
            heldSince = nil
            return .show(next)        // 分叉很大 = 换句/重开，正常切换
        }
        return holdOrAccept(next, now: now)
    }

    /// 持有 → 超时接受（有界，绝不永久冻结）。
    private mutating func holdOrAccept(_ next: String, now: Date) -> SubtitleDisplayDecision {
        if let since = heldSince, now.timeIntervalSince(since) >= holdTimeout {
            heldSince = nil
            return .show(next)
        }
        if heldSince == nil { heldSince = now }
        return .keep
    }
}

// MARK: 可读性指标（J）

/// "看得懂"的可观测口径（Chromium 把抖动做成 flicker_rate，这里照搬）。
struct SubtitleReadabilityMetrics {
    /// partial（流式）更新次数。
    private(set) var partialUpdates = 0
    /// 已显示文本被改写/缩短的次数（= 擦除）。
    private(set) var erasures = 0
    /// 因队列溢出被**合并**进相邻句的句子数（合并而非丢弃，内容仍会上屏）。
    private(set) var mergedSentences = 0
    /// 防冻结/分叉超时导致的强制提交次数。
    private(set) var forcedCommits = 0

    /// 抖动率：目标 < 0.05（0 = 同句增长期间从不擦除）。
    var flickerRate: Double {
        partialUpdates == 0 ? 0 : Double(erasures) / Double(partialUpdates)
    }

    mutating func recordPartial(erased: Bool) {
        partialUpdates += 1
        if erased { erasures += 1 }
    }

    mutating func recordMergedSentence() { mergedSentences += 1 }
    mutating func recordForcedCommit() { forcedCommits += 1 }

    mutating func reset() { self = SubtitleReadabilityMetrics() }

    var summary: String {
        "partial=\(partialUpdates) 擦除=\(erasures) flicker=\(String(format: "%.3f", flickerRate)) "
            + "合并=\(mergedSentences) 强制提交=\(forcedCommits)"
    }
}
