import AppKit
import SwiftUI

// MARK: - 逐字动画字幕（SwiftUI 原生 SplitText 效果）
//
// 参考 React Bits SplitText（chars 拆分 + 错峰入场）的观感，用原生 SwiftUI 实现：
// - 按字符拆分，新字符**只做纯淡入**（R5：不做位移、不做缩放——HIG 明确
//   反对位移/缩放入场，且位移会让文字块"长出来"时重心漂移）；
// - 公共前缀 diff：已显示的字保持静态，只有新增字符触发入场动画；
// - 实时流式追加时不会重建已有字符视图（按 offset 稳定复用），
//   避免“每个 token 更新都重放整个动画”的高频重建；
// - 自动换行 + 每行居中（复用 SubtitleFlowLayout）；
// - diff 状态放在 @State 引用盒中，不参与 Observation，长时间运行开销恒定；
// - 超出 maxAnimatedChars 时自动退化为普通 Text（超长字幕保护）。
// - **R5 动画预算**：单次刷新引入的动画总时长 ≤250ms
//   （= 单字时长 + 错峰 × (字数 − 1)），参数在本组件内被夹紧，
//   调用点传再大的值也不会超预算；
// - **P2-2 Reduce Motion**：开启系统「减少动态效果」后全部瞬时
//   （无淡入、无逐字、无位移、无缩放）。
//
// FloatingLetter 架构对应关系：
//   FloatingLetter
//   ├── SplitSubtitleText        （字幕文本拆分 + 公共前缀 diff）
//   ├── StaticLetterView         （已显示字符，静态渲染）
//   ├── AnimatedLetterView       （单字符入场动画）
//   └── SubtitleFlowLayout       （自动换行居中）

struct SplitSubtitleText: View {
    var text: String
    var fontSize: CGFloat = 26
    var fontWeight: Font.Weight = .semibold
    var foregroundStyle: Color = .white
    /// 每个新字符之间的错峰延迟（秒）。R5：默认 0（不做逐字错峰）；
    /// 实际生效值还会被总预算夹紧（绝对上限 30ms）。
    var staggerDelay: Double = 0
    /// 单字符动画时长（秒）。R5：≤120ms，超出会被夹紧。
    var duration: Double = 0.12
    /// 【保留仅为源码兼容，组件已忽略该参数】入场起始偏移。
    /// R5 禁止位移入场，故本组件不再读取它（生产调用点传 0）。
    var fromOffsetY: CGFloat = 0
    /// 【保留仅为源码兼容，组件已忽略该参数】入场起始缩放。
    /// R5 禁止缩放入场，故本组件不再读取它（生产调用点传 1）。
    var fromScale: CGFloat = 1
    /// 超出该字符数时退化为普通 Text（防止超长字幕带来大量视图）。
    var maxAnimatedChars = 200
    /// 整体对齐（跟随字幕对齐设置；默认居中）。
    var alignment: Alignment = .center

    /// P2-2：系统「减少动态效果」（SwiftUI 系统环境值）。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var diff = SplitSubtitleDiff()

    // MARK: R5 动画预算常数

    /// 单次刷新引入的动画总时长上限（R5 红线：≤250ms）。
    private static let totalBudget: Double = 0.25
    /// 单字符淡入时长上限（≤120ms）。
    private static let maxCharDuration: Double = 0.12
    /// 字符间错峰上限（≤30ms）。
    private static let maxStagger: Double = 0.03
    /// 整行淡入（句子更替分支）时长上限（≤150ms）。
    private static let sentenceFadeDuration: Double = 0.15

    private var chars: [String] {
        text.map(String.init)
    }

