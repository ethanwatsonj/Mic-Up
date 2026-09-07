//
//  PresentationDetailView.swift
//  versed
//
//  Created by Ethan Watson on 4/24/26.
//

import SwiftUI
import AVKit

// MARK: - Main Detail View

struct PresentationDetailView: View {
    let presentation: Presentation
    @State private var player: AVPlayer?
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 1
    @State private var isPlaying = false
    @State private var timeObserver: Any?
    @State private var videoEnded = false

    var body: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: 220)

            ZStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if presentation.status == .ready, let analysis = presentation.analysis {
                            overallFeedbackSection(analysis)
                        }

                        videoPlayerSection

                        if presentation.status == .ready, let analysis = presentation.analysis {
                            feedbackContent(analysis)
                        }
                    }
                    .frame(maxWidth: 800)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }

                if presentation.status != .ready {
                    statusOverlay
                }
            }
        }
        .background(Color.black)
        .focusable()
        .onKeyPress(.space) {
            handleSpacebar()
            return .handled
        }
        .task(id: presentation.videoFileName) {
            player?.pause()
            removeTimeObserver()
            player = nil
            currentTime = 0
            duration = 1
            isPlaying = false
            videoEnded = false
            loadPlayer()
        }
        .onDisappear {
            player?.pause()
            removeTimeObserver()
        }
    }

    // MARK: - Video

    private var videoPlayerSection: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.04))
            }
            .overlay {
                if let player {
                    GeometryReader { geo in
                        PlayerView(player: player)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .onTapGesture { handleSpacebar() }
                            .overlay {
                                if videoEnded {
                                    VStack(spacing: 8) {
                                        Image(systemName: "arrow.counterclockwise.circle.fill")
                                            .font(.system(size: 56))
                                            .foregroundStyle(.white.opacity(0.7))
                                        Text("Press Space to replay")
                                            .font(.hg(14))
                                            .foregroundStyle(.white.opacity(0.4))
                                    }
                                    .allowsHitTesting(false)
                                } else if !isPlaying, presentation.status == .ready {
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 56))
                                        .foregroundStyle(.white.opacity(0.7))
                                        .allowsHitTesting(false)
                                }
                            }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func overallFeedbackSection(_ analysis: PresentationAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(presentation.title)
                .font(.hgHeading1)
                .foregroundStyle(.white.opacity(0.9))

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(analysis.overallScore)")
                    .font(.hg(28, weight: .semibold))
                    .foregroundStyle(PrimaryColor.tone500)
                Text("/10")
                    .font(.hg(18, weight: .regular))
                    .foregroundStyle(.white.opacity(0.3))
            }

            Text(analysis.summary)
                .hgBodyStyle()
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Feedback & Controls

    private func feedbackContent(_ analysis: PresentationAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            playControls(analysis)

            if let note = noteForCurrentTime(analysis) {
                tipRow(note)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: noteForCurrentTime(analysis)?.id)
    }

    private func playControls(_ analysis: PresentationAnalysis) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: togglePlayback) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.callout)
                    .foregroundStyle(.white)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)

            Text(formatTime(currentTime))
                .font(.hg(14).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 36, alignment: .trailing)

            TimelineTrack(
                currentTime: currentTime,
                duration: duration,
                notes: analysis.feedbackNotes,
                segments: presentation.segments,
                onSeek: { seekTo($0) }
            )

            Text(formatTime(duration))
                .font(.hg(14).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 36, alignment: .leading)
        }
    }

    private func tipRow(_ note: FeedbackNote) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(note.title)
                    .hgLabelStyle()
                    .foregroundStyle(.white.opacity(0.9))

                Text(note.theme.label)
                    .hgLabelStyle()
                    .foregroundStyle(PrimaryColor.tone500)
            }

            Text(note.detail)
                .hgBodyStyle()
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .id(note.id)
    }

    private func noteForCurrentTime(_ analysis: PresentationAnalysis) -> FeedbackNote? {
        guard let activeSegment = presentation.segments.first(where: {
            currentTime >= $0.startTime && currentTime < $0.endTime
        }) else { return nil }

        return analysis.feedbackNotes.first { $0.segmentIndex == activeSegment.index }
    }

    // MARK: - Player Management

    private func loadPlayer() {
        guard let url = presentation.videoURL else { return }
        let avPlayer = AVPlayer(url: url)
        player = avPlayer
        setupTimeObserver(for: avPlayer)

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: avPlayer.currentItem,
            queue: .main
        ) { _ in
            videoEnded = true
            isPlaying = false
        }

        Task {
            guard let item = avPlayer.currentItem else { return }
            let dur = try? await item.asset.load(.duration)
            if let dur, dur.isValid && !dur.isIndefinite {
                await MainActor.run { duration = dur.seconds }
            }
        }
    }

    private func setupTimeObserver(for avPlayer: AVPlayer) {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            currentTime = time.seconds
            isPlaying = avPlayer.timeControlStatus == .playing
        }
    }

    private func removeTimeObserver() {
        if let observer = timeObserver, let player {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
    }

    private func handleSpacebar() {
        guard let player else { return }
        if videoEnded {
            seekTo(0)
            videoEnded = false
            player.play()
            isPlaying = true
        } else {
            togglePlayback()
        }
    }

    private func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
        isPlaying = player.timeControlStatus == .playing
    }

    private func seekTo(_ time: TimeInterval) {
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite else { return "0:00" }
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Status Overlay

    private var statusOverlay: some View {
        VStack(spacing: 16) {
            switch presentation.status {
            case .importing:
                ProgressView("Importing...").foregroundStyle(.white)
            case .transcribing:
                ProgressView("Transcribing speech...").foregroundStyle(.white)
                Text("This may take a moment depending on the video length.")
                    .font(.hg(14)).foregroundStyle(.white.opacity(0.4))
            case .analyzing:
                ProgressView("AI is analyzing your presentation...").foregroundStyle(.white)
                Text("Generating feedback and suggestions.")
                    .font(.hg(14)).foregroundStyle(.white.opacity(0.4))
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 32)).foregroundStyle(.red)
                Text("Analysis Failed").font(.hg(18, weight: .medium)).foregroundStyle(.white)
                Text(presentation.errorMessage ?? "There was an error processing this video.")
                    .font(.hg(14)).foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center).textSelection(.enabled).padding(.horizontal)
            case .ready:
                EmptyView()
            }
        }
        .frame(maxWidth: 800)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(Color.black.opacity(0.75))
    }
}

