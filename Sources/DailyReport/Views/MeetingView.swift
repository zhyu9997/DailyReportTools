import SwiftUI
import SwiftData

/// 会议纪要：列表 + 新增/编辑
struct MeetingView: View {
    @Environment(\.modelContext) private var context
    @Environment(NavigationCoordinator.self) private var coordinator
    @Query(sort: \Meeting.timestamp, order: .reverse) private var meetings: [Meeting]

    @State private var editing: Meeting?
    @State private var creating = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if meetings.isEmpty {
                    EmptyStateView(icon: "person.3",
                                   title: "还没有会议纪要",
                                   message: "点右上角 + 添加第一条。")
                        .padding(.top, 60)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(meetings) { m in
                            MeetingCard(meeting: m) { editing = m }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("会议纪要")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    }
                    .help("新增会议纪要")
                }
            }
            .sheet(isPresented: $creating) {
                MeetingFormView { _ in creating = false }
            }
            .sheet(item: $editing) { m in
                MeetingFormView(meeting: m) { _ in editing = nil }
            }
            .onChange(of: coordinator.meetingRequest?.id) { _, _ in
                if let req = coordinator.meetingRequest {
                    editing = req.meeting
                }
            }
        }
    }
}

/// 单条会议卡片
struct MeetingCard: View {
    @Environment(\.modelContext) private var context
    @Bindable var meeting: Meeting
    var onEdit: () -> Void

    @State private var isAddingReview = false
    @State private var newReviewer = ""
    @State private var newOpinion = ""

