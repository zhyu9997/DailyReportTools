import SwiftUI

/// 看板里的会议卡片（紧凑版，不可拖拽；点击跳转到「会议纪要」并打开编辑）
/// R22-B：从 HistoryView.swift 抽出（HistoryView 693 行 → 618 行）
/// MeetingBoardCard 是独立的 struct，不依赖 HistoryView 的 @State（与看板列渲染解耦）
struct MeetingBoardCard: View {
    @Environment(NavigationCoordinator.self) private var coordinator
    @Environment(\.appStore) private var store
    let meeting: MeetingRecord

    private static let meetingColor: Color = .purple
    private var tags: [TagRecord] { store?.tagsByMeeting[meeting.id] ?? [] }
    private var reviews: [ReviewRecord] { store?.reviewsByMeeting[meeting.id] ?? [] }

    var body: some View {
        Button {
            coordinator.openMeetingEdit(meeting)
        } label: {
            cardContent
        }
        .buttonStyle(.plain)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "person.3.fill")
                    .foregroundStyle(Self.meetingColor)
                    .font(.caption)
                Text(meeting.topic)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                if meeting.isRecurring {
                    Image(systemName: "repeat")
                        .font(.system(size: 9))
                        .foregroundStyle(Self.meetingColor)
                }
                Spacer(minLength: 0)
                Image(systemName: "pencil")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if !meeting.summary.isEmpty {
                Text(meeting.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            if !tags.isEmpty {
                HStack(spacing: 3) {
                    ForEach(tags) { tag in
                        Text(tag.name)
                            .font(.system(size: 9))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(tag.swiftUIColor.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
            }
            HStack(spacing: 6) {
                Label(meeting.timestamp.formatted(date: .abbreviated, time: .shortened),
                      systemImage: "clock")
                if !reviews.isEmpty {
                    Text("·")
                    Label("\(reviews.count)", systemImage: "bubble.left.and.bubble.right.fill")
                }
                Spacer(minLength: 0)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Self.meetingColor.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Self.meetingColor.opacity(0.25), lineWidth: 1))
        .contentShape(Rectangle())
        .help("点击编辑 · 在「会议纪要」中打开")
    }
}
