import SwiftUI

struct TaskTable: View {
    @Environment(\.colorScheme) private var scheme
    let tasks: [TaskItem]
    let projects: [Project]
    let people: [Person]
    @Binding var selection: Int?
    @Binding var marked: Set<Int>

    var body: some View {
        let palette = PanelPalette(dark: scheme == .dark)
        Table(tasks, selection: $selection) {
            TableColumn("Выбор") { task in
                let isMarked = marked.contains(task.id)
                Button {
                    if isMarked { marked.remove(task.id) } else { marked.insert(task.id) }
                } label: {
                    Image(systemName: isMarked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(isMarked ? palette.accent : .secondary)
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isMarked ? "Снять выбор" : "Выбрать для группового действия")
                .accessibilityLabel((isMarked ? "Снять выбор: " : "Выбрать: ") + task.title)
                .accessibilityAddTraits(isMarked ? .isSelected : [])
            }
            .width(52)
            TableColumn("Задача") { task in
                let expanded = selection == task.id
                Button {
                    selection = expanded ? nil : task.id
                } label: {
                    Text(task.title)
                        .font(.callout.bold())
                        .foregroundStyle(task.overdue ? palette.recordingInk : palette.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "Развёрнуто" : "Свёрнуто")
            }
            .width(min: 140, ideal: 250)
            TableColumn("Проект") { task in
                Text(projects.first { $0.id == task.projectId }?.title ?? "Без проекта")
                    .foregroundStyle(.secondary)
            }
            TableColumn("Исполнитель") { task in
                Text(people.first { $0.id == task.assigneeId }?.name ?? "Не назначен")
            }
            TableColumn("Статус") { task in
                let done = task.stageKind == "done"
                let color = done ? Color.green : palette.accent
                Label(task.stageTitle, systemImage: done ? "checkmark.circle.fill" : "circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(done ? Color.primary : palette.selectedInk)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(done ? color.opacity(0.16) : palette.selected, in: Capsule())
            }
            TableColumn("Срок") { task in
                if let date = task.dueDate {
                    Label([date, task.dueTime].compactMap { $0 }.joined(separator: " "),
                          systemImage: task.overdue ? "exclamationmark.clock" : "calendar")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(task.overdue ? palette.recordingInk : .secondary)
                        .accessibilityLabel(task.overdue ? "Просрочено" : "Срок")
                        .accessibilityValue([date, task.dueTime].compactMap { $0 }.joined(separator: " "))
                } else {
                    Text("—").foregroundStyle(.tertiary).accessibilityLabel("Без срока")
                }
            }
            TableColumn("Приоритет") { task in
                let labels = ["low": "Низкий", "normal": "Обычный", "high": "Высокий", "critical": "Критический"]
                Text(labels[task.priority ?? "normal"] ?? "Обычный")
            }
        }
        .scrollContentBackground(.hidden)
    }
}