    private var validReviews: [Review] {
        meeting.orderedReviews.filter { !$0.reviewer.isEmpty || !$0.opinion.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "person.3.fill").foregroundStyle(.tint)
                Text(meeting.topic).font(.headline)
                if meeting.isRecurring {
                    Label(meeting.recurrenceLabel, systemImage: "repeat")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.purple.opacity(0.15))
                        .foregroundStyle(.purple)
                        .clipShape(Capsule())
                }
                Spacer()
                Text(meeting.timestamp.relativeTime)
                    .font(.caption).foregroundStyle(.tertiary)
            }
            summaryEditor
            if !meeting.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(meeting.tags) { tag in
                        Text(tag.name)
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(tag.swiftUIColor.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
            }
            let reviews = validReviews
            if !reviews.isEmpty || isAddingReview {
                VStack(alignment: .leading, spacing: 8) {
                    Text("评审（\(reviews.count)）")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(reviews) { r in
                        reviewBlock(r)
                    }
                    if isAddingReview {
                        inlineAddReviewer
                    }
                }
            }
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { isAddingReview = true }
                } label: {
                    Label("评审", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless).font(.caption)
                .disabled(isAddingReview)
                Spacer()
                Button("编辑", action: onEdit)
                    .buttonStyle(.borderless).font(.caption)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.2), lineWidth: 1))
    }

    /// 卡片内联新增评审
    private var inlineAddReviewer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "person.circle").foregroundStyle(.tint).font(.caption)
                TextField("评审人", text: $newReviewer)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                Button {
                    cancelAdd()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("取消")
            }
            TextEditor(text: $newOpinion)
                .scrollContentBackground(.hidden)
                .font(.caption)
                .frame(minHeight: 38)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
            HStack {
                Spacer()
                Button {
                    saveAdd()
                } label: {
                    Label("添加", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(newReviewer.trimmingCharacters(in: .whitespaces).isEmpty
                          && newOpinion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary)
                .opacity(0.06)
        }
    }

    private func saveAdd() {
        let r = newReviewer.trimmingCharacters(in: .whitespaces)
        let o = newOpinion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty || !o.isEmpty else { cancelAdd(); return }
        let order = (meeting.orderedReviews.map(\.order).max() ?? -1) + 1
        let review = Review(reviewer: r, opinion: o, order: order)
        review.meeting = meeting
        context.insert(review)
        newReviewer = ""
        newOpinion = ""
        withAnimation(.easeInOut(duration: 0.18)) { isAddingReview = false }
    }

    private func cancelAdd() {
        newReviewer = ""
        newOpinion = ""
        withAnimation(.easeInOut(duration: 0.18)) { isAddingReview = false }
    }

    /// 概要：未来会议可随时内联编辑；已完成（timestamp ≤ 现在）的会议只读，避免误改
    @ViewBuilder
    private var summaryEditor: some View {
        if meeting.timestamp <= Date() {
            if !meeting.summary.isEmpty {
                Text(meeting.summary)
                    .font(.subheadline)
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ZStack(alignment: .topLeading) {
                if meeting.summary.isEmpty {
                    Text("点这里写概要…")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $meeting.summary)
                    .font(.subheadline)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 36, alignment: .top)
                    .padding(.horizontal, 4)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
            }
        }
    }

    @ViewBuilder
    private func reviewBlock(_ r: Review) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !r.reviewer.isEmpty {
                Label(r.reviewer, systemImage: "person.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            if !r.opinion.isEmpty {
                Text("“\(r.opinion)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            }
        }
    }
}

/// 表单用的评审草稿（非托管对象）
struct ReviewDraft: Identifiable {
    let id = UUID()
    var reviewer: String = ""
    var opinion: String = ""
}

/// 新增 / 编辑表单
struct MeetingFormView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var meeting: Meeting?
    var onDone: (Bool) -> Void

    @State private var topic = ""
    @State private var summary = ""
    @State private var timestamp = Date()
    @State private var selectedTags: [Tag] = []
    @State private var reviewDrafts: [ReviewDraft] = []
    @State private var isRecurring = false
    @State private var recurrenceUnit: RecurrenceUnit = .daily
    @State private var recurrenceInterval = 1
    @State private var recurrenceWeekdays: [Int] = []
    @State private var recurrenceMonthDays: [Int] = []

    private var validReviewCount: Int {
        reviewDrafts.filter { !$0.reviewer.trimmingCharacters(in: .whitespaces).isEmpty
                              || !$0.opinion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            Divider()
            HStack {
                Button("取消", role: .cancel) {
                    onDone(false)
                    dismiss()
                }
                Spacer()
                Button(action: save) {
                    Text(meeting == nil ? "添加" : "保存")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(topic.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 560)
        .onAppear { syncDraft() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(meeting == nil ? "新增会议纪要" : "编辑会议纪要")
                .font(.title2).bold()

            VStack(alignment: .leading, spacing: 4) {
                Text("会议主题").font(.caption).foregroundStyle(.secondary)
                TextField("主题（必填）", text: $topic).textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("会议时间").font(.caption).foregroundStyle(.secondary)
                DatePicker("", selection: $timestamp)
                    .labelsHidden()
            }

            RecurrenceEditor(isOn: $isRecurring,
                             unit: $recurrenceUnit,
                             interval: $recurrenceInterval,
                             weekdays: $recurrenceWeekdays,
                             monthDays: $recurrenceMonthDays)

            VStack(alignment: .leading, spacing: 4) {
                Text("会议概要").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $summary)
                    .scrollContentBackground(.hidden)
                    .font(.body)
                    .frame(minHeight: 70)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
            }

            TagPicker(selected: $selectedTags)

            // 评审列表（可增删）
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("评审（\(validReviewCount)）").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        withAnimation { reviewDrafts.append(ReviewDraft()) }
                    } label: {
                        Label("添加评审", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless).font(.caption)
                }
                ForEach($reviewDrafts) { $draft in
                    reviewEditor(draft: $draft)
                }
                if reviewDrafts.isEmpty {
                    Text("点「添加评审」录入一个评审人的意见。")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func reviewEditor(draft: Binding<ReviewDraft>) -> some View {
        let idx = reviewDrafts.firstIndex { $0.id == draft.wrappedValue.id }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "person.circle").foregroundStyle(.tint).font(.caption)
                TextField("评审人", text: draft.reviewer)
                    .textFieldStyle(.roundedBorder)
                if let idx {
                    Button {
                        withAnimation { _ = reviewDrafts.remove(at: idx) }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .help("删除此评审")
                }
            }
            TextEditor(text: draft.opinion)
                .scrollContentBackground(.hidden)
                .font(.body)
                .frame(minHeight: 50)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary)
                .opacity(0.05)
        }
    }

    private func syncDraft() {
        guard let m = meeting else { return }
        topic = m.topic
        summary = m.summary
        timestamp = m.timestamp
        selectedTags = m.tags
        isRecurring = m.isRecurring
        recurrenceUnit = m.recurrenceUnit
        recurrenceInterval = m.recurrenceInterval
        recurrenceWeekdays = m.recurrenceWeekdays
        recurrenceMonthDays = m.recurrenceMonthDays
        reviewDrafts = m.orderedReviews.map { ReviewDraft(reviewer: $0.reviewer, opinion: $0.opinion) }
    }

    private func save() {
        let t = topic.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }

        // 清洗评审 drafts
        let cleaned = reviewDrafts
            .map { ReviewDraft(
                reviewer: $0.reviewer.trimmingCharacters(in: .whitespaces),
                opinion: $0.opinion.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.reviewer.isEmpty || !$0.opinion.isEmpty }

        if let m = meeting {
            m.topic = t
            m.summary = summary
            m.timestamp = timestamp
            m.tags = selectedTags
            m.isRecurring = isRecurring
            m.recurrenceUnit = recurrenceUnit
            m.recurrenceInterval = recurrenceInterval
            m.recurrenceWeekdays = recurrenceWeekdays
            m.recurrenceMonthDays = recurrenceMonthDays
            // 删除旧评审
            for r in m.reviews { context.delete(r) }
            // 插入新评审
            for (i, d) in cleaned.enumerated() {
                let r = Review(reviewer: d.reviewer, opinion: d.opinion, order: i)
                r.meeting = m
                context.insert(r)
            }
        } else {
            let m = Meeting(topic: t,
                            summary: summary,
                            timestamp: timestamp,
                            isRecurring: isRecurring,
                            recurrenceUnit: recurrenceUnit,
                            recurrenceInterval: recurrenceInterval,
                            recurrenceWeekdays: recurrenceWeekdays,
                            recurrenceMonthDays: recurrenceMonthDays)
            context.insert(m)
            m.tags = selectedTags
            for (i, d) in cleaned.enumerated() {
                let r = Review(reviewer: d.reviewer, opinion: d.opinion, order: i)
                r.meeting = m
                context.insert(r)
            }
        }
        onDone(true)
        dismiss()
    }
}
