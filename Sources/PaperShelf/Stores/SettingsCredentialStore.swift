import SwiftUI

/// Keeps editable values after saving, so reopening settings is a normal form
/// rather than a write-only replacement box.
@MainActor
final class SettingsCredentialStore: ObservableObject {
    @Published var values: [CredentialPlan.Secret: String] = [:]
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private var unavailable: Set<CredentialPlan.Secret> = []
    private var baseline: [CredentialPlan.Secret: String] = [:]
    private var edited: Set<CredentialPlan.Secret> = []
    private var loaded = false

    func binding(_ key: CredentialPlan.Secret) -> Binding<String> {
        Binding(get: { self.values[key] ?? "" }, set: { self.values[key] = $0; self.edited.insert(key) })
    }

    func hasNewValue(_ key: CredentialPlan.Secret) -> Bool {
        let value = values[key] ?? ""
        return !value.isEmpty && value != baseline[key]
    }

    func status(_ key: CredentialPlan.Secret) -> String {
        if loading { return "正在读取…" }
        let value = values[key] ?? ""
        if let saved = baseline[key], value == saved { return value.isEmpty ? "未设置" : "已保存" }
        if !value.isEmpty { return "待保存" }
        if unavailable.contains(key) { return "旧值无法读取，请重新填写后保存" }
        return baseline[key]?.isEmpty == false ? "保存后清除" : "未设置"
    }

    func load() async {
        guard !loaded else { return }
        loaded = true; loading = true
        defer { loading = false }
        let initial = values
        await withTaskGroup(of: (CredentialPlan.Secret, String?).self) { group in
            for key in CredentialPlan.Secret.allCases {
                group.addTask {
                    do {
                        let result = try await AsyncSecretLoader.load(timeout: 2) {
                            [key.rawValue: try ProviderSecret.load(account: key.rawValue)]
                        }
                        return (key, result[key.rawValue])
                    } catch { return (key, nil) }
                }
            }
            for await (key, value) in group {
                guard let value else {
                    unavailable.insert(key)
                    continue
                }
                baseline[key] = value
                if values[key] == initial[key] { values[key] = value }
            }
        }
    }

    func save() async throws {
        let changes = CredentialPlan.Secret.allCases.compactMap { key -> (CredentialPlan.Secret, String)? in
            let value = values[key] ?? ""
            guard value != baseline[key], baseline[key] != nil || !value.isEmpty || edited.contains(key) else { return nil }
            return (key, value)
        }
        guard !changes.isEmpty else { return }
        saving = true
        defer { saving = false }
        // Update each baseline only after its write succeeds. A later failure
        // can be retried without pretending the remaining values were saved.
        for (key, value) in changes {
            try await Task.detached { try ProviderSecret.save(value, account: key.rawValue) }.value
            baseline[key] = value
            unavailable.remove(key)
            if values[key] == value { edited.remove(key) }
        }
    }
}
