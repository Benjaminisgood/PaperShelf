import SwiftUI

struct SettingsSecretField: View {
    let title: String
    @Binding var text: String
    var status = ""
    @State private var visible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Group {
                    if visible { TextField(LocalizedStringKey(title), text: $text) }
                    else { SecureField(LocalizedStringKey(title), text: $text) }
                }
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                Button { visible.toggle() } label: {
                    Image(systemName: visible ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(visible ? LocalizedStringKey("隐藏") : LocalizedStringKey("显示"))
                .accessibilityLabel(Text(visible ? "隐藏\(title)" : "显示\(title)"))
            }
            if !status.isEmpty { Text(LocalizedStringKey(status)).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
