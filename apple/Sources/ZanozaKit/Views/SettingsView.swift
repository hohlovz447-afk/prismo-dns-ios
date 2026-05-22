import SwiftUI

public struct SettingsView: View {
    @Binding var settings: AppSettings
    @ObservedObject var physicalInterfaceMonitor: PhysicalInterfaceMonitor
    let isTunnelRunning: Bool
    let onCommit: () -> Void

    public init(
        settings: Binding<AppSettings>,
        physicalInterfaceMonitor: PhysicalInterfaceMonitor,
        isTunnelRunning: Bool,
        onCommit: @escaping () -> Void
    ) {
        _settings = settings
        self.physicalInterfaceMonitor = physicalInterfaceMonitor
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

            Section {
                HStack {
                    Text(AppLocalization.string("Bound interface"))
                    Spacer()
                    Text(diagnosticDisplay)
                        .foregroundColor(.secondary)
                        .font(.callout.monospacedDigit())
                }
            } header: {
                Text(AppLocalization.string("Diagnostics"))
            } footer: {
                diagnosticFooter
            }
        }
        .formStyle(.grouped)
        .onDisappear(perform: onCommit)
    }

    private var diagnosticDisplay: String {
        let snapshot = physicalInterfaceMonitor.snapshot
        if snapshot.name.isEmpty {
            return AppLocalization.string("None")
        }
        let typeLabel: String
        switch snapshot.type {
        case .wifi: typeLabel = AppLocalization.string("Wi-Fi")
        case .cellular: typeLabel = AppLocalization.string("Cellular")
        case .wired: typeLabel = AppLocalization.string("Wired")
        case .other, .none: typeLabel = AppLocalization.string("Other")
        }
        return "\(typeLabel) (\(snapshot.name))"
    }

    @ViewBuilder
    private var diagnosticFooter: some View {
        let snapshot = physicalInterfaceMonitor.snapshot
        if snapshot.name.isEmpty {
            Text(AppLocalization.string("Outbound traffic may loop through another active VPN app. Disable other VPN apps or restart Zanoza after Wi-Fi/cellular is up."))
                .foregroundColor(.orange)
        } else {
            Text(AppLocalization.string("Outbound DNS queries are pinned to this physical interface, bypassing any other active VPN."))
        }
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
