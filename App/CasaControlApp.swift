import SwiftUI
import Security

struct Device: Identifiable {
    let id: String
    let name: String
    let on: Bool
    let available: Bool
    let brightness: Int?
}

enum ConnectionError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

enum Vault {
    static let service = "it.casacontrol.credentials"
    static func read() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "token",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ value: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "token"]
        let attrs: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(query.merging(attrs) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw ConnectionError.message("Impossibile salvare il token nel Portachiavi.") }
        } else if status != errSecSuccess {
            throw ConnectionError.message("Impossibile aggiornare il token nel Portachiavi.")
        }
    }
}

@MainActor final class Store: ObservableObject {
    @Published var devices: [Device] = []
    @Published var busy = false
    @Published var error: String?
    @Published var endpoint = UserDefaults.standard.string(forKey: "endpoint") ?? ""
    @Published var mode = UserDefaults.standard.string(forKey: "mode") ?? "tapo"
    @Published var token = Vault.read()

    func save() throws {
        try Vault.save(token)
        UserDefaults.standard.set(endpoint, forKey: "endpoint")
        UserDefaults.standard.set(mode, forKey: "mode")
        devices = []
    }
    func request(_ path: String, body: [String: Any]? = nil) async throws -> Data {
        guard let base = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(base.scheme?.lowercased() ?? ""),
              base.host != nil, base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConnectionError.message("Inserisci un URL http/https e un token validi.")
        }
        let url = base.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let response = response as? HTTPURLResponse else { throw ConnectionError.message("Risposta non valida.") }
        guard (200..<300).contains(response.statusCode) else {
            throw ConnectionError.message(response.statusCode == 401 ? "Token non valido." : "Il servizio ha risposto con errore \(response.statusCode).")
        }
        return data
    }
    func fetch() async throws {
        let data = try await request(mode == "tapo" ? "devices" : "api/states")
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ConnectionError.message("Formato dei dispositivi non valido.")
        }
        devices = items.compactMap { item in
            if mode == "tapo" {
                guard let id = item["id"] as? String else { return nil }
                return Device(id: id, name: item["name"] as? String ?? id,
                    on: item["on"] as? Bool ?? false, available: item["available"] as? Bool ?? false,
                    brightness: item["brightness"] as? Int)
            }
            guard let id = item["entity_id"] as? String,
                  ["light", "switch", "fan", "input_boolean"].contains(String(id.split(separator: ".").first ?? "")) else { return nil }
            let attrs = item["attributes"] as? [String: Any] ?? [:]
            let state = item["state"] as? String ?? "unknown"
            return Device(id: id, name: attrs["friendly_name"] as? String ?? id,
                on: state == "on", available: !["unknown", "unavailable"].contains(state),
                brightness: (attrs["brightness"] as? Int).map { Int(Double($0) / 255 * 100) })
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    func refresh() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do { try await fetch() } catch { self.error = error.localizedDescription }
    }
    func set(_ device: Device, on: Bool) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            if mode == "tapo" {
                _ = try await request("devices/\(device.id)/power", body: ["on": on])
            } else {
                let domain = String(device.id.split(separator: ".").first ?? "switch")
                _ = try await request("api/services/\(domain)/turn_\(on ? "on" : "off")", body: ["entity_id": device.id])
            }
            try await fetch()
        } catch { self.error = error.localizedDescription }
    }
}

@main struct CasaControlApp: App {
    var body: some Scene { WindowGroup { Dashboard() } }
}

struct Dashboard: View {
    @StateObject private var store = Store()
    @State private var settings = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(store.mode == "tapo" ? "Tapo · servizio locale" : "Home Assistant", systemImage: "house.fill")
                        .foregroundStyle(.teal)
                    if store.busy { ProgressView("Connessione…") }
                    if let error = store.error { Text(error).foregroundStyle(.red) }
                }
                if store.devices.isEmpty && !store.busy {
                    Section { Text("Configura la connessione, poi aggiorna per trovare i dispositivi.").foregroundStyle(.secondary) }
                }
                ForEach(store.devices) { device in
                    HStack {
                        Image(systemName: device.brightness == nil ? "powerplug.fill" : "lightbulb.fill")
                            .foregroundStyle(device.on ? .orange : .secondary)
                        VStack(alignment: .leading) {
                            Text(device.name)
                            Text(device.available ? (device.on ? "Acceso" : "Spento") : "Non disponibile")
                                .font(.caption).foregroundStyle(.secondary)
                            if let brightness = device.brightness { Text("Luminosità \(brightness)%").font(.caption) }
                        }
                        Spacer()
                        Toggle("Accendi \(device.name)", isOn: Binding(get: { device.on }, set: { value in
                            Task { await store.set(device, on: value) }
                        })).labelsHidden().disabled(store.busy || !device.available)
                    }
                }
            }
            .navigationTitle("Casa Control")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button { settings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Impostazioni") }
                ToolbarItem(placement: .navigationBarTrailing) { Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }.disabled(store.busy).accessibilityLabel("Aggiorna") }
            }
            .refreshable { await store.refresh() }
            .sheet(isPresented: $settings) { Settings(store: store) }
            .task { if !store.endpoint.isEmpty { await store.refresh() } }
        }
        .tint(.teal)
    }
}

struct Settings: View {
    @ObservedObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint = ""
    @State private var token = ""
    @State private var mode = "tapo"
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Servizio") {
                    Picker("Connessione", selection: $mode) {
                        Text("Tapo locale").tag("tapo")
                        Text("Home Assistant").tag("ha")
                    }
                    TextField("URL del servizio", text: $endpoint)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("Token di accesso", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Text(mode == "tapo" ? "Avvia il bridge incluso nel progetto sulla stessa rete dei dispositivi. Usa il suo URL e BRIDGE_TOKEN." : "Usa l’URL di Home Assistant e un token di accesso a lunga durata. Tapo e Smart Life/Tuya richiedono le rispettive integrazioni in Home Assistant.")
                    Text("Per HTTP locale usa un nome .local; per altri indirizzi usa HTTPS con certificato valido. Il token è conservato nel Portachiavi iOS.")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Connessione")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Salva") {
                    guard !store.busy else { return }
                    let old = (store.endpoint, store.token, store.mode)
                    store.endpoint = endpoint; store.token = token; store.mode = mode
                    do { try store.save(); dismiss(); Task { await store.refresh() } }
                    catch { store.endpoint = old.0; store.token = old.1; store.mode = old.2; self.error = error.localizedDescription }
                }.disabled(store.busy) }
            }
            .onAppear { endpoint = store.endpoint; token = store.token; mode = store.mode }
        }
    }
}
