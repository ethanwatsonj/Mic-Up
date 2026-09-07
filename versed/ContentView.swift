//
//  ContentView.swift
//  versed
//
//  Created by Ethan Watson on 4/24/26.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Speech

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Presentation.dateCreated, order: .reverse) private var presentations: [Presentation]
    @State private var showingImporter = false
    @State private var selectedPresentation: Presentation?
    @State private var renamingPresentation: Presentation?
    @State private var renameText = ""

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let selected = selectedPresentation {
                PresentationDetailView(presentation: selected)
                    .id(selected.id)
            } else {
                Color.black
                    .overlay {
                        ContentUnavailableView(
                            "No Presentation Selected",
                            systemImage: "play.rectangle",
                            description: Text("Import a video to get started with AI-powered speaking feedback.")
                        )
                        .foregroundStyle(.white.opacity(0.5))
                    }
            }

            sidebarOverlay
        }
        .background(.black)
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
    }

    // MARK: - Sidebar

    private var sidebarOverlay: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    Text("※")
                        .font(.hg(14, weight: .semibold))
                        .foregroundStyle(PrimaryColor.tone500)
                    Text("versed")
                        .font(.hg(14, weight: .semibold))
                        .foregroundStyle(PrimaryColor.tone500)
                }
                Spacer()
                Button(action: { showingImporter = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("Import Video")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(presentations) { presentation in
                        presentationRow(presentation)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }
        }
        .frame(width: 220, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func presentationRow(_ presentation: Presentation) -> some View {
        let isSelected = selectedPresentation == presentation

        return Button(action: { selectedPresentation = presentation }) {
            HStack(spacing: 8) {
                if renamingPresentation == presentation {
                    TextField("Title", text: $renameText, onCommit: {
                        presentation.title = renameText
                        renamingPresentation = nil
                    })
                    .font(.hg(14, weight: .regular))
                    .textFieldStyle(.plain)
                    .onExitCommand { renamingPresentation = nil }
                } else {
                    Text(presentation.title)
                        .font(.hg(14, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(.white.opacity(isSelected ? 0.9 : 0.45))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                if presentation.status == .transcribing || presentation.status == .analyzing || presentation.status == .importing {
                    ProgressView()
                        .controlSize(.mini)
                } else if presentation.status == .failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red.opacity(0.7))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? .white.opacity(0.1) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                renameText = presentation.title
                renamingPresentation = presentation
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) { deletePresentation(presentation) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Import & Processing

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }

        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        let fileName = "\(UUID().uuidString).\(url.pathExtension)"
        let destination = Presentation.videosDirectory.appendingPathComponent(fileName)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            print("Failed to copy video: \(error)")
            return
        }

        let title = url.deletingPathExtension().lastPathComponent
        let presentation = Presentation(title: title, videoFileName: fileName)
        modelContext.insert(presentation)
        selectedPresentation = presentation

        Task { await processPresentation(presentation) }
    }

    private func processPresentation(_ presentation: Presentation) async {
        guard let videoURL = presentation.videoURL else {
            presentation.errorMessage = "Could not resolve video file location."
            presentation.status = .failed
            return
        }

        presentation.status = .transcribing
        var wordSegments: [Any] = []
        do {
            let (transcript, segments, rawWords) = try await AnalysisService.shared.transcribe(videoURL: videoURL)
            presentation.transcript = transcript
            presentation.segments = segments
            wordSegments = rawWords
        } catch {
            presentation.errorMessage = "Transcription failed: \(error.localizedDescription)"
            presentation.status = .failed
            return
        }

        guard !presentation.transcript.isEmpty else {
            presentation.errorMessage = "No speech detected in this video."
            presentation.status = .failed
            return
        }

        if let title = try? await AnalysisService.shared.generateTitle(from: presentation.transcript) {
            presentation.title = title
        }

        presentation.status = .analyzing

        if let rawWordSegments = wordSegments as? [SFTranscriptionSegment] {
            let speechMetrics = await AnalysisService.shared.computeSpeechMetrics(
                wordSegments: rawWordSegments,
                segments: presentation.segments
            )
            presentation.speechMetrics = speechMetrics
        }

        var visualMetrics: VisualMetrics?
        do {
            visualMetrics = try await AnalysisService.shared.analyzeVideo(
                url: videoURL,
                segments: presentation.segments
            )
            presentation.visualMetrics = visualMetrics
        } catch {
            print("Visual analysis failed (non-fatal): \(error)")
        }

        do {
            let analysis = try await AnalysisService.shared.analyze(
                segments: presentation.segments,
                speechMetrics: presentation.speechMetrics,
                visualMetrics: visualMetrics
            )
            presentation.analysis = analysis
            presentation.status = .ready
        } catch {
            presentation.errorMessage = "Analysis failed: \(error.localizedDescription)"
            presentation.status = .failed
        }
    }

    private func deletePresentation(_ presentation: Presentation) {
        if let videoURL = presentation.videoURL {
            try? FileManager.default.removeItem(at: videoURL)
        }
        if selectedPresentation == presentation {
            selectedPresentation = nil
        }
        modelContext.delete(presentation)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Presentation.self, inMemory: true)
}
