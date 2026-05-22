import SwiftUI

public struct SettingsView: View {
    @Binding var settings: AppSettings
    let isTunnelRunning: Bool
    let onCommit: () -> Void

    public init(
        settings: Binding<AppSettings>,
        isTunnelRunning: Bool,
        onCommit: @escaping () -> Void
    ) {
        _settings = settings
        self.isTunnelRunning = isTunnelRunning
        self.onCommit = onCommit
    }

    public var body: some View {
        Form {
            Section {
                SocksPortRow(value: $settings.socksPort)
                Toggle(AppLocalization.string("Require username/password"), isOn: $settings.socksAuthEnabled)
                if settings.socksAuthEnabled {
                    TextField(AppLocalization.string("Username"), text: $settings.socksUser)
                        .zanozaPlainInput()
                        .onSubmit(onCommit)
                    SecureField(AppLocalization.string("Password"), text: $settings.socksPass)
                        .zanozaPlainInput()
                        .onSubmit(onCommit)
                }
            } header: {
                Text(AppLocalization.string("Local SOCKS5"))
            } footer: {
                if isTunnelRunning {
                    Text(AppLocalization.string("Changes apply after reconnecting."))
                        .foregroundStyle(.orange)
                }
            }

            Section {
                ResolversTextEditor(text: $settings.customResolvers)
            } header: {
                Text(AppLocalization.string("Resolvers"))
            } footer: {
                Text(AppLocalization.string("One resolver per line. Used by every profile; overrides the bundled list. Leave empty to fall back to the bundled public resolvers."))
            }
        }
        .formStyle(.grouped)
        .onDisappear(perform: onCommit)
    }
}

private struct SocksPortRow: View {
    @Binding var value: Int
    @FocusState private var isFocused: Bool
    @State private var text: String = ""

    var body: some View {
        HStack {
            Text(AppLocalization.string("SOCKS port"))
            Spacer(minLength: 12)
            TextField("", text: textBinding)
                .multilineTextAlignment(.trailing)
                .focused($isFocused)
                .frame(width: 92)
                #if os(iOS)
                .keyboardType(.numberPad)
                .textFieldStyle(.plain)
                #else
                .textFieldStyle(.plain)
                #endif
            Stepper("", value: clampedValue, in: AppSettings.socksPortRange)
                .labelsHidden()
                .fixedSize()
        }
        .onAppear { text = "\(value)" }
        .onChange(of: value) { newValue in
            if !isFocused { text = "\(newValue)" }
        }
        .onChange(of: isFocused) { focused in
            if !focused { commit() }
        }
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { text.isEmpty && !isFocused ? "\(value)" : text },
            set: { text = $0.filter(\.isNumber) }
        )
    }

    private var clampedValue: Binding<Int> {
        Binding(
            get: { value },
            set: { newValue in
                let clamped = AppSettings.clampedSocksPort(newValue)
                value = clamped
                text = "\(clamped)"
            }
        )
    }

    private func commit() {
        let digits = text.filter(\.isNumber)
        if let parsed = Int(digits) {
            value = AppSettings.clampedSocksPort(parsed)
        }
        text = "\(value)"
    }
}

private struct ResolversTextEditor: View {
    @Binding var text: String

    var body: some View {
        #if os(iOS)
        TextEditor(text: $text)
            .font(.system(.footnote, design: .monospaced))
            .frame(minHeight: 140)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        #else
        TextEditor(text: $text)
            .font(.system(.footnote, design: .monospaced))
            .frame(minHeight: 140)
        #endif
    }
}
