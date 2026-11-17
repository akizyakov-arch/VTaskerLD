import SwiftUI

struct MeetingOrbit<Controls: View>: View {
    let participants: [Person]
    let session: CaptureStatus.Session?
    let hint: CaptureStatus.SpeakerHint?
    @ViewBuilder let controls: () -> Controls

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var recording: Bool { session?.state == "recording" }
    private var level: Double { min(1, max(0, (session?.level ?? 0) * 2.5)) }
    private var speaker: Int? {
        guard recording, hint?.status == "candidate", hint?.sessionId == session?.sessionId,
              (hint?.ageMs ?? 0) < 10_000, level > 0.04 else { return nil }
        return hint?.personId
    }

    private var status: String {
        switch session?.state {
        case "paused": return "Пауза"
        case "recording": return "Идёт запись"
        case "starting": return "Запуск записи"
        case "stopping": return "Сохранение"
        default: return "Готово к записи"
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let palette = PanelPalette(dark: scheme == .dark)
            let radius = max(0, min(105, geometry.size.width / 2 - 36))
            let center = CGPoint(x: geometry.size.width / 2, y: 139)
            let visible = Array(participants.prefix(8))
            orbitRing(radius: radius)
                .position(center)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(meetingTime(session?.elapsedMs ?? 0)).font(.system(size: 36, weight: .bold)).monospacedDigit()
                HStack(spacing: 5) {
                    if session != nil { Circle().fill(session?.state == "paused" ? Color.orange : Color.red).frame(width: 7, height: 7) }
                    Text(status).font(.caption).foregroundStyle(palette.muted)
                }
                controls()
            }
            .position(center)
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, person in
                let angle = 2 * Double.pi * Double(index) / Double(visible.count) - Double.pi / 2
                avatar(person, index: index, palette: palette)
                    .position(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius + 8)
            }
            if participants.count > visible.count {
                Text("+\(participants.count - visible.count) участников")
                    .font(.caption).foregroundStyle(palette.muted)
                    .position(x: center.x, y: geometry.size.height - 6)
            }
        }
        .frame(height: 286)
    }

    private func orbitRing(radius: CGFloat) -> some View {
        let animated = recording && !reduceMotion
        let audioLevel = animated ? level : 0
        return TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animated)) { context in
            let phase = animated
                ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 18) / 18
                : 0
            let pulse = animated ? (1 - cos(phase * 12 * .pi)) / 2 : 0
            Canvas { graphics, size in
                for particle in MeetingOrbitArt.particles {
                    let diameter = particle.size * size.width
                    let bounds = CGRect(x: particle.x * size.width - diameter / 2,
                                        y: particle.y * size.height - diameter / 2,
                                        width: diameter, height: diameter)
                    graphics.fill(Path(ellipseIn: bounds), with: .color(particle.color))
                }
            }
            .frame(width: radius * 2.25, height: radius * 2.25)
            .rotationEffect(.degrees(phase * 360))
            .scaleEffect(1 + 0.025 * pulse + 0.05 * audioLevel)
            .opacity(recording ? 0.88 + 0.12 * pulse : session?.state == "paused" ? 0.42 : 0.72)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: audioLevel)
    }

    private func avatar(_ person: Person, index: Int, palette: PanelPalette) -> some View {
        let speaking = speaker == person.id
        let colors: [Color] = [
            Color(red: 0.80, green: 0.68, blue: 0.97), Color(red: 0.58, green: 0.76, blue: 0.98),
            Color(red: 1.0, green: 0.76, blue: 0.68), Color(red: 0.91, green: 0.80, blue: 0.56)
        ]
        let mint = Color(red: 0.63, green: 0.96, blue: 0.82)
        return VStack(spacing: 4) {
            Text(String(person.name.prefix(1)).uppercased())
                .font(.headline).foregroundStyle(Color.black.opacity(0.8))
                .frame(width: 42, height: 42)
                .background(speaking ? mint : colors[index % colors.count], in: Circle())
                .overlay {
                    if speaking { Circle().strokeBorder(mint, lineWidth: 2).padding(-4) }
                }
                .shadow(color: speaking ? mint.opacity(0.7) : .clear, radius: 8)
                .scaleEffect(speaking && !reduceMotion ? 1.06 + 0.14 * level : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: speaking)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: level)
            Text(person.name).font(.caption.weight(.semibold)).lineLimit(1)
                .foregroundStyle(palette.text)
                .padding(.horizontal, 4)
                .background(palette.surface, in: Capsule())
        }
        .frame(width: 82)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(speaking ? person.name + ", предположительно говорит" : person.name)
    }
}

private enum MeetingOrbitArt {
    struct Particle {
        let x: Double
        let y: Double
        let size: Double
        let color: Color
    }

    static let particles: [Particle] = {
        // Keep particle positions fixed as the timer and microphone level update.
        var seed: UInt64 = 42
        func sample() -> Double {
            seed = 6364136223846793005 &* seed &+ 1
            return Double(seed >> 40) / 16_777_216
        }

        return (0..<1_350).map { _ in
            let angle = sample() * 2 * Double.pi
            let spread = sample() + sample() - 1
            let radius = 0.39 + spread * 0.105 + 0.009 * sin(5 * angle)
            let size = 0.004 + pow(sample(), 2) * 0.023
            let hue = 0.68 - 0.17 * cos(angle)
            let opacity = (0.24 + sample() * 0.62) * (1 - abs(spread) * 0.7)
            return Particle(x: 0.5 + radius * cos(angle), y: 0.5 + radius * sin(angle), size: size,
                            color: Color(hue: hue, saturation: 0.82, brightness: 0.94).opacity(opacity))
        }
    }()
}
