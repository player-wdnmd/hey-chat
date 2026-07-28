import AVFoundation
import AVKit
import AppKit
import SwiftData
import SwiftUI

struct VideoWorkspaceView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AIModelConfiguration.sortOrder) private var models: [AIModelConfiguration]
    @Query(sort: \MediaRecord.createdAt, order: .reverse) private var mediaRecords: [MediaRecord]
    @ObservedObject var generation: VideoGenerationCoordinator

    @State private var selectedVideoModelID: UUID?
    @State private var prompt = ""
    @State private var referenceImages: [ImageInputFile] = []
    @State private var resolution: VideoResolution = .p720
    @State private var aspectRatio: VideoAspectRatio = .landscape16x9
    @State private var duration: VideoDuration = .seconds4
    @State private var isReferenceImporterPresented = false
    @State private var previewRecordID: UUID?
    @State private var deleteRequest: VideoDeleteRequest?
    @State private var isClearHistoryRequested = false

    private let fileStore = VideoFileStore()

    private var activeRecordID: UUID? {
        get { generation.activeRecordID }
        nonmutating set { generation.activeRecordID = newValue }
    }

    private var status: VideoWorkspaceStatus? {
        get { generation.status }
        nonmutating set { generation.status = newValue }
    }

    private var requestStartedAt: Date? {
        generation.requestStartedAt
    }

    private var videoModels: [AIModelConfiguration] {
        ModelConfigurationStore.sorted(models.filter {
            $0.isEnabled
                && $0.hasSupportedCategory
                && $0.category == .video
                && $0.provider == .openAICompatible
        })
    }

    private var videoModelRevision: [String] {
        videoModels.map {
            "\($0.id.uuidString)|\($0.modelIdentifier)|\($0.isDefault)|\($0.sortOrder)"
        }
    }

    private var selectedVideoModel: AIModelConfiguration? {
        ModelConfigurationStore.preferredModel(
            in: .video,
            selectedID: selectedVideoModelID,
            from: models
        )
    }

    private var selectedModelCapabilities: VideoModelCapabilities {
        VideoModelCapabilities.resolve(for: selectedVideoModel?.modelIdentifier ?? "")
    }

    private var videoRecords: [MediaRecord] {
        mediaRecords.filter { $0.mediaKindRawValue == MediaKind.video.rawValue }
    }

    private var activeRecord: MediaRecord? {
        guard let activeRecordID else { return nil }
        return videoRecords.first { $0.id == activeRecordID }
    }

    private var previewRecord: MediaRecord? {
        guard let previewRecordID else { return nil }
        return videoRecords.first { $0.id == previewRecordID }
    }

    private var isBusy: Bool {
        generation.isBusy
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                statusView
                responsiveWorkspace
                historyPanel
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 30)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
        .task {
            synchronizeSelectedModel()
            synchronizeActiveRecord()
        }
        .onChange(of: videoModelRevision) { _, _ in
            synchronizeSelectedModel()
        }
        .onChange(of: selectedVideoModelID) { _, _ in
            synchronizeGenerationOptions()
        }
        .onChange(of: videoRecords.map(\.id)) { _, _ in
            synchronizeActiveRecord()
        }
        .fileImporter(
            isPresented: $isReferenceImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true,
            onCompletion: importReferenceImages
        )
        .alert(item: $deleteRequest) { request in
            Alert(
                title: Text("删除视频？"),
                message: Text(request.message),
                primaryButton: .destructive(Text("删除")) {
                    deleteRecord(id: request.recordID)
                },
                secondaryButton: .cancel()
            )
        }
        .alert("清空视频历史？", isPresented: $isClearHistoryRequested) {
            Button("清空", role: .destructive, action: clearVideoHistory)
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除 \(videoRecords.count) 条本机视频记录及其保存的文件。")
        }
        .sheet(isPresented: Binding(
            get: { previewRecord != nil },
            set: { if !$0 { previewRecordID = nil } }
        )) {
            if let previewRecord {
                VideoPreviewSheet(record: previewRecord, fileStore: fileStore)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Videos")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(Color.white.opacity(0.82))

                Text("视频工具")
                    .font(.system(size: 25, weight: .heavy))
                    .foregroundStyle(.white)
            }

            Spacer()

            if isBusy {
                Button(action: { cancelRequest(showStatus: true) }) {
                    Label("停止", systemImage: "stop.fill")
                }
                .buttonStyle(AeroPrimaryButtonStyle())
            } else {
                Label("\(videoRecords.count) 条本机记录", systemImage: "film.stack")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.88))
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .background {
            LinearGradient(
                colors: [AeroTheme.sky, AeroTheme.deepSky, AeroTheme.leaf],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.68), lineWidth: 1)
        }
        .shadow(color: AeroTheme.deepSky.opacity(0.18), radius: 16, y: 8)
    }

    @ViewBuilder
    private var statusView: some View {
        if let status {
            HStack(spacing: 9) {
                Image(systemName: status.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                Text(status.message)
                    .textSelection(.enabled)
                Spacer()
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(status.isError ? AeroTheme.destructive : AeroTheme.deepLeaf)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(Color.white.opacity(0.58))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var responsiveWorkspace: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                requestPanel
                    .frame(minWidth: 350, idealWidth: 390, maxWidth: 420)
                resultPanel
                    .frame(minWidth: 410, maxWidth: .infinity)
            }

            VStack(spacing: 24) {
                requestPanel
                resultPanel
            }
        }
    }

    private var requestPanel: some View {
        VStack(alignment: .leading, spacing: 17) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Request")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(AeroTheme.deepLeaf)
                Text("生成视频")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(AeroTheme.text)
            }

            modelPicker

            VStack(alignment: .leading, spacing: 7) {
                fieldLabel("提示词")
                TextEditor(text: $prompt)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(height: 150)
                    .padding(8)
                    .videoInputSurface()
                    .disabled(isBusy)
            }

            referenceImageSection
            generationControls

            Button(action: submitRequest) {
                Label("生成视频", systemImage: "sparkles.rectangle.stack")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AeroPrimaryButtonStyle())
            .disabled(
                isBusy
                    || selectedVideoModel == nil
                    || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        .padding(24)
        .aeroGlass(cornerRadius: 24)
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                fieldLabel("视频模型")
                Spacer()
                if !videoModels.isEmpty {
                    Text("\(videoModels.count) 个可用")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AeroTheme.faintText)
                }
            }

            if videoModels.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "video.badge.exclamationmark")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(AeroTheme.deepSky)
                        .frame(width: 40, height: 40)
                        .background(AeroTheme.sky.opacity(0.16))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("暂无可用视频模型")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(AeroTheme.text)
                        Text("请先在模型管理中新增并启用 OpenAI 兼容视频模型。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(AeroTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
                .padding(13)
                .frame(maxWidth: .infinity, minHeight: 76)
                .videoModelSurface(isSelected: false)
            } else {
                Menu {
                    ForEach(videoModels) { model in
                        Button {
                            selectedVideoModelID = model.id
                        } label: {
                            Label(
                                model.displayName,
                                systemImage: selectedVideoModelID == model.id
                                    ? "checkmark.circle.fill"
                                    : "video.fill"
                            )
                        }
                    }
                } label: {
                    if let model = selectedVideoModel {
                        selectedVideoModelCard(model)
                    } else {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在选择视频模型")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AeroTheme.secondaryText)
                            Spacer()
                        }
                        .padding(13)
                        .frame(maxWidth: .infinity, minHeight: 76)
                        .videoModelSurface(isSelected: false)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .disabled(isBusy)
                .help("选择视频模型")

                if let model = selectedVideoModel, !model.modelDescription.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(AeroTheme.deepSky)
                            .padding(.top, 1)
                        Text(model.modelDescription)
                            .font(.system(size: 10.5))
                            .foregroundStyle(AeroTheme.secondaryText)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }

    private func selectedVideoModelCard(_ model: AIModelConfiguration) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [AeroTheme.sky.opacity(0.72), AeroTheme.leaf.opacity(0.66)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "video.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: AeroTheme.deepSky.opacity(0.24), radius: 3, y: 1)
            }
            .frame(width: 44, height: 44)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.76), lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(AeroTheme.text)
                        .lineLimit(1)

                    if model.isDefault {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color(red: 0.92, green: 0.62, blue: 0.12))
                            .help("默认视频模型")
                    }
                }

                Text(model.modelIdentifier)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(AeroTheme.secondaryText)
                    .lineLimit(1)

                Label(model.provider.displayName, systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(AeroTheme.deepLeaf)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(AeroTheme.deepSky)
                .frame(width: 24, height: 24)
                .background(AeroTheme.sky.opacity(0.12))
                .clipShape(Circle())
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .contentShape(Rectangle())
        .videoModelSurface(isSelected: true)
    }

    private var referenceImageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                fieldLabel("参考图（可选）")
                Spacer()
                Text("\(referenceImages.count)/\(ImageInputLoader.maximumFileCount)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AeroTheme.faintText)
            }

            Button {
                isReferenceImporterPresented = true
            } label: {
                Label("添加参考图", systemImage: "photo.badge.plus")
            }
            .buttonStyle(.bordered)
            .disabled(isBusy || referenceImages.count >= ImageInputLoader.maximumFileCount)

            if !referenceImages.isEmpty {
                referenceImageStrip
            }
        }
    }

    private var referenceImageStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(Array(referenceImages.enumerated()), id: \.element.id) { index, input in
                    VideoReferenceImageTile(
                        input: input,
                        canMoveBackward: index > 0,
                        canMoveForward: index < referenceImages.count - 1,
                        isDisabled: isBusy,
                        moveBackward: { moveReferenceImage(at: index, offset: -1) },
                        moveForward: { moveReferenceImage(at: index, offset: 1) },
                        remove: { referenceImages.removeAll { $0.id == input.id } }
                    )
                }
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 5)
        }
        .scrollIndicators(.hidden)
        .frame(height: 108)
    }

    private var generationControls: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 7) {
                fieldLabel("分辨率")
                Picker("分辨率", selection: $resolution) {
                    ForEach(selectedModelCapabilities.resolutions) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(isBusy)
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    fieldLabel("画幅")
                    Picker("画幅", selection: $aspectRatio) {
                        ForEach(selectedModelCapabilities.aspectRatios) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(isBusy)
                }

                VStack(alignment: .leading, spacing: 7) {
                    fieldLabel("时长")
                    Picker("时长", selection: $duration) {
                        ForEach(selectedModelCapabilities.durations) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(isBusy)
                }
                .frame(minWidth: 122)
            }
        }
    }

    private var resultPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Result")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(AeroTheme.deepLeaf)
                    Text("返回结果")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(AeroTheme.text)
                }
                Spacer()
                if let activeRecord, !isBusy {
                    resultActions(for: activeRecord)
                }
            }

            Group {
                if isBusy {
                    loadingResult
                } else if let activeRecord {
                    activeResult(activeRecord)
                } else {
                    ContentUnavailableView(
                        "尚未生成视频",
                        systemImage: "video.badge.plus",
                        description: Text("新的视频结果会保存到这台 Mac 的本机媒体库。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 390)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(24)
        .aeroGlass(cornerRadius: 24)
    }

    private var loadingResult: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("正在生成视频")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(AeroTheme.text)
            if let requestStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = max(0, Int(context.date.timeIntervalSince(requestStartedAt)))
                    Text("已等待 \(elapsed) 秒")
                        .font(.system(size: 11))
                        .foregroundStyle(AeroTheme.secondaryText)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 390)
    }

    private func activeResult(_ record: MediaRecord) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            if let url = playableURL(for: record) {
                LocalVideoPlayer(url: url)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.6), lineWidth: 1)
                    }
            } else {
                ContentUnavailableView(
                    "本机文件不可用",
                    systemImage: "exclamationmark.triangle",
                    description: Text("这条记录仍在历史中，但对应的视频文件已不存在。")
                )
                .frame(maxWidth: .infinity, minHeight: 280)
            }

            Text(record.prompt)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AeroTheme.text)
                .lineLimit(3)
                .textSelection(.enabled)

            Text("\(record.modelDisplayName) · \(record.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 10.5))
                .foregroundStyle(AeroTheme.secondaryText)
                .lineLimit(1)

            if !record.resultSummary.isEmpty {
                Text(record.resultSummary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(AeroTheme.faintText)
                    .lineLimit(2)
            }
        }
    }

    private func resultActions(for record: MediaRecord) -> some View {
        HStack(spacing: 4) {
            Button {
                previewRecordID = record.id
            } label: {
                Image(systemName: "play.rectangle")
            }
            .buttonStyle(.borderless)
            .help("打开视频预览")
            .disabled(!fileStore.fileExists(relativePath: record.localRelativePath))

            Button {
                revealInFinder(record)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("在 Finder 中显示")
            .disabled(!fileStore.fileExists(relativePath: record.localRelativePath))

            Button {
                exportRecord(record)
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .help("导出副本")
            .disabled(!fileStore.fileExists(relativePath: record.localRelativePath))

            Button(role: .destructive) {
                deleteRequest = VideoDeleteRequest(record: record)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除视频")
        }
    }

    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Library")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(AeroTheme.deepLeaf)
                    Text("本机视频库")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(AeroTheme.text)
                }
                Spacer()
                Text("\(videoRecords.count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AeroTheme.secondaryText)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(AeroTheme.sky.opacity(0.2))
                    .clipShape(Circle())

                if !videoRecords.isEmpty {
                    Button("清空", systemImage: "trash") {
                        isClearHistoryRequested = true
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(AeroTheme.destructive)
                }
            }

            if videoRecords.isEmpty {
                ContentUnavailableView("暂无视频记录", systemImage: "film.stack")
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 180, maximum: 246), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(videoRecords) { record in
                        videoHistoryCard(record)
                    }
                }
            }
        }
        .padding(22)
        .aeroGlass(cornerRadius: 24)
    }

    private func videoHistoryCard(_ record: MediaRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                activeRecordID = record.id
                status = nil
            } label: {
                VideoHistoryThumbnail(url: playableURL(for: record))
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("查看这条视频记录")

            Text(record.prompt)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AeroTheme.text)
                .lineLimit(2)

            HStack(spacing: 5) {
                Text(record.modelDisplayName)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    previewRecordID = record.id
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .help("预览视频")
                .disabled(!fileStore.fileExists(relativePath: record.localRelativePath))

                Button(role: .destructive) {
                    deleteRequest = VideoDeleteRequest(record: record)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除视频")
            }
            .font(.system(size: 10))
            .foregroundStyle(AeroTheme.secondaryText)
        }
        .padding(10)
        .background(Color.white.opacity(activeRecordID == record.id ? 0.72 : 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AeroTheme.deepSky.opacity(activeRecordID == record.id ? 0.34 : 0.12), lineWidth: 1)
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(AeroTheme.secondaryText)
    }

    private func synchronizeSelectedModel() {
        guard let preferred = ModelConfigurationStore.preferredModel(
            in: .video,
            selectedID: selectedVideoModelID,
            from: models
        ) else {
            selectedVideoModelID = nil
            return
        }
        selectedVideoModelID = preferred.id
        synchronizeGenerationOptions(for: preferred)
    }

    private func synchronizeGenerationOptions(for model: AIModelConfiguration? = nil) {
        let identifier = model?.modelIdentifier ?? selectedVideoModel?.modelIdentifier ?? ""
        let capabilities = VideoModelCapabilities.resolve(for: identifier)
        if !capabilities.resolutions.contains(resolution),
           let first = capabilities.resolutions.first {
            resolution = first
        }
        if !capabilities.aspectRatios.contains(aspectRatio),
           let first = capabilities.aspectRatios.first {
            aspectRatio = first
        }
        if !capabilities.durations.contains(duration),
           let first = capabilities.durations.first {
            duration = first
        }
    }

    private func synchronizeActiveRecord() {
        if let activeRecordID,
           videoRecords.contains(where: { $0.id == activeRecordID }) {
            return
        }
        activeRecordID = videoRecords.first?.id
    }

    private func importReferenceImages(_ result: Result<[URL], Error>) {
        guard !isBusy else { return }
        do {
            let urls = try result.get()
            let remaining = ImageInputLoader.maximumFileCount - referenceImages.count
            guard remaining > 0 else {
                status = .failure("一次最多使用 \(ImageInputLoader.maximumFileCount) 张参考图。")
                return
            }
            let loaded = try urls.prefix(remaining).map { url in
                try ImageInputLoader.load(url: url)
            }
            let unique = loaded.filter { candidate in
                !referenceImages.contains {
                    $0.fileName == candidate.fileName && $0.data == candidate.data
                }
            }
            referenceImages.append(contentsOf: unique)
            if urls.count > remaining {
                status = .success("最多保留 \(ImageInputLoader.maximumFileCount) 张参考图，超出的文件未添加。")
            } else if unique.isEmpty, !urls.isEmpty {
                status = .success("所选参考图已存在。")
            } else {
                status = nil
            }
        } catch is CancellationError {
            return
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func moveReferenceImage(at index: Int, offset: Int) {
        let destination = index + offset
        guard referenceImages.indices.contains(index),
              referenceImages.indices.contains(destination) else { return }
        referenceImages.swapAt(index, destination)
    }

    private func submitRequest() {
        guard !isBusy, let model = selectedVideoModel else {
            status = .failure("请先选择可用的视频模型。")
            return
        }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            status = .failure("请先输入视频提示词。")
            return
        }

        let request = VideoToolRequest(
            prompt: trimmedPrompt,
            duration: duration,
            resolution: resolution,
            aspectRatio: aspectRatio,
            referenceImages: referenceImages
        )
        let target = VideoModelTarget(model: model)
        _ = generation.start(
            request: request,
            target: target,
            prompt: trimmedPrompt,
            modelContext: modelContext
        )
    }

    private func cancelRequest(showStatus: Bool) {
        generation.cancel(showStatus: showStatus)
    }

    private func deleteRecord(id: UUID) {
        guard let record = videoRecords.first(where: { $0.id == id }) else { return }
        let staged: StagedVideoFile?
        do {
            staged = try stageFileForDeletion(record)
        } catch {
            status = .failure("删除视频失败：\(error.localizedDescription)")
            return
        }

        modelContext.delete(record)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            do {
                try restoreStagedFile(staged)
                status = .failure("删除视频失败：\(error.localizedDescription)")
            } catch let restoreError {
                status = .failure(
                    "删除记录失败，视频文件暂时留在恢复区；下次启动会重试。"
                        + " 数据错误：\(error.localizedDescription)"
                        + " 文件错误：\(restoreError.localizedDescription)"
                )
            }
            return
        }

        if activeRecordID == id {
            activeRecordID = videoRecords.first(where: { $0.id != id })?.id
        }
        if previewRecordID == id {
            previewRecordID = nil
        }

        do {
            try discardStagedFile(staged)
            status = .success("视频记录已删除。")
        } catch {
            status = .success("视频记录已删除；暂存文件将在下次启动时自动清理。")
        }
    }

    private func clearVideoHistory() {
        let records = videoRecords
        guard !records.isEmpty else { return }
        var stagedFiles: [StagedVideoFile?] = []

        do {
            for record in records {
                stagedFiles.append(try stageFileForDeletion(record))
            }
        } catch {
            for stagedFile in stagedFiles.reversed() {
                try? restoreStagedFile(stagedFile)
            }
            status = .failure("清空视频历史失败：\(error.localizedDescription)")
            return
        }

        records.forEach { record in
            modelContext.delete(record)
        }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            var restoreFailures = 0
            for stagedFile in stagedFiles.reversed() {
                do {
                    try restoreStagedFile(stagedFile)
                } catch {
                    restoreFailures += 1
                }
            }
            if restoreFailures > 0 {
                status = .failure(
                    "清空记录失败，\(restoreFailures) 个视频文件暂时留在恢复区；下次启动会重试。"
                        + " 数据错误：\(error.localizedDescription)"
                )
            } else {
                status = .failure("清空视频历史失败：\(error.localizedDescription)")
            }
            return
        }

        let cleanupFailures = stagedFiles.reduce(into: 0) { failures, stagedFile in
            do {
                try discardStagedFile(stagedFile)
            } catch {
                failures += 1
            }
        }
        activeRecordID = nil
        previewRecordID = nil
        if cleanupFailures == 0 {
            status = .success("本机视频历史已清空。")
        } else {
            status = .success("视频历史已清空；\(cleanupFailures) 个暂存文件将在下次启动时自动清理。")
        }
    }

    private func stageFileForDeletion(_ record: MediaRecord) throws -> StagedVideoFile? {
        guard fileStore.fileExists(relativePath: record.localRelativePath) else { return nil }
        return try fileStore.stageForDeletion(relativePath: record.localRelativePath)
    }

    private func restoreStagedFile(_ stagedFile: StagedVideoFile?) throws {
        guard let stagedFile else { return }
        try fileStore.restore(stagedFile)
    }

    private func discardStagedFile(_ stagedFile: StagedVideoFile?) throws {
        guard let stagedFile else { return }
        try fileStore.discard(stagedFile)
    }

    private func playableURL(for record: MediaRecord) -> URL? {
        guard fileStore.fileExists(relativePath: record.localRelativePath) else { return nil }
        return try? fileStore.url(for: record.localRelativePath)
    }

    private func revealInFinder(_ record: MediaRecord) {
        guard let url = playableURL(for: record) else {
            status = .failure("无法找到视频文件。")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func exportRecord(_ record: MediaRecord) {
        guard let sourceURL = playableURL(for: record) else {
            status = .failure("无法找到视频文件。")
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = sourceURL.lastPathComponent
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try fileStore.export(relativePath: record.localRelativePath, to: destination)
            status = .success("视频副本已导出。")
        } catch {
            status = .failure("导出视频失败：\(error.localizedDescription)")
        }
    }
}

private struct VideoDeleteRequest: Identifiable {
    let recordID: UUID
    let prompt: String

    var id: UUID { recordID }

    init(record: MediaRecord) {
        self.recordID = record.id
        self.prompt = record.prompt
    }

    var message: String {
        let preview = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if preview.isEmpty {
            return "对应的本机视频文件也会被删除。"
        }
        return "“\(String(preview.prefix(48)))”及对应的本机视频文件会被删除。"
    }
}

private struct VideoReferenceImageTile: View {
    let input: ImageInputFile
    let canMoveBackward: Bool
    let canMoveForward: Bool
    let isDisabled: Bool
    let moveBackward: () -> Void
    let moveForward: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = NSImage(data: input.data) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 23, weight: .light))
                            .foregroundStyle(AeroTheme.faintText)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.white.opacity(0.5))
                    }
                }
                .frame(width: 70, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(AeroTheme.deepSky.opacity(0.18), lineWidth: 1)
                }

                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(AeroTheme.destructive)
                }
                .buttonStyle(.borderless)
                .help("移除 \(input.fileName)")
                .disabled(isDisabled)
                .offset(x: 6, y: -6)
            }

            HStack(spacing: 12) {
                Button(action: moveBackward) {
                    Image(systemName: "chevron.left")
                }
                .disabled(isDisabled || !canMoveBackward)
                .help("向前移动")

                Button(action: moveForward) {
                    Image(systemName: "chevron.right")
                }
                .disabled(isDisabled || !canMoveForward)
                .help("向后移动")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 9, weight: .bold))
        }
        .frame(width: 78)
    }
}

