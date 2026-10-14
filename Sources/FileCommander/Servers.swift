import NetFS
import SwiftUI

/// A server in the sidebar: either mounted by macOS (SMB/AFP/NFS/WebDAV) or browsed over SFTP.
struct SavedServer: Codable, Hashable, Identifiable {
    enum Kind: Codable, Hashable {
        case mount(String)          // e.g. smb://nas.local/share
        case sftp(SFTPServer)
    }

    var kind: Kind

    var id: String {
        switch kind {
        case .mount(let u): return u
        case .sftp(let s): return "sftp://" + s.target
        }
    }

    var name: String {
        switch kind {
        case .mount(let u): return URL(string: u).map { ($0.host ?? u) + $0.path } ?? u
        case .sftp(let s): return s.label
        }
    }

    var symbol: String {
        if case .sftp = kind { return "lock.shield" }
        return "externaldrive.connected.to.line.below"
    }
}

/// Mounts network shares through macOS (NetFS). macOS shows its own sign-in / Keychain
/// prompt when needed, so the app never sees passwords.
enum ServerMounter {
    struct MountError: LocalizedError {
        let code: Int32
        var errorDescription: String? {
            switch code {
            case ECANCELED, Int32(-128): return "Connection cancelled."
            case EAUTH, EPERM, EACCES: return "The server didn't accept the sign-in."
            case ENOENT: return "That share doesn't exist on the server."
            case EHOSTUNREACH, ENETUNREACH, ETIMEDOUT: return "Can't reach the server."
            default: return "Couldn't connect (error \(code))."
            }
        }
    }

    /// Builds a mount URL from user input like "nas.local/share" + protocol, or a full URL.
    static func makeURL(scheme: String, address: String) -> URL? {
        var a = address.trimmingCharacters(in: .whitespaces)
        if a.contains("://") { return URL(string: a) }
        while a.hasPrefix("/") { a.removeFirst() }
        guard !a.isEmpty else { return nil }
        return URL(string: "\(scheme)://\(a)")
    }

    @MainActor
    static func mount(_ urlString: String, completion: @escaping @MainActor (Result<URL, Error>) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(.failure(MountError(code: EINVAL)))
            return
        }
        let open = NSMutableDictionary()
        open[kNAUIOptionKey] = kNAUIOptionAllowUI          // let macOS ask for credentials
        var request: AsyncRequestID?
        let rc = NetFSMountURLAsync(url as CFURL, nil, nil, nil, open, nil, &request, DispatchQueue.main) { status, _, mountpoints in
            MainActor.assumeIsolated {
                if status == 0 || status == EEXIST,
                   let path = (mountpoints as? [String])?.first {
                    completion(.success(URL(fileURLWithPath: path)))
                } else if status == 0 || status == EEXIST {
                    // Already mounted: find it among the mounted volumes.
                    let match = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeURLForRemountingKey])?
                        .first { (try? $0.resourceValues(forKeys: [.volumeURLForRemountingKey]))?.volumeURLForRemounting?.host == url.host }
                    if let match { completion(.success(match)) } else { completion(.failure(MountError(code: ENOENT))) }
                } else {
                    completion(.failure(MountError(code: status)))
                }
            }
        }
        if rc != 0 && rc != EINPROGRESS {
            completion(.failure(MountError(code: rc)))
        }
    }
}

struct ConnectSheet: View {
    enum Proto: String, CaseIterable, Identifiable {
        case smb = "SMB (Windows / NAS)", afp = "AFP", nfs = "NFS", webdav = "WebDAV (https)", sftp = "SFTP (SSH)"
        var id: String { rawValue }
        var scheme: String {
            switch self {
            case .smb: return "smb"
            case .afp: return "afp"
            case .nfs: return "nfs"
            case .webdav: return "https"
            case .sftp: return "sftp"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var proto: Proto = .smb
    @State private var address = ""
    @State private var user = ""
    @State private var port = ""
    @State private var remotePath = ""
    @State private var identity = ""
    @State private var connecting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect to Server").font(.title3.bold())
            Form {
                Picker("Protocol", selection: $proto) {
                    ForEach(Proto.allCases) { Text($0.rawValue).tag($0) }
                }
                if proto == .sftp {
                    TextField("Host", text: $address, prompt: Text("server.example.com"))
                    TextField("User", text: $user, prompt: Text("optional (uses ~/.ssh/config)"))
                    TextField("Port", text: $port, prompt: Text("22"))
                    TextField("Folder", text: $remotePath, prompt: Text("optional, e.g. /var/www"))
                    HStack {
                        TextField("Key file", text: $identity, prompt: Text("optional, e.g. ~/.ssh/id_ed25519"))
                        Button("Choose…", action: chooseKey)
                    }
                    Text("Signs in with SSH keys (ssh-agent, ~/.ssh/config or the key file). The server's host key must already be trusted — connect once with `ssh` in Terminal if it's new.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("Server", text: $address, prompt: Text("nas.local/share  or  \(proto.scheme)://…"))
                    Text("macOS mounts the share and asks for your name and password itself (and can keep them in your Keychain). It then appears under Locations.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if connecting { ProgressView().controlSize(.small); Text("Connecting…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || connecting)
            }
        }
        .padding(18)
        .frame(width: 520)
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { identity = url.path }
    }

    private func connect() {
        error = nil
        let server: SavedServer
        if proto == .sftp {
            let host = address.trimmingCharacters(in: .whitespaces)
            server = SavedServer(kind: .sftp(SFTPServer(
                user: user.trimmingCharacters(in: .whitespaces), host: host, port: Int(port),
                path: remotePath.trimmingCharacters(in: .whitespaces), identityFile: identity)))
        } else {
            guard let url = ServerMounter.makeURL(scheme: proto.scheme, address: address) else {
                error = "That doesn't look like a server address."
                return
            }
            server = SavedServer(kind: .mount(url.absoluteString))
        }
        connecting = true
        model.connect(server) { message in
            connecting = false
            if let message { error = message } else { dismiss() }
        }
    }
}
