import SwiftUI

/// 会议纪要：列表 + 新增/编辑
struct MeetingView: View {
    @Environment(\.appStore) private var store
    @Environment(NavigationCoordinator.self) private var coordinator

    @State private var editing: MeetingRecord?
    @State private var creating = false

    private var meetings: [MeetingRecord] { store?.meetings ?? [] }

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
    @Environment(\.appStore) private var store
    let meeting: MeetingRecord
    var onEdit: () -> Void

    @State private var isAddingReview = false
    @State private var newReviewer = ""
    @State private var newOpinion = ""
    /// 写失败反馈：saveAdd 走 throw-aware 入口，避免 store?.run 吞 throws 后 UI 假成功
    /// R21-C：summary 内联编辑的 writeError 已搬到 InlineSummaryEditor
    @State private var writeError: String?

    private var tags: [TagRecord] { store?.tagsByMeeting[meeting.id] ?? [] }
    private var reviews: [ReviewRecord] { store?.reviewsByMeeting[meeting.id] ?? [] }

    private var validReviews: [ReviewRecord] {
        Self.validReviews(from: reviews)
    }

    /// 过滤 + 排序的纯函数核心：丢弃 reviewer/opinion 双空的占位行（用户点了添加又没填），
    /// 再按 order 升序稳定排列。R44-A：从 instance 抽 static 让单测可覆盖两段语义。
    /// 改坏会让空评审污染卡片（标题显示「评审（3）」但实际只有 1 条），或顺序错乱
    static func validReviews(from reviews: [ReviewRecord]) -> [ReviewRecord] {
        reviews.filter { !$0.reviewer.isEmpty || !$0.opinion.isEmpty }
            .sorted { $0.order < $1.order }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "person.3.fill").foregroundStyle(.tint)
                Text(meeting.topic).font(.headline)
                if meeting.isRecurring {
                    BadgeChip.recurrence(meeting.recurrenceLabel, color: .purple)
                }
                Spacer()
                Text(meeting.timestamp.relativeTime)
                    .font(.caption).foregroundStyle(.tertiary)
            }
            summaryEditor
            if !tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(tags) { tag in
                        BadgeChip.tag(tag)
                    }
                }
            }
            let list = validReviews
            if !list.isEmpty || isAddingReview {
                VStack(alignment: .leading, spacing: 8) {
                    Text("评审（\(list.count)）")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(list) { r in
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
        .softCard(color: Color.accentColor, cornerRadius: 10, fillOpacity: 0.06, strokeOpacity: 0.2)
        .writeErrorAlert($writeError)
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
                .font(.caption)
                .textEditorCard(minHeight: 38, padding: 4)
            HStack {
                Spacer()
                Button {
                    saveAdd()
                } label: {
                    Label("添加", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(newReviewer.isBlank && newOpinion.isBlank)
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
        let r = newReviewer.trimmed
        let o = newOpinion.trimmed
        guard !r.isEmpty || !o.isEmpty else { cancelAdd(); return }
        let ok = write({ try $0.addReview(to: meeting.id, reviewer: r, opinion: o) })
        guard ok else { return }   // 写失败时保留草稿，让用户重试或修改
        newReviewer = ""
        newOpinion = ""
        withAnimation(.easeInOut(duration: 0.18)) { isAddingReview = false }
    }

    /// 统一写入口：返回 true 表示成功，失败时弹 alert 反馈（与 WorkEntryCard/TagPicker 同模式）
    /// R23-D：主体逻辑抽到共享 `performWrite`
    @discardableResult
    private func write(_ block: (AppStore) throws -> Void) -> Bool {
        performWrite(in: store, error: &writeError, block)
    }

    private func cancelAdd() {
        newReviewer = ""
        newOpinion = ""
        withAnimation(.easeInOut(duration: 0.18)) { isAddingReview = false }
    }

    /// 概要：未来会议可随时内联编辑；已完成（timestamp ≤ 现在）的会议只读，避免误改
    /// R21-C：内联编辑器抽到 InlineSummaryEditor，本视图只保留只读分支
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
            InlineSummaryEditor(meeting: meeting, style: .standard)
        }
    }

    @ViewBuilder
    private func reviewBlock(_ r: ReviewRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !r.reviewer.isEmpty {
                Label(r.reviewer, systemImage: "person.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            if !r.opinion.isEmpty {
                Text("「\(r.opinion)」")
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
    @Environment(\.appStore) private var store
    @Environment(\.dismiss) private var dismiss

    var meeting: MeetingRecord?
    var onDone: (Bool) -> Void

    @State private var topic = ""
    @State private var summary = ""
    @State private var timestamp = Date()
    @State private var selectedTags: [TagRecord] = []
    @State private var reviewDrafts: [ReviewDraft] = []
    @State private var isRecurring = false
    @State private var recurrenceUnit: RecurrenceUnit = .daily
    @State private var recurrenceInterval = 1
    @State private var recurrenceWeekdays: [Int] = []
    @State private var recurrenceMonthDays: [Int] = []
    @State private var saveError: String?

    private var validReviewCount: Int {
        Self.validReviewCount(reviewDrafts)
    }

    /// 评审草稿有效计数的纯函数核心：过滤掉 reviewer+opinion 双空占位行后计数。
    /// R46-D：从 instance 抽 static 让单测可覆盖过滤契约。与 MeetingCard.validReviews 必须对称——
    /// 任一方改 isBlank 判定会让表单标题「评审（N）」与卡片显示数分叉。
    /// 改坏会让用户看到「评审（3）」但保存后只有 1 条
    static func validReviewCount(_ drafts: [ReviewDraft]) -> Int {
        drafts.filter { !$0.reviewer.isBlank || !$0.opinion.isBlank }.count
    }

    /// 评审草稿清洗的纯函数核心：trim 两字段 → 丢弃双空占位行 → enumerated 重排 order。
    /// R48-C：从 save() 抽 static 让单测可覆盖 trim/filter/order 三段语义。
    /// 改坏会让空评审被持久化（"评审（3）" 但实际全空）或顺序错乱（order 跳号或重复）
    static func cleanReviewDrafts(_ drafts: [ReviewDraft]) -> [NewReview] {
        drafts
            .map { ReviewDraft(reviewer: $0.reviewer.trimmed, opinion: $0.opinion.trimmed) }
            .filter { !$0.reviewer.isEmpty || !$0.opinion.isEmpty }
            .enumerated()
            .map { (idx, d) in NewReview(reviewer: d.reviewer, opinion: d.opinion, order: idx) }
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
                .disabled(topic.isBlank)
            }
            .padding(12)
        }
        .frame(width: 560)
        .onAppear { syncDraft() }
        .writeErrorAlert($saveError, title: "保存失败")
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
                    .font(.body)
                    .textEditorCard(minHeight: 70)
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
                .font(.body)
                .textEditorCard(minHeight: 50)
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
        selectedTags = store?.tagsByMeeting[m.id] ?? []
        isRecurring = m.isRecurring
        recurrenceUnit = m.recurrenceUnit
        recurrenceInterval = m.recurrenceInterval
        recurrenceWeekdays = m.recurrenceWeekdays
        recurrenceMonthDays = m.recurrenceMonthDays
        let existing = store?.reviewsByMeeting[m.id] ?? []
        reviewDrafts = existing
            .sorted { $0.order < $1.order }
            .map { ReviewDraft(reviewer: $0.reviewer, opinion: $0.opinion) }
    }

    /// @State 草稿 → record 写回。R33-F 抽出：save 原本内联 8 行 mutations 与 syncDraft 字段集
    /// 完全对称（topic/summary/timestamp + 4 个 recurrence 字段），新增字段必须同时改两处。
    /// 抽 helper 后只动 syncDraft + applyDraft 两端，不再扫整个 save 寻找遗漏点。
    /// 注意 topic 已在 save() 入口清洗为 trimmed，所以这里直接赋值。
    private func applyDraft(to rec: inout MeetingRecord) {
        rec.topic = topic.trimmed
        rec.summary = summary
        rec.timestamp = timestamp
        rec.isRecurring = isRecurring
        rec.recurrenceUnit = recurrenceUnit
        rec.recurrenceInterval = recurrenceInterval
        rec.recurrenceWeekdays = recurrenceWeekdays
        rec.recurrenceMonthDays = recurrenceMonthDays
    }

    private func save() {
        let t = topic.trimmed
        guard !t.isEmpty else { return }

        // 清洗评审 drafts（trim 双字段 → 丢弃双空占位行 → 重排 order）
        let cleaned = Self.cleanReviewDrafts(reviewDrafts)

        do {
            if let m = meeting {
                // 三步走独立事务（每步原子），任一失败后续不执行 + 抛错给用户
                // 不再用 store?.run 吞 throws 假装成功
                try store?.updateMeeting(m.id) { rec in
                    applyDraft(to: &rec)
                }
                try store?.setMeetingTags(m.id, tagIds: selectedTags.map(\.id))
                try store?.setMeetingReviews(meetingId: m.id, with: cleaned)
            } else {
                _ = try store?.insertMeeting(NewMeeting(
                    topic: t,
                    summary: summary,
                    timestamp: timestamp,
                    isRecurring: isRecurring,
                    recurrenceUnit: recurrenceUnit,
                    recurrenceInterval: recurrenceInterval,
                    recurrenceWeekdays: recurrenceWeekdays,
                    recurrenceMonthDays: recurrenceMonthDays,
                    tagIds: selectedTags.map(\.id),
                    reviews: cleaned
                ))
            }
        } catch {
            saveError = error.localizedDescription
            return
        }
        onDone(true)
        dismiss()
    }
}
