//
//  AnalysisService.swift
//  versed
//
//  Created by Ethan Watson on 4/24/26.
//

import Foundation
import Speech
import FoundationModels
import Vision
import AVFoundation

// MARK: - Generable types for structured AI output

@Generable(description: "Speaking and presentation feedback analysis")
struct GeneratedAnalysis {
    @Guide(description: "Overall presentation score", .range(1...10))
    var overallScore: Int

    @Guide(description: "A 1-2 sentence summary of the presentation quality")
    var summary: String

    @Guide(description: "Specific feedback notes", .maximumCount(10))
    var notes: [GeneratedNote]
}

@Generable(description: "A feedback note about a specific part of the speech")
struct GeneratedNote {
    @Guide(description: "The segment number this feedback refers to", .range(0...100))
    var segmentNumber: Int

    var category: NoteCategory

    @Guide(description: "Short title, 2-5 words")
    var title: String

    @Guide(description: "In-depth actionable feedback in 2-3 sentences explaining the issue, why it matters, and how to improve")
    var detail: String

    var type: NoteType
}

@Generable
enum NoteCategory: String {
    case delivery
    case clarity
    case structure
    case presence
    case language
}

@Generable
enum NoteType: String {
    case strength
    case improvement
}

// MARK: - Analysis Service

