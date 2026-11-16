import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 与原型一致的通用组件

struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
            content
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paper)
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }
}

struct NoteBox: View {
    let text: String
    var warn = false
    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(warn ? Theme.amber : Theme.text)
            .lineSpacing(3)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(warn ? Theme.amberBg : Theme.soft)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct DataRow: View {
    let name: String
    let value: String
    var mono = false
    var body: some View {
        HStack(alignment: .top) {
            Text(name).font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            Spacer(minLength: 12)
            Text(mono ? prettyPath(value) : value)
                .font(.system(size: 12.5, design: mono ? .monospaced : .default))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 0.5) }
    }
}

struct FieldLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
    }
}

struct StyledTextField: View {
    let label: String
    @Binding var text: String
    var hint: String = ""
    var mono = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: label)
            if RenderMode.active {
                Text(text.isEmpty ? " " : prettyPath(text))
                    .font(.system(size: 13, design: mono ? .monospaced : .default))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.paper)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous).stroke(Theme.border, lineWidth: 1))
            } else {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: mono ? .monospaced : .default))
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Theme.paper)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous).stroke(Theme.border, lineWidth: 1))
            }
            if !hint.isEmpty {
                Text(hint).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
        }
    }
}

struct StyledNumberField: View {
    let label: String
    @Binding var value: Int
    var hint: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: label)
            if RenderMode.active {
                Text("\(value)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.paper)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous).stroke(Theme.border, lineWidth: 1))
            } else {
                TextField("", value: $value, format: .number)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Theme.paper)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous).stroke(Theme.border, lineWidth: 1))
            }
            if !hint.isEmpty {
                Text(hint).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
        }
    }
}

struct StyledSecureField: View {
    let label: String
    @Binding var text: String
    var hint: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: label)
            if RenderMode.active {
                Text(text.isEmpty ? "（未设置）" : String(repeating: "•", count: min(12, text.count)))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.paper)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous).stroke(Theme.border, lineWidth: 1))
            } else {
                SecureField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Theme.paper)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous).stroke(Theme.border, lineWidth: 1))
            }
            if !hint.isEmpty {
                Text(hint).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
        }
    }
}

/// 原型风格的开关行。
struct SwitchRow: View {
    let title: String
    var desc: String = ""
    @Binding var isOn: Bool
    var disabled = false
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.ink)
                if !desc.isEmpty {
                    Text(desc).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            if RenderMode.active {
                Text(isOn ? "开" : "关")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isOn ? Theme.green : Theme.muted)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(isOn ? Theme.mint : Theme.soft)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(isOn ? Theme.green.opacity(0.4) : Theme.border, lineWidth: 1))
            } else {
                Toggle("", isOn: $isOn)
                    .toggleStyle(.switch)
                    .tint(Theme.green)
                    .labelsHidden()
                    .disabled(disabled)
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 0.5) }
    }
}

/// 原型 choice 分段按钮。
struct ChoiceRow<T: Hashable>: View {
    let title: String
    let options: [(T, String)]
    @Binding var selection: T
    var desc: String = ""
    var disabled: Set<T> = []
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(text: title)
            HStack(spacing: 6) {
                ForEach(options, id: \.0) { opt in
                    let isDisabled = disabled.contains(opt.0)
                    Button {
                        if !isDisabled { selection = opt.0 }
                    } label: {
                        Text(opt.1 + (isDisabled ? "（不可用）" : ""))
                            .font(.system(size: 12.5, weight: selection == opt.0 ? .semibold : .regular))
                            .foregroundStyle(isDisabled ? Theme.muted : (selection == opt.0 ? Theme.paper : Theme.text))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(selection == opt.0 && !isDisabled ? Theme.accent : Theme.soft)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(selection == opt.0 && !isDisabled ? Color.clear : Theme.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(isDisabled)
                    .opacity(isDisabled ? 0.5 : 1)
                }
            }
            if !desc.isEmpty {
                Text(desc).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
        }
    }
}

struct ActionButton: View {
    let label: String
    var icon: Icon? = nil
    var primary = false
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { LineIcon(icon: icon, size: 15) }
                Text(label).font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(primary ? Theme.paper : Theme.text)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(primary ? Theme.accent : Theme.paper)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(primary ? Color.clear : Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
    }
}

struct Pill: View {
    let text: String
    var tone: Tone = .neutral
    enum Tone { case neutral, green, amber, red }
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(fg)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(bg)
            .clipShape(Capsule())
    }
    var fg: Color {
        switch tone {
        case .neutral: return Theme.muted
        case .green: return Theme.green
        case .amber: return Theme.amber
        case .red: return Theme.red
        }
    }
    var bg: Color {
        switch tone {
        case .neutral: return Theme.soft
        case .green: return Theme.mint
        case .amber: return Theme.amberBg
        case .red: return Theme.redBg
        }
    }
}

struct MonoBlock: View {
    let text: String
    var body: some View {
        Group {
            if RenderMode.active {
                Text(prettyPath(text))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    Text(text)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 220)
            }
        }
        .background(Theme.soft)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }
}

struct RestartBadge: View {
    var body: some View {
        Pill(text: "需要重启", tone: .amber)
    }
}

/// 详情页头部：返回 + 面包屑 + 标题。
struct DetailHead: View {
    let title: String
    let subtitle: String
    let onBack: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 5) {
                        LineIcon(icon: .back, size: 14)
                        Text("返回总览").font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Theme.paper)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Spacer()
                Text("功能设置 / \(title)").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            }
            Text(title).font(.system(size: 27, weight: .bold)).foregroundStyle(Theme.ink)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.muted)
        }
        .padding(.bottom, 6)
    }
}

/// 两栏详情布局。
struct DetailBody<L: View, R: View>: View {
    @ViewBuilder var left: L
    @ViewBuilder var right: R
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 18) { left }.frame(maxWidth: .infinity)
            VStack(spacing: 18) { right }.frame(width: 340)
        }
    }
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// 显示用路径美化：把主目录前缀替换为 ~（仅用于展示，不改动实际配置值）。
/// 既缩短显示，也避免在截图/界面中暴露本机用户名。
func prettyPath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}

/// 外部终端启动的服务：停止前必须用户确认。
func confirmExternalStop() -> Bool {
    let alert = NSAlert()
    alert.messageText = "服务由外部终端启动"
    alert.informativeText = "检测到 tqllm 服务不是本应用启动的（可能来自终端）。停止它将中断外部会话。确定停止吗？"
    alert.addButton(withTitle: "停止服务")
    alert.addButton(withTitle: "取消")
    alert.alertStyle = .warning
    return alert.runModal() == .alertFirstButtonReturn
}

func savePanel(defaultName: String, content: String) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = defaultName
    panel.canCreateDirectories = true
    if panel.runModal() == .OK, let url = panel.url {
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
}

func openPanel() -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url {
        return try? String(contentsOf: url, encoding: .utf8)
    }
    return nil
}

func chooseDirectory() -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url { return url.path }
    return nil
}

func chooseFile(extensions: [String]) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
    if panel.runModal() == .OK, let url = panel.url { return url.path }
    return nil
}