    var body: some View {
        let current = chars
        let commonPrefix = updatedPrefix(current: current)
        // P2-2 闸门：SwiftUI 系统环境值 + 仓库既有的运行时镜像（MotionPrefs
        // 由根视图 .reduceMotionGate() 同步）双保险——浮层是独立 NSHostingView，
        // 只依赖其中一条路径都可能漏接。
        let reduced = reduceMotion || MotionPrefs.shared.reduceMotion
        // R5：单字符时长夹紧到 ≤120ms（调用点传 0.32 / 0.5 也会被收敛）。
        let charDuration = min(max(duration, 0), Self.maxCharDuration)
        // R5：错峰同时受两个上限约束——绝对上限 30ms，以及"总时长 ≤250ms"
        // 反推出的上限。字数越多错峰越小：超长块自动退化为整块同时淡入，
        // 保证 charDuration + stagger × (字数 − 1) ≤ 250ms 恒成立。
        let staggerCap = current.count > 1
            ? max(0, (Self.totalBudget - charDuration) / Double(current.count - 1))
            : 0
        let stagger = reduced ? 0 : min(max(staggerDelay, 0), min(Self.maxStagger, staggerCap))

        if current.count > maxAnimatedChars {
            // 超长保护：普通 Text，保留系统换行/截断行为。
            Text(text)
                .font(.system(size: fontSize, weight: fontWeight))
                .foregroundStyle(foregroundStyle)
                .lineLimit(2)
                .multilineTextAlignment(alignment == .leading ? .leading : .center)
                .fixedSize(horizontal: false, vertical: true)
        } else if commonPrefix == 0, !current.isEmpty {
            // 句子更替（与上一句无公共前缀）：整行作为单一单位快速淡入。
            // 逐字重播在整句替换场景是「全屏重打」——旧句瞬间消失、新句
            // 几十个字逐个浮现，读完时间远超更新节奏，正是刷新难受的主因；
            // 追加场景（同一句增长）仍走逐字入场（打字感保留）。
            // R5：淡入 ≤150ms；H：reduce motion 时不做 transition。
            Text(text)
                .font(.system(size: fontSize, weight: fontWeight))
                .foregroundStyle(foregroundStyle)
                .multilineTextAlignment(alignment == .leading ? .leading : .center)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(nil)
                .frame(maxWidth: .infinity, alignment: alignment)
                .transition(reduced ? .identity : .opacity)
                .onAppear {
                    // 真正的交叉淡入事务由父级 FloatingLetterViews 的
                    // .animation(value: renderer.text)（同为 ≤150ms）提供；
                    // 这里保留原调用点，但必须过 H 闸门。
                    guard !reduced else { return }
                    withAnimation(.easeOut(duration: Self.sentenceFadeDuration)) {}
                }
        } else {
            SubtitleFlowLayout(
                horizontalSpacing: 0,
                lineSpacing: 2,
                textAlignment: alignment == .leading ? .leading : .center
            ) {
                ForEach(Array(current.enumerated()), id: \.offset) { index, char in
                    if index < commonPrefix {
                        StaticLetterView(
                            char: char,
                            fontSize: fontSize,
                            fontWeight: fontWeight,
                            foregroundStyle: foregroundStyle
                        )
                    } else {
                        AnimatedLetterView(
                            char: char,
                            delay: Double(index - commonPrefix) * stagger,
                            duration: charDuration,
                            fontSize: fontSize,
                            fontWeight: fontWeight,
                            foregroundStyle: foregroundStyle,
                            animated: !reduced
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment)
        }
    }

    /// 分类静态/动画前缀。仅当文本真正变化时重算；同文本的后续重渲染
    /// 保持上次分类，避免中断正在进行的入场动画。
    private func updatedPrefix(current: [String]) -> Int {
        if diff.lastText != text {
            diff.prefix = Self.commonPrefixCount(diff.chars, current)
            diff.lastText = text
            diff.chars = current
        }
        return diff.prefix
    }

    /// 连续相同的前缀数量：这些字符已经显示过，不需要重播动画。
    private static func commonPrefixCount(_ previous: [String], _ current: [String]) -> Int {
        var count = 0
        while count < previous.count, count < current.count, previous[count] == current[count] {
            count += 1
        }
        return count
    }
}

/// 非可观察的 diff 状态盒：保存在 @State 中，不参与 Observation，
/// 避免每次字幕更新触发额外重渲染。
private final class SplitSubtitleDiff {
    var lastText = ""
    var chars: [String] = []
    var prefix = 0
}

// MARK: - 已显示字符（静态）

private struct StaticLetterView: View {
    let char: String
    let fontSize: CGFloat
    let fontWeight: Font.Weight
    let foregroundStyle: Color

    var body: some View {
        let size = subtitleSegmentSize(segment: char, fontSize: fontSize, fontWeight: fontWeight)
        Text(char)
            .font(.system(size: fontSize, weight: fontWeight))
            .foregroundStyle(foregroundStyle)
            .fixedSize()
            .frame(width: size.width, height: size.height, alignment: .center)
    }
}

// MARK: - 单字符入场动画

private struct AnimatedLetterView: View {
    let char: String
    let delay: Double
    let duration: Double
    let fontSize: CGFloat
    let fontWeight: Font.Weight
    let foregroundStyle: Color
    /// P2-2：false = Reduce Motion 生效，不做任何动画，直接落到终态。
    let animated: Bool

    @State private var appeared = false

    private var bodySize: CGSize {
        subtitleSegmentSize(segment: char, fontSize: fontSize, fontWeight: fontWeight)
    }

    /// power3.out 缓动曲线（与 React Bits ease="power3.out" 观感一致）。
    private var entranceAnimation: Animation {
        .timingCurve(0.215, 0.61, 0.355, 1.0, duration: duration)
    }

    var body: some View {
        Text(char)
            .font(.system(size: fontSize, weight: fontWeight))
            .foregroundStyle(foregroundStyle)
            .fixedSize()
            // R5：入场只有 opacity 一个维度——不做 offset、不做 scaleEffect。
            .opacity(animated && !appeared ? 0 : 1)
            .frame(width: bodySize.width, height: bodySize.height, alignment: .center)
            .onAppear {
                guard animated else {
                    // H：reduce motion 时瞬时归位，不建 Task、不跑动画。
                    appeared = true
                    return
                }
                guard delay > 0 else {
                    withAnimation(entranceAnimation) { appeared = true }
                    return
                }
                Task {
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { return }
                    withAnimation(entranceAnimation) { appeared = true }
                }
            }
    }
}