actor AnalysisService {
    static let shared = AnalysisService()

    private let chunkDuration: TimeInterval = 15.0

    private let fillerWordSet: Set<String> = [
        "um", "uh", "uhh", "umm", "er", "err", "ah", "ahh",
        "like", "basically", "actually", "literally", "right",
        "you know", "i mean", "sort of", "kind of"
    ]

    // MARK: Transcription

    func transcribe(videoURL: URL) async throws -> (String, [TranscriptSegment], [SFTranscriptionSegment]) {
        let authorized = await requestSpeechAuthorization()
        guard authorized else {
            throw AnalysisError.speechNotAuthorized
        }

        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw AnalysisError.speechNotAvailable
        }

        let request = SFSpeechURLRecognitionRequest(url: videoURL)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = false

        let transcription: SFTranscription = try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !hasResumed else { return }
                if let error {
                    hasResumed = true
                    continuation.resume(throwing: error)
                    return
                }
                guard let result else { return }
                if result.isFinal {
                    hasResumed = true
                    continuation.resume(returning: result.bestTranscription)
                }
            }
        }

        let segments = buildSegments(from: transcription)
        return (transcription.formattedString, segments, Array(transcription.segments))
    }

    private func buildSegments(from transcription: SFTranscription) -> [TranscriptSegment] {
        let wordSegments = transcription.segments
        guard !wordSegments.isEmpty else { return [] }

        var chunks: [TranscriptSegment] = []
        var currentWords: [String] = []
        var chunkStart: TimeInterval = wordSegments[0].timestamp
        var chunkEnd: TimeInterval = chunkStart
        var chunkIndex = 0

        for word in wordSegments {
            let wordEnd = word.timestamp + word.duration

            if word.timestamp - chunkStart >= chunkDuration && !currentWords.isEmpty {
                chunks.append(TranscriptSegment(
                    index: chunkIndex,
                    startTime: chunkStart,
                    endTime: chunkEnd,
                    text: currentWords.joined(separator: " ")
                ))
                chunkIndex += 1
                currentWords = []
                chunkStart = word.timestamp
            }

            currentWords.append(word.substring)
            chunkEnd = wordEnd
        }

        if !currentWords.isEmpty {
            chunks.append(TranscriptSegment(
                index: chunkIndex,
                startTime: chunkStart,
                endTime: chunkEnd,
                text: currentWords.joined(separator: " ")
            ))
        }

        return chunks
    }

    private func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: Speech Metrics (transcript-derived)

    func computeSpeechMetrics(wordSegments: [SFTranscriptionSegment], segments: [TranscriptSegment]) -> SpeechMetrics {
        let totalWords = Double(wordSegments.count)
        let totalDuration: Double
        if let first = wordSegments.first, let last = wordSegments.last {
            totalDuration = max((last.timestamp + last.duration) - first.timestamp, 1)
        } else {
            totalDuration = 1
        }
        let overallWPM = (totalWords / totalDuration) * 60.0

        var segmentWPMs: [SpeechMetrics.SegmentWPM] = []
        for segment in segments {
            let wordsInSegment = wordSegments.filter { $0.timestamp >= segment.startTime && $0.timestamp < segment.endTime }
            let segDuration = max(segment.endTime - segment.startTime, 1)
            let wpm = (Double(wordsInSegment.count) / segDuration) * 60.0
            segmentWPMs.append(.init(segmentIndex: segment.index, wpm: wpm))
        }

        var pauses: [Double] = []
        for i in 1..<wordSegments.count {
            let prevEnd = wordSegments[i - 1].timestamp + wordSegments[i - 1].duration
            let nextStart = wordSegments[i].timestamp
            let gap = nextStart - prevEnd
            if gap > 0.5 {
                pauses.append(gap)
            }
        }

        var fillerInstances: [String: [Int: Int]] = [:]
        for segment in segments {
            let wordsInSegment = wordSegments.filter { $0.timestamp >= segment.startTime && $0.timestamp < segment.endTime }
            for word in wordsInSegment {
                let lower = word.substring.lowercased().trimmingCharacters(in: .punctuationCharacters)
                if fillerWordSet.contains(lower) {
                    fillerInstances[lower, default: [:]][segment.index, default: 0] += 1
                }
            }
        }

        var fillerWords: [SpeechMetrics.FillerWordInstance] = []
        var totalFillers = 0
        for (word, segmentCounts) in fillerInstances {
            for (segIndex, count) in segmentCounts {
                fillerWords.append(.init(word: word, segmentIndex: segIndex, count: count))
                totalFillers += count
            }
        }

        return SpeechMetrics(
            overallWPM: overallWPM,
            segmentWPMs: segmentWPMs,
            totalPauses: pauses.count,
            avgPauseDuration: pauses.isEmpty ? 0 : pauses.reduce(0, +) / Double(pauses.count),
            fillerWordCount: totalFillers,
            fillerWords: fillerWords
        )
    }

    // MARK: Visual Metrics (Vision-based)

    func analyzeVideo(url: URL, segments: [TranscriptSegment]) async throws -> VisualMetrics {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        let duration = try await asset.load(.duration).seconds
        guard duration > 0 else {
            return VisualMetrics(eyeContactPercentage: 0, avgHeadYaw: 0, avgHeadRoll: 0, postureScore: 0, shoulderAlignmentScore: 0, segmentVisuals: [])
        }

        let sampleInterval: TimeInterval = 2.0
        var sampleTimes: [TimeInterval] = []
        var t: TimeInterval = 0.5
        while t < duration {
            sampleTimes.append(t)
            t += sampleInterval
        }

        var frameResults: [(time: TimeInterval, yaw: Double?, faceDetected: Bool, postureScore: Double)] = []

        for sampleTime in sampleTimes {
            let cmTime = CMTime(seconds: sampleTime, preferredTimescale: 600)
            guard let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: nil) else { continue }

            let result = analyzeFrame(cgImage)
            frameResults.append((time: sampleTime, yaw: result.yaw, faceDetected: result.faceDetected, postureScore: result.postureScore))
        }

        let facesDetected = frameResults.filter { $0.faceDetected }
        let eyeContactFrames = facesDetected.filter { frame in
            guard let yaw = frame.yaw else { return false }
            return abs(yaw) < 0.25
        }
        let eyeContactPct = facesDetected.isEmpty ? 0 : (Double(eyeContactFrames.count) / Double(facesDetected.count)) * 100

        let yaws = facesDetected.compactMap { $0.yaw }
        let avgYaw = yaws.isEmpty ? 0 : yaws.reduce(0, +) / Double(yaws.count)

        let postureScores = frameResults.map { $0.postureScore }
        let avgPosture = postureScores.isEmpty ? 0 : postureScores.reduce(0, +) / Double(postureScores.count)

        var segmentVisuals: [VisualMetrics.SegmentVisual] = []
        for segment in segments {
            let segFrames = frameResults.filter { $0.time >= segment.startTime && $0.time < segment.endTime }
            let segFaces = segFrames.filter { $0.faceDetected }
            let segEyeContact = segFaces.filter { frame in
                guard let yaw = frame.yaw else { return false }
                return abs(yaw) < 0.25
            }
            let segEyePct = segFaces.isEmpty ? 0 : (Double(segEyeContact.count) / Double(segFaces.count)) * 100
            let segYaws = segFaces.compactMap { $0.yaw }
            let segAvgYaw = segYaws.isEmpty ? 0 : segYaws.reduce(0, +) / Double(segYaws.count)
            let segPostures = segFrames.map { $0.postureScore }
            let segAvgPosture = segPostures.isEmpty ? 0 : segPostures.reduce(0, +) / Double(segPostures.count)

            segmentVisuals.append(.init(
                segmentIndex: segment.index,
                eyeContactPercentage: segEyePct,
                avgYaw: segAvgYaw,
                postureScore: segAvgPosture
            ))
        }

        return VisualMetrics(
            eyeContactPercentage: eyeContactPct,
            avgHeadYaw: avgYaw,
            avgHeadRoll: 0,
            postureScore: avgPosture,
            shoulderAlignmentScore: avgPosture,
            segmentVisuals: segmentVisuals
        )
    }

    private struct FrameAnalysis {
        var yaw: Double?
        var faceDetected: Bool
        var postureScore: Double
    }

    private func analyzeFrame(_ cgImage: CGImage) -> FrameAnalysis {
        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        let faceRequest = VNDetectFaceLandmarksRequest()
        let bodyRequest = VNDetectHumanBodyPoseRequest()

        try? requestHandler.perform([faceRequest, bodyRequest])

        var yaw: Double?
        var faceDetected = false
        if let face = faceRequest.results?.first {
            faceDetected = true
            yaw = face.yaw?.doubleValue
        }

        var postureScore: Double = 0.5
        if let body = bodyRequest.results?.first {
            postureScore = computePostureScore(from: body)
        }

        return FrameAnalysis(yaw: yaw, faceDetected: faceDetected, postureScore: postureScore)
    }

    private func computePostureScore(from observation: VNHumanBodyPoseObservation) -> Double {
        guard let points = try? observation.recognizedPoints(.torso) else { return 0.5 }

        let leftShoulder = points[.leftShoulder]
        let rightShoulder = points[.rightShoulder]
        let neck = points[.neck]

        guard let ls = leftShoulder, ls.confidence > 0.3,
              let rs = rightShoulder, rs.confidence > 0.3 else {
            return 0.5
        }

        let shoulderDiff = abs(ls.location.y - rs.location.y)
        let shoulderScore = max(0, 1.0 - shoulderDiff * 5.0)

        var alignmentScore = 0.7
        if let n = neck, n.confidence > 0.3 {
            let shoulderMidX = (ls.location.x + rs.location.x) / 2.0
            let neckOffset = abs(n.location.x - shoulderMidX)
            alignmentScore = max(0, 1.0 - neckOffset * 5.0)
        }

        return (shoulderScore + alignmentScore) / 2.0
    }

    // MARK: Title Generation

    func generateTitle(from transcript: String) async throws -> String {
        let model = SystemLanguageModel.default
        guard model.availability == .available else {
            throw AnalysisError.modelNotAvailable
        }

        let session = LanguageModelSession(instructions: """
            You generate short, descriptive titles for speech recordings. \
            Given a transcript, produce a concise title (3-6 words) that captures what the speech is about. \
            Do not use quotes or punctuation. Just output the title.
            """)

        let preview = String(transcript.prefix(500))
        let response = try await session.respond(to: "Generate a short title for this speech:\n\n\(preview)")
        let title = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(title.prefix(50))
    }

    // MARK: AI Analysis (enhanced with metrics)

    func analyze(
        segments: [TranscriptSegment],
        speechMetrics: SpeechMetrics? = nil,
        visualMetrics: VisualMetrics? = nil
    ) async throws -> PresentationAnalysis {
        let model = SystemLanguageModel.default
        guard model.availability == .available else {
            throw AnalysisError.modelNotAvailable
        }

        let numberedTranscript = segments.map { segment in
            "[Segment \(segment.index) | \(segment.formattedTimeRange)] \(segment.text)"
        }.joined(separator: "\n")

        var metricsContext = ""

        if let sm = speechMetrics {
            metricsContext += "\n\nSPEECH METRICS:\n"
            metricsContext += "- Overall pace: \(Int(sm.overallWPM)) words per minute\n"
            metricsContext += "- Total pauses (>0.5s): \(sm.totalPauses), avg duration: \(String(format: "%.1f", sm.avgPauseDuration))s\n"
            metricsContext += "- Filler words detected: \(sm.fillerWordCount) total\n"

            let fillerSummary = Dictionary(grouping: sm.fillerWords) { $0.word }
                .map { (word, instances) in "\(word): \(instances.reduce(0) { $0 + $1.count })x" }
                .joined(separator: ", ")
            if !fillerSummary.isEmpty {
                metricsContext += "- Filler breakdown: \(fillerSummary)\n"
            }

            for segWPM in sm.segmentWPMs {
                metricsContext += "- Segment \(segWPM.segmentIndex) pace: \(Int(segWPM.wpm)) WPM\n"
            }
        }

        if let vm = visualMetrics {
            metricsContext += "\n\nVISUAL METRICS (from video analysis):\n"
            metricsContext += "- Eye contact with camera: \(Int(vm.eyeContactPercentage))% of the time\n"
            metricsContext += "- Average head yaw: \(String(format: "%.2f", vm.avgHeadYaw)) (0 = centered)\n"
            metricsContext += "- Overall posture score: \(String(format: "%.0f", vm.postureScore * 100))%\n"

            for sv in vm.segmentVisuals {
                metricsContext += "- Segment \(sv.segmentIndex): eye contact \(Int(sv.eyeContactPercentage))%, posture \(String(format: "%.0f", sv.postureScore * 100))%\n"
            }
        }

        let session = LanguageModelSession(instructions: """
            You are an expert public speaking and presentation coach. \
            Analyze the timed transcript of a speech along with quantitative metrics. \
            Each segment has a number and time range. \
            Categorize feedback into these themes: \
            - delivery (pace, rhythm, pausing, filler words, vocal variety) \
            - clarity (enunciation, conciseness, coherence) \
            - structure (organization, transitions, opening/closing) \
            - presence (confidence, energy, engagement, authority, eye contact, body language, posture) \
            - language (word choice, vocabulary, phrasing) \
            IMPORTANT pace reference ranges: \
            Under 100 WPM is slow (good for emphasis, but too slow feels sluggish). \
            100-130 WPM is a deliberate, measured pace. \
            130-160 WPM is the ideal conversational range for presentations. \
            160-190 WPM is brisk but still clear. \
            Over 190 WPM is genuinely fast and may hurt clarity. \
            Use these ranges accurately — do NOT call anything under 130 WPM "fast". \
            Use the speech metrics (WPM, pauses, filler words) to give specific delivery feedback. \
            Use the visual metrics (eye contact %, posture score, head position) to give specific presence feedback. \
            Reference actual numbers when relevant. \
            Provide at most one feedback note per segment — only include notes for segments that need feedback. \
            For each note, specify the segment number it refers to. \
            For each note, write 2-3 sentences: explain what you observed, why it matters, and give a concrete suggestion. \
            Be encouraging but honest.
            """)

        let prompt = "Analyze this timed speech transcript and provide feedback referencing segment numbers:\n\n\(numberedTranscript)\(metricsContext)"

        let response = try await session.respond(
            to: prompt,
            generating: GeneratedAnalysis.self
        )

        let generated = response.content
        let maxIndex = segments.count - 1
        var seenSegments = Set<Int>()
        let feedbackNotes = generated.notes.compactMap { note -> FeedbackNote? in
            let segmentIndex = min(max(note.segmentNumber, 0), maxIndex)
            guard seenSegments.insert(segmentIndex).inserted else { return nil }
            return FeedbackNote(
                segmentIndex: segmentIndex,
                category: note.category.rawValue,
                title: note.title,
                detail: note.detail,
                type: note.type == .strength ? .strength : .improvement
            )
        }
        return PresentationAnalysis(
            overallScore: generated.overallScore,
            summary: generated.summary,
            feedbackNotes: feedbackNotes
        )
    }
}

enum AnalysisError: LocalizedError {
    case speechNotAuthorized
    case speechNotAvailable
    case modelNotAvailable

    var errorDescription: String? {
        switch self {
        case .speechNotAuthorized:
            return "Speech recognition is not authorized. Please enable it in System Settings."
        case .speechNotAvailable:
            return "Speech recognition is not available on this device."
        case .modelNotAvailable:
            return "Apple Intelligence is not available. Please enable it in System Settings."
        }
    }
}