// MARK: - AVPlayer NSView Wrapper

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        view.showsSharingServiceButton = false
        view.updatesNowPlayingInfoCenter = false
        view.player = player
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

// MARK: - Timeline Track

struct TimelineTrack: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let notes: [FeedbackNote]
    let segments: [TranscriptSegment]
    let onSeek: (TimeInterval) -> Void

    private let segmentGap: CGFloat = 4
    private let trackHeight: CGFloat = 22

    private var progress: CGFloat {
        guard duration > 0 else { return 0 }
        return min(max(CGFloat(currentTime / duration), 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let layouts = chunkLayouts(in: width)

            ZStack(alignment: .leading) {
                trackRow(layouts: layouts, width: width)
                playhead(width: width)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = max(0, min(value.location.x / width, 1))
                        onSeek(Double(fraction) * duration)
                    }
            )
        }
        .frame(height: trackHeight)
    }

    private func trackRow(layouts: [ChunkLayout], width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(0.08))
                .frame(width: width, height: trackHeight)

            ForEach(layouts) { layout in
                let active = isActive(layout.chunk)

                RoundedRectangle(cornerRadius: 5)
                    .fill(layout.chunk.note.theme.color.opacity(active ? 1 : 0.55))
                    .overlay {
                        if layout.width >= 44 {
                            Text(layout.chunk.note.theme.label)
                                .font(.hg(11, weight: active ? .semibold : .medium))
                                .foregroundStyle(Color.black.opacity(active ? 0.72 : 0.55))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .padding(.horizontal, 4)
                        }
                    }
                    .frame(width: layout.width, height: trackHeight)
                    .offset(x: layout.startX)
                    .onTapGesture { onSeek(layout.chunk.startTime) }
            }
        }
        .frame(width: width, height: trackHeight)
    }

    private func playhead(width: CGFloat) -> some View {
        Rectangle()
            .fill(.white.opacity(0.85))
            .frame(width: 2, height: trackHeight)
            .offset(x: width * progress - 1)
            .allowsHitTesting(false)
    }

    private func chunkLayouts(in width: CGFloat) -> [ChunkLayout] {
        feedbackChunks
            .sorted { $0.startTime < $1.startTime }
            .map { chunk in
                let startX = timeToX(chunk.startTime, in: width)
                let endX = timeToX(chunk.endTime, in: width)
                let rawWidth = max(endX - startX, 0)
                let inset = rawWidth > segmentGap ? segmentGap : 0
                let layoutWidth = max(rawWidth - inset, 6)
                let layoutStart = startX + inset / 2

                return ChunkLayout(
                    chunk: chunk,
                    startX: layoutStart,
                    width: layoutWidth
                )
            }
    }

    private func isActive(_ chunk: FeedbackChunk) -> Bool {
        currentTime >= chunk.startTime && currentTime < chunk.endTime
    }

    private func timeToX(_ time: TimeInterval, in width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(time / duration) * width
    }

    private var feedbackChunks: [FeedbackChunk] {
        let noteBySegment = Dictionary(
            notes.map { ($0.segmentIndex, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return noteBySegment.compactMap { segmentIndex, note in
            guard let segment = segments.first(where: { $0.index == segmentIndex }) else { return nil }
            return FeedbackChunk(
                segmentIndex: segmentIndex,
                startTime: segment.startTime,
                endTime: segment.endTime,
                note: note
            )
        }
    }
}

private struct ChunkLayout: Identifiable {
    let chunk: FeedbackChunk
    let startX: CGFloat
    let width: CGFloat

    var id: Int { chunk.segmentIndex }
}

private struct FeedbackChunk {
    let segmentIndex: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let note: FeedbackNote
}
