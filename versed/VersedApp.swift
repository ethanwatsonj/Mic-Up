le //
//  VersedApp.swift
//  versed
//
//  Created by Ethan Watson on 4/24/26.
//

import SwiftUI
import SwiftData

@main
struct VersedApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Presentation.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .tint(PrimaryColor.tone500)
                .hostGrotesk()
        }
        .modelContainer(sharedModelContainer)
    }
}

// MARK: - Host Grotesk Font

private let hgFamily = "Host Grotesk"

extension Font {
    static func hg(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(hgFamily, size: size).weight(weight)
    }

    static var hgHeading1: Font { .hg(24, weight: .semibold) }
    static var hgBody: Font { .hg(18, weight: .regular) }
    static var hgLabel: Font { .hg(14, weight: .semibold) }
}

extension View {
    func hgBodyStyle() -> some View {
        font(.hgBody)
            .lineSpacing(6)
    }

    func hgLabelStyle() -> some View {
        font(.hgLabel)
            .lineSpacing(10)
    }
}

struct HostGroteskModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.custom(hgFamily, size: 16).weight(.regular))
    }
}

extension View {
    func hostGrotesk() -> some View {
        modifier(HostGroteskModifier())
    }
}
