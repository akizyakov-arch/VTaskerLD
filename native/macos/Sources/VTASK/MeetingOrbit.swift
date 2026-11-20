import AppKit
import SwiftUI

struct MeetingOrbit<Controls: View>: View {
    let title: String
    let projectName: String
    let participants: [Person]
    let photoURL: (Person) -> URL?
    let session: CaptureStatus.Session?
    let hint: CaptureStatus.SpeakerHint?
    @ViewBuilder let controls: () -> Controls

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var recording: Bool { session?.state == "recording" }
    private var level: Double { min(1, max(0, (session?.level ?? 0) * 2.5)) }
    private var speaker: Int? {
        guard recording, let session, let hint, hint.status == "candidate",
              let sessionID = session.sessionId, hint.sessionId == sessionID,
              let age = hint.ageMs, age < 6_500,
              let end = hint.endMs, let saved = session.savedMs,
              end <= saved, saved - end <= 6_000, level > 0.04 else { return nil }
        return hint.personId
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
        let dark = scheme == .dark
        let palette = PanelPalette(dark: dark)
        let visible = Array(participants.prefix(8))
        let stageShape = RoundedRectangle(cornerRadius: 24)
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    stageTitle(palette)
                    Spacer(minLength: 0)
                    stageStatus(palette)
                    Spacer(minLength: 0)
                    participantCount(palette)
                }
                VStack(alignment: .leading, spacing: 12) {
                    stageTitle(palette)
                    HStack {
                        stageStatus(palette)
                        Spacer(minLength: 0)
                        participantCount(palette)
                    }
                }
            }
            .padding(.horizontal, 24)

            ZStack {
                RecordingWave(level: level, recording: recording, paused: session?.state == "paused")
                    .frame(height: 250)
                if !visible.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        VStack(spacing: 26) {
                            participantRow(visible.prefix(5), palette: palette)
                            if visible.count > 5 {
                                participantRow(visible.dropFirst(5), palette: palette)
                            }
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 8)], spacing: 20) {
                            ForEach(visible) { person in
                                avatar(person, palette: palette)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 22)
                }
            }
            .frame(minHeight: 300)
            if participants.count > visible.count {
                Text("+\(participants.count - visible.count) участников")
                    .font(.caption).foregroundStyle(palette.muted)
                    .padding(.bottom, 8)
            }
            controls()
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background {
            stageShape.fill(
                LinearGradient(colors: dark
                    ? [Color(red: 0.065, green: 0.055, blue: 0.14), Color(red: 0.11, green: 0.10, blue: 0.22)]
                    : [Color(red: 0.985, green: 0.98, blue: 1), Color(red: 0.92, green: 0.91, blue: 0.99)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        }
        .clipShape(stageShape)
        .overlay { stageShape.strokeBorder(.purple.opacity(dark ? 0.30 : 0.14)) }
    }

    private func stageTitle(_ palette: PanelPalette) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(scheme == .dark ? Color(red: 0.82, green: 0.66, blue: 1) : .purple)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.weight(.semibold)).foregroundStyle(palette.text)
                    .lineLimit(1).accessibilityAddTraits(.isHeader)
                Text(projectName).font(.callout).foregroundStyle(palette.muted).lineLimit(1)
            }
        }
    }

    private func stageStatus(_ palette: PanelPalette) -> some View {
        HStack(spacing: 12) {
            Label(status, systemImage: recording ? "record.circle.fill" : session?.state == "paused" ? "pause.fill" : "waveform")
                .font(.caption.weight(.semibold))
                .foregroundStyle(recording ? (scheme == .dark ? Color(red: 0.82, green: 0.66, blue: 1) : .purple) : palette.muted)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
            Label(meetingTime(session?.elapsedMs ?? 0), systemImage: "clock")
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(palette.text)
        }
        .fixedSize()
    }

    private func participantCount(_ palette: PanelPalette) -> some View {
        Label("\(participants.count)", systemImage: "person.2")
            .font(.callout.weight(.medium))
            .foregroundStyle(palette.text)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.thinMaterial, in: Capsule())
            .accessibilityLabel("Участников: \(participants.count)")
    }

    private func participantRow(_ people: ArraySlice<Person>, palette: PanelPalette) -> some View {
        HStack(spacing: 20) {
            ForEach(people) { person in
                avatar(person, palette: palette).frame(width: 100)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func avatar(_ person: Person, palette: PanelPalette) -> some View {
        let speaking = speaker == person.id
        let dark = scheme == .dark
        let glow = dark ? Color(red: 0.74, green: 0.47, blue: 1) : Color(red: 0.47, green: 0.20, blue: 0.93)
        return VStack(spacing: 8) {
            PersonAvatar(person: person, url: photoURL(person), size: 70,
                         monogramInk: dark ? Color(red: 0.90, green: 0.84, blue: 1)
                                           : Color(red: 0.30, green: 0.18, blue: 0.51))
                .background {
                    Circle().fill(RadialGradient(
                        colors: dark
                            ? [Color(red: 0.09, green: 0.08, blue: 0.17),
                               Color(red: 0.20, green: 0.18, blue: speaking ? 0.45 : 0.32)]
                            : [.white, Color(red: 0.83, green: 0.77, blue: speaking ? 1 : 0.95)],
                        center: .center, startRadius: 5, endRadius: 37))
                }
                .overlay {
                    Circle().strokeBorder(
                        LinearGradient(colors: speaking ? [.white, glow, .pink] : [.white.opacity(0.75), glow.opacity(0.30), glow.opacity(0.58)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: speaking ? 3 : 1
                    )
                    if speaking { Circle().strokeBorder(glow.opacity(0.55)).padding(-4) }
                }
                .shadow(color: glow.opacity(speaking ? 0.8 : 0.20), radius: speaking ? 12 : 4)
                .overlay(alignment: .bottomTrailing) {
                    if speaking {
                        Image(systemName: "waveform")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Color(red: 0.32, green: 0.19, blue: 0.61), in: Circle())
                            .overlay { Circle().strokeBorder(.white.opacity(0.55)) }
                            .offset(x: 3, y: 3)
                    }
                }
                .scaleEffect(speaking && !reduceMotion ? 1.12 + 0.10 * level : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: speaking)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: level)
            Text(person.name).lineLimit(1)
            .font(.caption.weight(.semibold))
            .foregroundStyle(palette.text)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.thinMaterial, in: Capsule())
            .help(person.name)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(speaking ? person.name + ", говорит" : person.name)
    }
}

private struct RecordingWave: View, Animatable {
    var level: Double
    let recording: Bool
    let paused: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    private static let image: NSImage? = {
        let url = Bundle.main.url(forResource: "recording-wave", withExtension: "png")
            ?? Bundle.module.url(forResource: "recording-wave", withExtension: "png")
        return url.flatMap(NSImage.init(contentsOf:))
    }()

    private var darkRibbonOpacity: Double { scheme == .dark ? 0.20 : 0.085 }

    var body: some View {
        let moving = recording && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 8) * .pi / 4
            Canvas { graphics, size in
                guard let bitmap = Self.image, size.width > 0, size.height > 0 else { return }
                var ribbon = graphics
                ribbon.opacity = darkRibbonOpacity
                let image = ribbon.resolve(Image(nsImage: bitmap))
                let height = min(size.width / 3, size.height * 0.82)
                let signal = moving ? sqrt(min(1, max(0, level))) : 0
                let time = moving ? phase : 0
                let dark = scheme == .dark
                for strand in 0..<25 {
                    let spread = Double(strand - 12) / 12
                    var path = Path()
                    for point in 0...64 {
                        let x = Double(point) / 64
                        let middle = exp(-pow((x - 0.49) * 7, 2))
                        let base = sin(x * 6 * .pi - time + 0.5) * (21 + 32 * middle + 18 * signal)
                        let weave = spread * (24 + 30 * middle + 24 * signal) * cos(x * 5 * .pi + time)
                        let position = CGPoint(x: x * size.width, y: size.height / 2 + base + weave)
                        if point == 0 { path.move(to: position) } else { path.addLine(to: position) }
                    }
                    graphics.stroke(path, with: .linearGradient(
                        Gradient(colors: [.pink.opacity(0.36), .purple.opacity(dark ? 0.56 : 0.31),
                                          Color(red: 0.61, green: 0.39, blue: 1).opacity(dark ? 0.79 : 0.46),
                                          .indigo.opacity(dark ? 0.60 : 0.34), .purple.opacity(0.35)]),
                        startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)), lineWidth: 0.75)
                }
                if !moving {
                    ribbon.draw(image, in: CGRect(x: 0, y: (size.height - height) / 2,
                                                     width: size.width, height: height))
                    return
                }
                let columns = 28
                let stripWidth = size.width / CGFloat(columns)
                for index in 0..<columns {
                    let fraction = (Double(index) + 0.5) / Double(columns)
                    let envelope = sin(.pi * fraction)
                    let shift = envelope * (1.4 + 5.5 * signal) * sin(phase * 3 - 2 * .pi * fraction)
                    let stretchedHeight = height
                        * (1 + envelope * (0.028 + 0.13 * signal) * (0.65 + 0.35 * cos(phase * 2 - .pi * fraction)))
                    var strip = ribbon
                    let left = CGFloat(index) * stripWidth
                    strip.clip(to: Path(CGRect(x: left, y: 0, width: stripWidth, height: size.height)))
                    strip.draw(image, in: CGRect(x: 0, y: (size.height - stretchedHeight) / 2 + shift,
                                                  width: size.width, height: stretchedHeight))
                }
            }
        }
        .opacity(paused ? 0.66 : recording ? 1 : 0.89)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: level)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct RecordingControlStyle: ButtonStyle {
    let stop: Bool
    let primary: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let colors: [Color] = stop
            ? [Color(red: 0.79, green: 0.19, blue: 0.28), Color(red: 0.65, green: 0.10, blue: 0.24)]
            : [Color(red: 0.67, green: 0.15, blue: 0.62), Color(red: 0.39, green: 0.22, blue: 0.77),
               Color(red: 0.02, green: 0.46, blue: 0.64)]
        return configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(stop || primary ? Color.white : Color.primary)
            .frame(width: primary ? 52 : 44, height: primary ? 52 : 44)
            .background {
                if stop || primary {
                    Circle().fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                } else {
                    Circle().fill(.thinMaterial)
                }
            }
            .overlay { Circle().strokeBorder(.purple.opacity(primary ? 0.75 : 0.24), lineWidth: primary ? 2 : 1) }
            .shadow(color: colors[0].opacity(0.24), radius: 5, y: 2)
            .opacity(isEnabled ? (configuration.isPressed ? 0.74 : 1) : 0.48)
    }
}
