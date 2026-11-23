import SwiftUI

enum ValliTourStep: Int, CaseIterable {
    case today, projects, meetings, approvals, glossary, settings, assistant

    var title: String {
        switch self {
        case .today: return "Сегодня"
        case .projects: return "Проекты"
        case .meetings: return "Совещания"
        case .approvals: return "Задачи и решения"
        case .glossary: return "Справочники"
        case .settings: return "Настройки"
        case .assistant: return "Чат с Валли"
        }
    }

    var message: String {
        switch self {
        case .today:
            return "Привет, я Валли. Начнём с экрана «Сегодня». Здесь можно открыть просроченные задачи одним нажатием и посмотреть сроки в календаре или на диаграмме Ганта."
        case .projects:
            return "Откройте проект, чтобы увидеть его обзор, задачи, совещания и материалы. В обзоре можно отредактировать карточку проекта, его сроки и этапы работ."
        case .meetings:
            return "Создайте встречу через плюс и выберите участников. Запись включается отдельно в карточке встречи. После записи откройте протокол, чтобы проверить текст и запустить анализ."
        case .approvals:
            return "Здесь видны предложения на согласовании. Откройте карточку, проверьте формулировку, исполнителя и срок. Подтверждённое поручение появится в задачах проекта."
        case .glossary:
            return "В этой вкладке можно выбрать отрасль и просмотреть шаблоны этапов работ. Во вкладке «Термины» добавляйте названия и выражения, которые использует ваша команда."
        case .settings:
            return "Здесь можно выбрать тему и отдельно настроить распознавание речи, анализ протокола и мой голос."
        case .assistant:
            return "Попробуйте написать мне «Покажи задачи на неделю». В карточке проекта я ищу по этому проекту. Микрофон чата включается отдельной кнопкой."
        }
    }

    var previous: Self? { Self(rawValue: rawValue - 1) }
    var next: Self? { Self(rawValue: rawValue + 1) }
}

struct ValliTourPanel: View {
    let step: ValliTourStep
    let canNavigate: Bool
    let canSpeak: Bool
    let showStep: (ValliTourStep) -> Void
    let close: () -> Void
    @StateObject private var speech = AssistantSpeech()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                NavigationBackButton(action: close)
                    .accessibilityLabel("Вернуться в чат")
                    .help("Вернуться в чат")
                    .keyboardShortcut(.cancelAction)
                ValliAvatar(state: .idle, size: 44, highlighted: speech.isSpeaking)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Обучение с Валли").font(.title3.weight(.semibold))
                    Text("Шаг \(step.rawValue + 1) из \(ValliTourStep.allCases.count)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(step.title).font(.headline).accessibilityAddTraits(.isHeader)
                    Text(step.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Button {
                        if speech.isSpeaking { speech.stop() }
                        else { speech.speak(step.message) }
                    } label: {
                        Label(speech.isSpeaking ? "Остановить" : "Озвучить",
                              systemImage: speech.isSpeaking ? "stop.fill" : "speaker.wave.2")
                    }
                    .disabled(!canSpeak)
                    .help(canSpeak ? "Озвучить подсказку Валли" : "Озвучивание доступно после остановки записи и голосового диалога")
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                .padding(14)
            }
            .id(step)
            Divider()
            HStack(spacing: 8) {
                if let previous = step.previous {
                    Button("Назад") { showStep(previous) }.disabled(!canNavigate)
                }
                Spacer()
                if let next = step.next {
                    Button("Далее") { showStep(next) }.buttonStyle(.borderedProminent).disabled(!canNavigate)
                } else {
                    Button("Перейти в чат", action: close).buttonStyle(.borderedProminent)
                }
            }
            .padding(14)
        }
        .onChange(of: step) { _ in speech.stop() }
        .onChange(of: canSpeak) { allowed in if !allowed { speech.stop() } }
        .onDisappear { speech.stop() }
    }
}