private struct LocalVideoPlayer: View {
    let url: URL

    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                ZStack {
                    Color.black.opacity(0.78)
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }
            }
        }
        .background(Color.black.opacity(0.82))
        .task(id: url) {
            player?.pause()
            player = AVPlayer(url: url)
        }
        .onDisappear {
            player?.pause()
        }
    }
}

private struct VideoHistoryThumbnail: View {
    let url: URL?

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.black.opacity(0.68)
                Image(systemName: url == nil ? "video.slash" : "video")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.72))
            }

            Circle()
                .fill(Color.black.opacity(0.46))
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .offset(x: 1)
                }
        }
        .clipped()
        .task(id: url) {
            image = await makeThumbnail(url: url)
        }
    }

    private func makeThumbnail(url: URL?) async -> NSImage? {
        guard let url else { return nil }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = NSSize(width: 560, height: 320)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        guard let (cgImage, _) = try? await generator.image(at: time) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}

private struct VideoPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let record: MediaRecord
    let fileStore: VideoFileStore

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.modelDisplayName)
                        .font(.system(size: 13, weight: .bold))
                    Text(record.prompt)
                        .font(.system(size: 11))
                        .foregroundStyle(AeroTheme.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("关闭预览")
            }

            if let url = try? fileStore.url(for: record.localRelativePath),
               fileStore.fileExists(relativePath: record.localRelativePath) {
                LocalVideoPlayer(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("本机视频不可用", systemImage: "video.slash")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 560)
    }
}

private extension View {
    func videoInputSurface() -> some View {
        background(Color.white.opacity(0.62))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AeroTheme.deepSky.opacity(0.16), lineWidth: 1)
            }
    }

    func videoModelSurface(isSelected: Bool) -> some View {
        background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(isSelected ? 0.72 : 0.58))
                .overlay {
                    LinearGradient(
                        colors: [AeroTheme.sky.opacity(0.1), AeroTheme.mint.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isSelected ? AeroTheme.deepSky.opacity(0.3) : AeroTheme.deepSky.opacity(0.16),
                    lineWidth: 1
                )
        }
        .shadow(color: AeroTheme.deepSky.opacity(isSelected ? 0.1 : 0), radius: 7, y: 3)
    }
}
