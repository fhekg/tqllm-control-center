import SwiftUI

/// 离屏截图模式：ImageRenderer 无法绘制 TextField / ScrollView 等 AppKit 桥接内容，
/// 渲染模式下改用纯 SwiftUI Text 等价呈现（真实窗口中仍为可交互控件）。
enum RenderMode {
    static var active = false
}

/// 设计语言：严格对齐 design/tqllm_control_center.html 原型。
enum Theme {
    static let bg = Color(hex: 0xF3F4F5)
    static let paper = Color.white
    static let ink = Color(hex: 0x22272C)
    static let text = Color(hex: 0x404A54)
    static let muted = Color(hex: 0x838B93)
    static let border = Color(hex: 0xE7E9EC)
    static let soft = Color(hex: 0xF7F8F9)
    static let accent = Color(hex: 0x1F292E)
    static let green = Color(hex: 0x39816C)
    static let mint = Color(hex: 0xE9F5EF)
    static let amber = Color(hex: 0xA27A33)
    static let amberBg = Color(hex: 0xFAF5E9)
    static let red = Color(hex: 0xB4552D)
    static let redBg = Color(hex: 0xFAEFE9)

    static let cardRadius: CGFloat = 24
    static let panelRadius: CGFloat = 20
    static let fieldRadius: CGFloat = 10
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.paper)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).stroke(Theme.border, lineWidth: 1))
            .shadow(color: Color(hex: 0x1A242E).opacity(0.025), radius: 12, x: 0, y: 5)
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

/// 线性图标：与原型 paths 对应的 SF Symbols 选择。
enum Icon: String {
    case sliders = "slider.horizontal.3"
    case power = "power"
    case layers = "square.stack.3d.up"
    case zap = "bolt"
    case brain = "brain"
    case database = "cylinder"
    case network = "point.3.connected.trianglepath.dotted"
    case activity = "waveform.path.ecg"
    case terminal = "terminal"
    case save = "square.and.arrow.down"
    case arrow = "chevron.right"
    case back = "chevron.left"
    case cpu = "cpu"
    case check = "checkmark"
    case folder = "folder"
    case copy = "doc.on.doc"
    case info = "info.circle"
    case play = "play.fill"
    case refresh = "arrow.clockwise"
    case book = "book"
    case warning = "exclamationmark.triangle"
    case disk = "externaldrive"
    case gauge = "gauge.with.dots.needle.67percent"
}

struct LineIcon: View {
    let icon: Icon
    var size: CGFloat = 22
    var body: some View {
        Image(systemName: icon.rawValue)
            .font(.system(size: size * 0.82, weight: .regular))
            .frame(width: size, height: size)
    }
}