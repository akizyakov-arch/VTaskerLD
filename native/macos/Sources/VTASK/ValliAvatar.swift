import SwiftUI

enum ValliState: String, CaseIterable {
    case idle, listening, thinking, searching, question, done
    case takingNotes = "taking-notes"
    case needsReview = "needs-review"
    case audioUnclear = "audio-unclear"

    var title: String {
        switch self {
        case .idle: return "На связи"
        case .listening: return "Слушаю"
        case .thinking: return "Думаю"
        case .takingNotes: return "Веду протокол"
        case .searching: return "Ищу"
        case .question: return "Есть вопрос"
        case .done: return "Готово"
        case .needsReview: return "Нужна проверка"
        case .audioUnclear: return "Не расслышал"
        }
    }
}

struct ValliAvatar: View {
    let state: ValliState
    let size: CGFloat
    var animated = false
    var highlighted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Keep decoded thumbnails available when chat state changes.
    private static let assets = NSCache<NSString, NSImage>()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27)
        ZStack {
            avatar.id(state).transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .scaleEffect(highlighted && !reduceMotion ? 1.06 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: highlighted)
        .animation(animated && !reduceMotion ? .easeOut(duration: 0.18) : nil, value: state)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var avatar: some View {
        if let image = Self.asset(for: state) {
            Image(nsImage: image).resizable().scaledToFit()
        } else {
            Image(systemName: "face.smiling")
                .font(.system(size: size * 0.56))
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary)
        }
    }

    private static func asset(for state: ValliState) -> NSImage? {
        let key = state.rawValue as NSString
        if let image = assets.object(forKey: key) { return image }
        let url = Bundle.main.url(forResource: state.rawValue, withExtension: "png", subdirectory: "ValliAvatar")
            ?? Bundle.module.url(forResource: state.rawValue, withExtension: "png", subdirectory: "ValliAvatar")
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        assets.setObject(image, forKey: key)
        return image
    }
}
