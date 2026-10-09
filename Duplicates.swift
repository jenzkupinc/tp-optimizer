import SwiftUI
import AppKit
import CryptoKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

struct DupFile: Identifiable {
    let id = UUID()
    let url: URL
    let size: Int64
    let date: Date
    var selected = false
}

struct DupGroup: Identifiable {
    let id = UUID()
    var files: [DupFile]
    var waste: Int64 { files.first.map { $0.size * Int64(files.count - 1) } ?? 0 }
    var keepsOne: Bool { files.contains { !$0.selected } }
}

enum FileKind: String, CaseIterable {
    case all = "Todo", photos = "Fotos", videos = "Videos", audio = "Audio", docs = "Documentos"
    func matches(_ url: URL) -> Bool {
        guard self != .all, let t = UTType(filenameExtension: url.pathExtension) else { return self == .all }
        switch self {
        case .photos: return t.conforms(to: .image)
        case .videos: return t.conforms(to: .movie) || t.conforms(to: .video)
        case .audio: return t.conforms(to: .audio)
        case .docs: return t.conforms(to: .pdf) || t.conforms(to: .presentation) || t.conforms(to: .spreadsheet) || t.conforms(to: .text) || ["doc", "docx", "pages", "key", "numbers"].contains(url.pathExtension.lowercased())
        case .all: return true
        }
    }
}

@MainActor
final class Duplicates: ObservableObject {
    @Published var roots: [URL] = [URL(fileURLWithPath: NSHomeDirectory())]
    @Published var kind: FileKind = .all
    @Published var groups: [DupGroup] = []
    @Published var scanning = false
    @Published var status = ""

    var selectedSize: Int64 { groups.flatMap(\.files).filter(\.selected).reduce(0) { $0 + $1.size } }
    var selectedCount: Int { groups.flatMap(\.files).filter(\.selected).count }
    var everyGroupKeepsOne: Bool { groups.allSatisfy(\.keepsOne) }

    func addFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = true
        if p.runModal() == .OK { roots.append(contentsOf: p.urls.filter { !roots.contains($0) }) }
    }

    func scan() {
        scanning = true
        groups = []
        let roots = roots, kind = kind
        Task.detached {
            let result = Duplicates.find(roots: roots, kind: kind) { msg in Task { @MainActor in self.status = msg } }
            await MainActor.run {
                self.groups = result
                self.scanning = false
                self.status = result.isEmpty ? "No hay duplicados." : "\(result.count) grupos · se pueden recuperar \(formatBytes(result.reduce(0) { $0 + $1.waste }))"
            }
        }
    }

    nonisolated static func find(roots: [URL], kind: FileKind, progress: @escaping (String) -> Void) -> [DupGroup] {
        let skip: Set<String> = ["Library", "node_modules", ".venv", "venv", ".git", ".Trash", "__pycache__", ".cache", ".next", "DerivedData"]
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var bySize: [Int64: [DupFile]] = [:]
        var count = 0
        for root in roots {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e {
                if skip.contains(url.lastPathComponent) { e.skipDescendants(); continue }
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, v.isSymbolicLink != true,
                      let size = v.fileSize, size >= 256_000, kind.matches(url) else { continue }
                bySize[Int64(size), default: []].append(DupFile(url: url, size: Int64(size), date: v.contentModificationDate ?? .distantPast))
                count += 1
                if count % 2000 == 0 { progress("Revisados \(count) archivos…") }
            }
        }
        var groups: [DupGroup] = []
        let candidates = bySize.values.filter { $0.count > 1 }
        for (i, files) in candidates.enumerated() {
            if i % 50 == 0 { progress("Comparando contenido \(i) de \(candidates.count)…") }
            var byQuick: [String: [DupFile]] = [:]
            for f in files { if let h = hash(f.url, quick: true) { byQuick[h, default: []].append(f) } }
            for same in byQuick.values where same.count > 1 {
                var byFull: [String: [DupFile]] = [:]
                for f in same { if let h = hash(f.url, quick: false) { byFull[h, default: []].append(f) } }
                for dup in byFull.values where dup.count > 1 {
                    var sorted = dup.sorted { $0.date < $1.date }
                    for j in sorted.indices.dropFirst() { sorted[j].selected = true }
                    groups.append(DupGroup(files: sorted))
                }
            }
        }
        return groups.sorted { $0.waste > $1.waste }
    }

    nonisolated static func hash(_ url: URL, quick: Bool) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var sha = SHA256()
        let chunk = 1 << 20
        if quick {
            let end = (try? h.seekToEnd()) ?? 0
            for offset in [0, end / 2, end > UInt64(chunk) ? end - UInt64(chunk) : 0] {
                try? h.seek(toOffset: offset)
                if let d = try? h.read(upToCount: chunk) { sha.update(data: d) }
            }
        } else {
            while let d = try? h.read(upToCount: chunk), !d.isEmpty { sha.update(data: d) }
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func removeSelected() async {
        guard everyGroupKeepsOne else { status = "Hay un grupo con todas sus copias marcadas: desmarca una para no perder el archivo."; return }
        let urls = groups.flatMap(\.files).filter(\.selected).map(\.url)
        guard !urls.isEmpty else { return }
        let moved = await recycle(urls)
        status = moved == urls.count
            ? "\(plural(moved, "duplicado", "duplicados")) en la Papelera."
            : "Pude mover \(moved) de \(urls.count). Los demás siguen donde estaban."
        record("Mandé \(plural(moved, "duplicado", "duplicados")) a la Papelera (de \(urls.count) marcados)")
        groups = groups.compactMap { g in
            let rest = g.files.filter { !urls.contains($0.url) }
            return rest.count > 1 ? DupGroup(files: rest) : nil
        }
    }
}

