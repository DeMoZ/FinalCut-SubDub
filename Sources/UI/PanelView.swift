import SwiftUI
import Translation
import UniformTypeIdentifiers

/// The panel shown inside Final Cut Pro (Window ▸ Extensions ▸ SubDub) and in the companion app.
struct PanelView: View {
    @StateObject private var job = SubtitleJob()
    @State private var dropTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                dropZone
                if job.project != nil {
                    sourcePicker
                    languageGrid
                    downloadNotice
                    actionArea
                }
            }
            .padding(16)
        }
        .frame(minWidth: 320, idealWidth: 380, minHeight: 420)
        .task { await job.loadLanguages() }
        .modifier(TranslationHost(broker: job.translator))
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "captions.bubble.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("SubDub").font(.headline)
                Text("Offline transcription & translation on this Mac").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: job.project == nil ? [6, 4] : []))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
                .background(RoundedRectangle(cornerRadius: 10).fill(dropTargeted ? Color.accentColor.opacity(0.12) : Color.clear))

            if let project = job.project {
                HStack(spacing: 10) {
                    Image(systemName: "film.stack").font(.title2).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name).font(.body.weight(.semibold)).lineLimit(2)
                        Text("Duration \(Self.format(project.duration)) · drop another project to replace")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc").font(.title)
                    Text("Drop a project here").font(.body.weight(.semibold))
                    Text("from the Final Cut Pro browser (or an .fcpxml file)")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = job.loadError {
                        Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                    }
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, minHeight: job.project == nil ? 130 : 64)
        .overlay(FCPXMLDropTarget(isTargeted: $dropTargeted) { job.load($0) })
        .disabled(job.isRunning)
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Spoken language").font(.subheadline.weight(.semibold))
            Picker("", selection: $job.sourceLocaleID) {
                ForEach(job.sourceLocales, id: \.self) { locale in
                    Text(Self.localeName(locale)).tag(locale.identifier(.bcp47))
                }
            }
            .labelsHidden()
            .disabled(job.isRunning)
        }
    }

    private var languageGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Subtitles").font(.subheadline.weight(.semibold))
            Toggle("Original (\(job.sourceLanguage.displayName))", isOn: $job.includeOriginal)
                .toggleStyle(.checkbox)
            Text("Translate to:").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(job.targetLanguages.filter { $0.code != job.sourceLanguage.code }) { lang in
                    LanguageChip(language: lang, isOn: job.selectedTargets.contains(lang.code)) {
                        job.toggle(lang)
                    }
                }
            }
            .disabled(job.isRunning)
        }
    }

    @ViewBuilder
    private var downloadNotice: some View {
        if !job.notDownloaded.isEmpty || job.downloadError != nil {
            VStack(alignment: .leading, spacing: 8) {
                if !job.notDownloaded.isEmpty {
                    Label("One-time download needed for offline translation: \(job.notDownloaded.map(\.displayName).joined(separator: ", "))",
                          systemImage: "arrow.down.circle")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = job.downloadError {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if let lang = job.downloadingLanguage {
                        ProgressView().controlSize(.small)
                        Text("Downloading \(lang)…").font(.caption)
                    } else if !job.notDownloaded.isEmpty {
                        Button("Download") { Task { await job.downloadMissing() } }
                    }
                    Spacer()
                    Button("Open Settings") { TranslationBroker.openTranslationSettings() }
                        .help("System Settings ▸ General ▸ Language & Region ▸ Translation Languages")
                    Button {
                        Task { await job.refreshDownloads() }
                    } label: { Image(systemName: "arrow.clockwise") }
                        .help("Check again")
                }
                .controlSize(.small)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            .disabled(job.isRunning)
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        switch job.phase {
        case .idle:
            startButton
        case .running(let step, let fraction):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: fraction)
                HStack {
                    Text(step).font(.callout)
                    Spacer()
                    Button("Cancel") { job.cancel() }
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                startButton
            }
        case .done(let result, let importError):
            DoneView(result: result, importError: importError, languages: languagesSummary) {
                job.start()
            }
        }
    }

    private var startButton: some View {
        Button {
            job.start()
        } label: {
            Label(startTitle, systemImage: "text.bubble")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .disabled(!job.canStart)
    }

    private var startTitle: String {
        let n = (job.includeOriginal ? 1 : 0) + job.effectiveTargets.count
        return n == 0 ? "Choose a language" : "Create Subtitles (\(languagesSummary))"
    }

    private var languagesSummary: String {
        var codes = job.includeOriginal ? [job.sourceLanguage.code] : []
        codes += job.effectiveTargets.map(\.code)
        return codes.joined(separator: ", ")
    }

    static func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func localeName(_ locale: Locale) -> String {
        let name = Locale(identifier: "en").localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

private struct LanguageChip: View {
    let language: SubtitleLanguage
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(language.displayName).font(.callout).lineLimit(1)
                    if language.nativeName.lowercased() != language.displayName.lowercased() {
                        Text(language.nativeName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(isOn ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(language.code)
    }
}

private struct DoneView: View {
    let result: PipelineResult
    let importError: String?
    let languages: String
    let regenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Done: \(result.cueCount) captions × \(result.srtURLs.count) language(s)", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.body.weight(.semibold))

            if let importError {
                Text("Couldn't open in Final Cut Pro automatically: \(importError). Drag the file below into the FCP browser.")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text("A copy of the project with captions was imported into Final Cut Pro. Toggle languages in Timeline Index ▸ Roles ▸ Captions.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ForEach(result.warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                Image(systemName: "doc.badge.arrow.up").font(.title3)
                VStack(alignment: .leading, spacing: 0) {
                    Text(result.fcpxmlURL.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                    Text("drag into Final Cut Pro manually").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.1)))
            .onDrag { NSItemProvider(contentsOf: result.fcpxmlURL) ?? NSItemProvider() }

            HStack {
                Button("Import Again") {
                    Task { try? await FinalCutBridge.importIntoFinalCut(result.fcpxmlURL) }
                }
                Button("Show in Finder") { FinalCutBridge.reveal(result.fcpxmlURL) }
                Spacer()
                Button("Redo", action: regenerate)
            }
            .controlSize(.small)
        }
    }
}
