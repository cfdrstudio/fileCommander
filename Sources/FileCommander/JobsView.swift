import SwiftUI

/// Toolbar button showing overall progress; opens the job list.
struct JobsButton: View {
    let center: JobCenter
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            if center.activeJobs.isEmpty {
                Label("Transfers", systemImage: "arrow.up.arrow.down.circle")
            } else {
                ZStack {
                    Circle().stroke(.tertiary, lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: center.overallFraction)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 16, height: 16)
            }
        }
        .help("Transfers")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            JobsList(center: center)
        }
        .onChange(of: center.activeJobs.count) { old, new in
            if new > old { showing = true }    // surface new transfers
        }
    }
}

struct JobsList: View {
    let center: JobCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transfers").font(.headline)
                Spacer()
                Button("Clear Finished") { center.clearFinished() }
                    .disabled(center.jobs.allSatisfy(\.isActive))
            }
            .padding(12)
            Divider()
            if center.jobs.isEmpty {
                Text("No transfers yet.").foregroundStyle(.secondary).padding(20)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(center.jobs) { job in
                            JobRow(job: job)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 400)
    }
}

struct JobRow: View {
    let job: FileJob

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(job.title).lineLimit(1).truncationMode(.middle)
                Spacer()
                controls
            }
            if job.isActive && job.isIndeterminate {
                ProgressView().progressViewStyle(.linear)
            } else if job.isActive {
                ProgressView(value: job.fraction)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            } else {
                Text(detail).font(.caption).foregroundStyle(statusColor).lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var controls: some View {
        switch job.state {
        case .running where job.isIndeterminate:
            EmptyView()     // zip tasks can't be paused or cancelled midway
        case .running, .scanning:
            iconButton("pause.fill", help: "Pause") { job.pause() }
            iconButton("xmark.circle.fill", help: "Cancel") { job.cancel() }
        case .paused:
            iconButton("play.fill", help: "Resume") { job.resume() }
            iconButton("xmark.circle.fill", help: "Cancel") { job.cancel() }
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .cancelled:
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(help)
    }

    private var detail: String {
        let f = FileOps.formatSize
        switch job.state {
        case .scanning:
            return "Preparing…"
        case .running where job.isIndeterminate:
            return "Working…"
        case .running, .paused:
            var s = job.totalBytes > 0
                ? "\(f(job.doneBytes)) of \(f(job.totalBytes))"
                : "\(job.doneFiles) of \(job.totalFiles) items"
            if job.state == .paused {
                s += " — Paused"
            } else if job.bytesPerSecond > 0 {
                s += " — \(f(Int64(job.bytesPerSecond)))/s"
                let remaining = Double(job.totalBytes - job.doneBytes) / job.bytesPerSecond
                if remaining > 2 { s += ", \(Self.duration(remaining)) left" }
            }
            if !job.currentName.isEmpty { s += " — \(job.currentName)" }
            return s
        case .done:
            return job.totalBytes > 0 ? "Done — \(f(job.totalBytes))" : "Done"
        case .cancelled:
            return "Cancelled"
        case .failed(let message):
            return message
        }
    }

    private var statusColor: Color {
        if case .failed = job.state { return .orange }
        return .secondary
    }

    private static func duration(_ s: Double) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = s > 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        return f.string(from: s) ?? ""
    }
}

/// Asks what to do when a copied/moved item already exists at the destination.
struct ConflictSheet: View {
    let job: FileJob
    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.on.doc").font(.largeTitle).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 6) {
                    Text("“\(job.conflict?.name ?? "")” already exists in “\(job.conflict?.destination ?? "")”.")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Replace moves the existing item to the Trash, so you can undo it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if job.items.count > 1 {
                Toggle("Apply to all remaining conflicts", isOn: $applyToAll)
            }
            HStack {
                Button("Stop", role: .cancel) { job.cancel() }
                Spacer()
                Button("Skip") { job.resolveConflict(.skip, applyToAll: applyToAll) }
                Button("Replace") { job.resolveConflict(.replace, applyToAll: applyToAll) }
                Button("Keep Both") { job.resolveConflict(.keepBoth, applyToAll: applyToAll) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