struct Thumb: View {
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable() }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: url) {
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 88, height: 88), scale: 2, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req).nsImage
        }
    }
}

struct DuplicatesView: View {
    @ObservedObject var d: Duplicates
    @State private var confirmMove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Header(title: "Duplicados", subtitle: "Encuentra copias idénticas por su contenido, no por su nombre. Conserva el original, marca lo demás.")
            HStack {
                ForEach(d.roots, id: \.self) { r in
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        Text(r.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1)
                        Button { d.roots.removeAll { $0 == r } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("Quitar esta carpeta de la búsqueda")
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.brandTeal.opacity(0.14)))
                    .help(r.path)
                }
                Button { d.addFolder() } label: { Label("Carpeta", systemImage: "plus") }.help("Agregar otra carpeta donde buscar")
                if FileManager.default.fileExists(atPath: "/Volumes/Respaldo"), !d.roots.contains(URL(fileURLWithPath: "/Volumes/Respaldo")) {
                    Button { d.roots.append(URL(fileURLWithPath: "/Volumes/Respaldo")) } label: { Label("SSD", systemImage: "externaldrive") }.help("Buscar también en el disco de respaldo")
                }
            }
            HStack {
                Picker("", selection: $d.kind) { ForEach(FileKind.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented).frame(maxWidth: 420).labelsHidden().help("Qué tipo de archivos comparar")
                Spacer()
                Button { d.scan() } label: { Label("Buscar duplicados", systemImage: "doc.on.doc") }
                    .buttonStyle(PrimaryButton()).disabled(d.scanning || d.roots.isEmpty).help("Compara el contenido de cada archivo. En carpetas grandes puede tardar varios minutos")
            }
            HStack { if d.scanning { ProgressView().controlSize(.small) }; Text(d.status).foregroundStyle(.secondary) }
            if d.groups.isEmpty {
                Placeholder(symbol: "doc.on.doc", text: "Elige carpetas y toca Buscar duplicados")
            } else {
                List {
                    ForEach($d.groups) { $g in
                        Section("\(g.files.count) copias · sobran \(formatBytes(g.waste))") {
                            ForEach($g.files) { $f in
                                HStack(spacing: 10) {
                                    Toggle("", isOn: $f.selected).labelsHidden().help(f.selected ? "Marcada para ir a la Papelera" : "Se queda")
                                    Thumb(url: f.url)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(f.url.lastPathComponent).fontWeight(.medium).lineLimit(1)
                                        Text(f.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    Text(f.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                                    Text(formatBytes(f.size)).monospacedDigit()
                                        .help("\(f.url.path)\nModificado: \(f.date.formatted(date: .long, time: .shortened))")
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([f.url]) } label: { Image(systemName: "eye") }.buttonStyle(.plain).help("Mostrar en Finder")
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                HStack {
                    Text("Seleccionado: \(formatBytes(d.selectedSize))").fontWeight(.medium)
                    Spacer()
                    Button("Mover copias a la Papelera") { confirmMove = true }
                        .buttonStyle(PrimaryButton()).disabled(d.selectedSize == 0 || !d.everyGroupKeepsOne)
                        .help(d.everyGroupKeepsOne ? "Mueve las copias marcadas a la Papelera. En cada grupo queda al menos una" : "Un grupo tiene todas sus copias marcadas: desmarca una")
                }
            }
        }
        .padding()
        .confirmationDialog("¿Mover \(d.selectedCount) copias (\(formatBytes(d.selectedSize))) a la Papelera?", isPresented: $confirmMove) {
            Button("Mover a la Papelera") { Task { await d.removeSelected() } }
        } message: { Text("Podrás recuperarlas desde la Papelera. En cada grupo se queda al menos una copia.") }
    }
}
