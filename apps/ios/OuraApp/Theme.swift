import SwiftUI
import UIKit

enum Obs {
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1)
        })
    }

    static let paper = adaptive(light: 0xf4f7ff, dark: 0x101727)
    static let ink = adaptive(light: 0x101e36, dark: 0xf0f5ff)
    static let ink2 = adaptive(light: 0x344662, dark: 0xc1cee4)
    static let muted = adaptive(light: 0x4b5e78, dark: 0xa5b6d0)
    static let rule = adaptive(light: 0xc7d4e8, dark: 0x34445e)
    static let accent = adaptive(light: 0x2557ac, dark: 0x91b8ff)

    static let chart = adaptive(light: 0x426992, dark: 0xa6c5eb)
    static let good = adaptive(light: 0x087152, dark: 0x53d9a4)
    static let bad = adaptive(light: 0x9e471d, dark: 0xffa476)
    static let alert = adaptive(light: 0xaa3038, dark: 0xff8d98)

    private static let canvasBlue = adaptive(light: 0xcbdcff, dark: 0x233b6a)
    private static let canvasAqua = adaptive(light: 0xd4f1f0, dark: 0x1a3e4e)

    // Back-compat names. `teal` is the quiet chart color; `yellow` is a problem.
    static var teal: Color { chart }
    static var yellow: Color { bad }
    static var warn: Color { bad }
    static var black: Color { paper }
    static var base: Color { paper }
    static var baseLow: Color { paper }
    static var trace: Color { rule }

    static var canvas: some View {
        ZStack {
            paper
            RadialGradient(colors: [canvasBlue, paper.opacity(0)], center: .topTrailing,
                           startRadius: 0, endRadius: 520)
            RadialGradient(colors: [canvasAqua, paper.opacity(0)], center: .bottomLeading,
                           startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
    }

    // Sleep stages keep distinct hues (deep / light / REM / wake). Other charts
    // stay gray unless a value is actually good or a problem.
    static let deep = adaptive(light: 0x104281, dark: 0x5598e7)
    static let light = adaptive(light: 0x6da7ec, dark: 0x9ec5f4)
    static let rem = adaptive(light: 0x1baf7a, dark: 0x2ec48c)
    static let wake = adaptive(light: 0xeda100, dark: 0xeda100)
    static func stage(_ s: Int) -> Color {
        switch s { case 1: return deep; case 2: return light; case 3: return rem; default: return wake }
    }

    /// Color a delta only when it is large enough to be worth noticing.
    static func tone(delta: Double?, goodWhenPositive: Bool = true, threshold: Double = 8) -> Color {
        guard let d = delta else { return chart }
        let isGood = d >= 0 ? goodWhenPositive : !goodWhenPositive
        if abs(d) < threshold { return chart }
        return isGood ? good : bad
    }

    static func debt(_ state: String) -> Color {
        switch state {
        case "none": return good
        case "low": return chart
        case "moderate": return bad
        case "high": return alert
        default: return chart
        }
    }

    static func heading(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func prose(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

struct ObsTag: View {
    let text: String
    var icon: String? = nil
    init(_ text: String, icon: String? = nil) { self.text = text; self.icon = icon }
    var body: some View {
        HStack(spacing: 7) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Obs.muted)
            }
            Text(text.uppercased())
                .font(Obs.mono(11, .medium))
                .tracking(1.6)
                .foregroundStyle(Obs.muted)
        }
    }
}

struct ObsRule: View {
    var body: some View {
        Rectangle().fill(Obs.rule).frame(height: 1)
            .padding(.top, 6).padding(.bottom, 2)
    }
}

struct ObsCard: ViewModifier {
    var padding: CGFloat = 18
    var radius: CGFloat = 22
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        return content
            .padding(padding)
            .background {
                if reduceTransparency { shape.fill(Obs.paper) }
                else { shape.fill(.regularMaterial) }
            }
            .overlay { shape.strokeBorder(Obs.rule.opacity(0.65), lineWidth: 1).allowsHitTesting(false) }
    }
}

extension View {
    func obsCard(padding: CGFloat = 18, radius: CGFloat = 22) -> some View {
        modifier(ObsCard(padding: padding, radius: radius))
    }

    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            if prominent { buttonStyle(.glassProminent) }
            else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) }
            else { buttonStyle(.bordered) }
        }
        #else
        if prominent { buttonStyle(.borderedProminent) }
        else { buttonStyle(.bordered) }
        #endif
    }

    @ViewBuilder
    func glassToolbar() -> some View {
        let shape = RoundedRectangle(cornerRadius: 24)
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
        #else
        background(.regularMaterial, in: shape)
        #endif
    }
}

struct ObsStat: View {
    let label: String
    let value: String
    var accent: Color = Obs.ink
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(Obs.mono(13)).foregroundStyle(Obs.ink2)
            Spacer(minLength: 16)
            Text(value).font(Obs.mono(15, .medium)).foregroundStyle(accent)
                .monospacedDigit()
        }
    }
}
