//
//  Presentation.swift
//  versed
//
//  Created by Ethan Watson on 4/24/26.
//

import Foundation
import SwiftData

@Model
final class Presentation {
    var title: String
    var dateCreated: Date
    var videoFileName: String?
    var transcript: String
    var segmentsJSON: Data?
    var analysisJSON: Data?
    var speechMetricsJSON: Data?
    var visualMetricsJSON: Data?
    var statusRaw: String
    var errorMessage: String?

    var status: PresentationStatus {
        get { PresentationStatus(rawValue: statusRaw) ?? .importing }
        set { statusRaw = newValue.rawValue }
    }

    var segments: [TranscriptSegment] {
        get {
            guard let data = segmentsJSON else { return [] }
            return (try? JSONDecoder().decode([TranscriptSegment].self, from: data)) ?? []
        }
        set {
            segmentsJSON = try? JSONEncoder().encode(newValue)
        }
    }

    var analysis: PresentationAnalysis? {
        get {
            guard let data = analysisJSON else { return nil }
            return try? JSONDecoder().decode(PresentationAnalysis.self, from: data)
        }
        set {
            analysisJSON = try? JSONEncoder().encode(newValue)
        }
    }

    var speechMetrics: SpeechMetrics? {
        get {
            guard let data = speechMetricsJSON else { return nil }
            return try? JSONDecoder().decode(SpeechMetrics.self, from: data)
        }
        set {
            speechMetricsJSON = try? JSONEncoder().encode(newValue)
        }
    }

    var visualMetrics: VisualMetrics? {
        get {
            guard let data = visualMetricsJSON else { return nil }
            return try? JSONDecoder().decode(VisualMetrics.self, from: data)
        }
        set {
            visualMetricsJSON = try? JSONEncoder().encode(newValue)
        }
    }

    var videoURL: URL? {
        guard let fileName = videoFileName else { return nil }
        return Self.videosDirectory.appendingPathComponent(fileName)
    }

    static var videosDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("VersedVideos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init(title: String, videoFileName: String? = nil) {
        self.title = title
        self.dateCreated = Date()
        self.videoFileName = videoFileName
        self.transcript = ""
        self.statusRaw = PresentationStatus.importing.rawValue
    }
}

enum PresentationStatus: String, Codable {
    case importing
    case transcribing
    case analyzing
    case ready
    case failed
}

// MARK: - Transcript Segment

struct TranscriptSegment: Codable, Identifiable {
    var id = UUID()
    var index: Int
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String

    var formattedTimeRange: String {
        "\(formatTime(startTime)) - \(formatTime(endTime))"
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Speech Metrics (transcript-derived)

struct SpeechMetrics: Codable {
    var overallWPM: Double
    var segmentWPMs: [SegmentWPM]
    var totalPauses: Int
    var avgPauseDuration: Double
    var fillerWordCount: Int
    var fillerWords: [FillerWordInstance]

    struct SegmentWPM: Codable {
        var segmentIndex: Int
        var wpm: Double
    }

    struct FillerWordInstance: Codable {
        var word: String
        var segmentIndex: Int
        var count: Int
    }
}

// MARK: - Visual Metrics (Vision-derived)

struct VisualMetrics: Codable {
    var eyeContactPercentage: Double
    var avgHeadYaw: Double
    var avgHeadRoll: Double
    var postureScore: Double
    var shoulderAlignmentScore: Double
    var segmentVisuals: [SegmentVisual]

    struct SegmentVisual: Codable {
        var segmentIndex: Int
        var eyeContactPercentage: Double
        var avgYaw: Double
        var postureScore: Double
    }
}

// MARK: - Analysis Types

struct PresentationAnalysis: Codable {
    var overallScore: Int
    var summary: String
    var feedbackNotes: [FeedbackNote]
}

struct FeedbackNote: Codable, Identifiable {
    var id = UUID()
    var segmentIndex: Int
    var category: String
    var title: String
    var detail: String
    var type: FeedbackType

    enum FeedbackType: String, Codable {
        case strength
        case improvement
    }

    var theme: FeedbackTheme {
        FeedbackTheme(rawValue: category) ?? .delivery
    }
}

import SwiftUI

enum FeedbackTheme: String {
    case delivery
    case clarity
    case structure
    case presence
    case language

    var label: String {
        switch self {
        case .delivery: return "Delivery"
        case .clarity: return "Clarity"
        case .structure: return "Structure"
        case .presence: return "Presence"
        case .language: return "Language"
        }
    }

    var icon: String {
        switch self {
        case .delivery: return "waveform"
        case .clarity: return "text.magnifyingglass"
        case .structure: return "list.bullet"
        case .presence: return "person.fill"
        case .language: return "character.textbox"
        }
    }

    var color: Color {
        switch self {
        case .delivery: return PrimaryColor.tone500
        case .clarity: return PrimaryColor.tone400
        case .structure: return PrimaryColor.tone600
        case .presence: return PrimaryColor.tone300
        case .language: return PrimaryColor.tone700
        }
    }

    var mutedColor: Color {
        switch self {
        case .delivery: return PrimaryColor.tone700
        case .clarity: return PrimaryColor.tone600
        case .structure: return PrimaryColor.tone800
        case .presence: return PrimaryColor.tone500
        case .language: return PrimaryColor.tone800
        }
    }
}
