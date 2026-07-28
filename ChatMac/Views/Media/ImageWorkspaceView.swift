import AppKit
import ImageIO
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ImageWorkspaceView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AIModelConfiguration.sortOrder) private var models: [AIModelConfiguration]
    @Query(sort: \MediaRecord.createdAt, order: .reverse) private var mediaRecords: [MediaRecord]

    @State private var selectedImageModelID: UUID?
    @State private var selectedMode: ImageWorkspaceMode = .generate
    @State private var generatePrompt = ""
    @State private var processPrompt = ""
    @State private var processingMode: ImageProcessingMode = .compatible
    @State private var referenceImages: [ImageInputFile] = []
    @State private var maskImage: ImageInputFile?
    @State private var imageImportTarget: ImageImportTarget = .referenceImages
    @State private var isImageImporterPresented = false
    @State private var activeRecordID: UUID?
    @State private var previewRecordID: UUID?
    @State private var status: ImageWorkspaceStatus?
    @State private var deleteRequest: ImageDeleteRequest?
    @State private var isClearHistoryRequested = false
    @State private var requestTask: Task<Void, Never>?
    @State private var requestID: UUID?
    @State private var requestStartedAt: Date?

    private let imageService = ImageService()
    private let fileStore = ImageFileStore()

    private var imageModels: [AIModelConfiguration] {
        ModelConfigurationStore.sorted(models.filter {
            $0.isEnabled
                && $0.hasSupportedCategory
                && $0.category == .image
                && $0.provider == .openAICompatible
        })
    }

    private var selectedImageModel: AIModelConfiguration? {
        ModelConfigurationStore.preferredModel(
            in: .image,
            selectedID: selectedImageModelID,
            from: models
        )
    }

    private var imageRecords: [MediaRecord] {
        mediaRecords.filter(\.isImage)
    }

    private var activeRecord: MediaRecord? {
        guard let activeRecordID else { return nil }
        return imageRecords.first { $0.id == activeRecordID }
    }

    private var previewRecord: MediaRecord? {
        guard let previewRecordID else { return nil }
        return imageRecords.first { $0.id == previewRecordID }
    }

    private var isBusy: Bool {
        requestTask != nil
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
        }
        .onChange(of: models.map(\.id)) { _, _ in
            synchronizeSelectedModel()
        }
        .onDisappear {
            cancelRequest(showStatus: false)
        }
        .fileImporter(
            isPresented: $isImageImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: imageImportTarget == .referenceImages,
            onCompletion: importImages
        )
        .alert(item: $deleteRequest) { request in
            Alert(
                title: Text("删除图片？"),
                message: Text(request.message),
                primaryButton: .destructive(Text("删除")) {
                    deleteRecord(id: request.recordID)
                },
                secondaryButton: .cancel()
            )
        }
        .alert("清空图片历史？", isPresented: $isClearHistoryRequested) {
            Button("清空", role: .destructive, action: clearImageHistory)
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除 \(imageRecords.count) 条本机图片记录及其保存的文件。")
        }
        .sheet(isPresented: Binding(
            get: { previewRecord != nil },
            set: { if !$0 { previewRecordID = nil } }
        )) {
            if let previewRecord {
                ImagePreviewSheet(record: previewRecord, fileStore: fileStore)
            }
        }
    }

    private var header: some View {
        AeroWorkspaceHeader(
            eyebrow: "Media · Images",
            title: "图片工具",
            systemImage: "photo"
        ) {
            if isBusy {
                Button(action: { cancelRequest(showStatus: true) }) {
                    Label("停止", systemImage: "stop.fill")
                }
                .buttonStyle(AeroPrimaryButtonStyle())
            } else {
                Label("\(imageRecords.count) 条本机记录", systemImage: "photo.stack")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AeroTheme.secondaryText)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.54))
                    .clipShape(Capsule())
            }
        }
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
                    .frame(minWidth: 340, idealWidth: 380, maxWidth: 410)
                resultPanel
                    .frame(minWidth: 390, maxWidth: .infinity)
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
                Text(selectedMode.displayName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(AeroTheme.text)
            }

            Picker("图片操作", selection: $selectedMode) {
                ForEach(ImageWorkspaceMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(isBusy)

            modelPicker

            switch selectedMode {
            case .generate:
                generateForm
            case .process:
                processForm
            }
        }
        .padding(24)
        .aeroGlass(cornerRadius: 24)
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                fieldLabel("图片模型")
                Spacer()
                if !imageModels.isEmpty {
                    Text("\(imageModels.count) 个可用")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AeroTheme.faintText)
                }
            }

            if imageModels.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(AeroTheme.deepSky)
                        .frame(width: 40, height: 40)
                        .background(AeroTheme.sky.opacity(0.16))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("暂无可用图片模型")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(AeroTheme.text)
                        Text("请先在模型管理中新增并启用 OpenAI 兼容图片模型。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(AeroTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
                .padding(13)
                .frame(maxWidth: .infinity, minHeight: 76)
                .imageModelSurface(isSelected: false)
            } else {
                Menu {
                    ForEach(imageModels) { model in
                        Button {
                            selectedImageModelID = model.id
                        } label: {
                            Label(
                                "\(model.displayName) · \(model.mediaAPIKind.displayName)",
                                systemImage: selectedImageModelID == model.id
                                    ? "checkmark.circle.fill"
                                    : imageModelIcon(for: model)
                            )
                        }
                    }
                } label: {
                    if let model = selectedImageModel {
                        selectedImageModelCard(model)
                    } else {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在选择图片模型")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AeroTheme.secondaryText)
                            Spacer()
                        }
                        .padding(13)
                        .frame(maxWidth: .infinity, minHeight: 76)
                        .imageModelSurface(isSelected: false)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .disabled(isBusy)
                .help("选择图片模型")

                if let model = selectedImageModel, !model.modelDescription.isEmpty {
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

    private func selectedImageModelCard(_ model: AIModelConfiguration) -> some View {
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
                Image(systemName: imageModelIcon(for: model))
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
                            .help("默认图片模型")
                    }
                }

                Text(model.modelIdentifier)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(AeroTheme.secondaryText)
                    .lineLimit(1)

                Label(model.mediaAPIKind.displayName, systemImage: "point.3.connected.trianglepath.dotted")
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
        .imageModelSurface(isSelected: true)
    }

    private func imageModelIcon(for model: AIModelConfiguration) -> String {
        switch model.mediaAPIKind {
        case .imageGenerations:
            "photo.badge.plus"
        case .chatCompletions:
            "message.badge.waveform"
        case .videoGenerations:
            "video.badge.plus"
        }
    }

    private var generateForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                fieldLabel("提示词")
                TextEditor(text: $generatePrompt)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(height: 188)
                    .padding(8)
                    .imageInputSurface()
                    .disabled(isBusy)
            }

            Button(action: submitRequest) {
                Label("生成图片", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(AeroPrimaryButtonStyle())
            .disabled(isBusy || selectedImageModel == nil)
        }
    }

    private var processForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                fieldLabel("处理指令")
                TextEditor(text: $processPrompt)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .frame(height: 116)
                    .padding(8)
                    .imageInputSurface()
                    .disabled(isBusy)
            }

            referenceImageSection

            Toggle("使用 Images API 编辑", isOn: Binding(
                get: { processingMode == .edit },
                set: { isEnabled in
                    processingMode = isEnabled ? .edit : .compatible
                    if !isEnabled {
                        maskImage = nil
                    }
                }
            ))
            .toggleStyle(.checkbox)
            .disabled(isBusy || referenceImages.count != 1 || selectedImageModel?.mediaAPIKind != .imageGenerations)

            if processingMode == .edit {
                maskImageSection
            } else if selectedImageModel?.mediaAPIKind == .imageGenerations {
                Text("参考图处理需要选择 Chat Completions 图像模型。")
                    .font(.system(size: 11))
                    .foregroundStyle(AeroTheme.secondaryText)
            }

            Button(action: submitRequest) {
                Label(
                    processingMode == .edit ? "开始图片编辑" : "开始处理",
                    systemImage: processingMode == .edit ? "wand.and.stars.inverse" : "slider.horizontal.3"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(AeroPrimaryButtonStyle())
            .disabled(
                isBusy
                    || selectedImageModel == nil
                    || referenceImages.isEmpty
                    || (processingMode == .compatible
                        && selectedImageModel?.mediaAPIKind != .chatCompletions)
            )
        }
        .onChange(of: selectedImageModel?.id) { _, _ in
            if selectedImageModel?.mediaAPIKind != .imageGenerations {
                processingMode = .compatible
                maskImage = nil
            }
        }
        .onChange(of: referenceImages.count) { _, count in
            if count != 1 && processingMode == .edit {
                processingMode = .compatible
                maskImage = nil
            }
        }
    }

    private var referenceImageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                fieldLabel("参考图")
                Spacer()
                Text("\(referenceImages.count)/\(ImageInputLoader.maximumFileCount)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AeroTheme.faintText)
            }

            Button {
                imageImportTarget = .referenceImages
                isImageImporterPresented = true
            } label: {
                Label("添加参考图", systemImage: "photo.badge.plus")
            }
            .buttonStyle(.bordered)
            .disabled(isBusy || referenceImages.count >= ImageInputLoader.maximumFileCount)

            if !referenceImages.isEmpty {
                referenceImageStrip(referenceImages) { input in
                    referenceImages.removeAll { $0.id == input.id }
                }
            }
        }
    }

    private var maskImageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel("遮罩图（可选）")
            HStack(spacing: 10) {
                Button {
                    imageImportTarget = .mask
                    isImageImporterPresented = true
                } label: {
                    Label(maskImage == nil ? "选择遮罩图" : "更换遮罩图", systemImage: "circle.dotted")
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)

                if let maskImage {
                    InputImageThumbnail(input: maskImage, size: 56)
                    Button {
                        self.maskImage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("移除遮罩图")
                    .disabled(isBusy)
                }
                Spacer(minLength: 0)
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
                if let activeRecord {
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
                        "尚未生成图片",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("新的图片结果会保存到这台 Mac 的本机媒体库。")
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
            Text("正在处理图片")
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
            if fileStore.fileExists(relativePath: record.localRelativePath) {
                Button {
                    previewRecordID = record.id
                } label: {
                    LocalImagePreview(
                        relativePath: record.localRelativePath,
                        fileStore: fileStore,
                        maximumPixelSize: 1_600
                    )
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 280, maxHeight: 460)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("放大预览")
            } else {
                ContentUnavailableView(
                    "本机文件不可用",
                    systemImage: "exclamationmark.triangle",
                    description: Text("这条记录仍在历史中，但对应的图片文件已不存在。")
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
                deleteRequest = ImageDeleteRequest(record: record)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除图片")
        }
    }

    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Library")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(AeroTheme.deepLeaf)
                    Text("本机图片库")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(AeroTheme.text)
                }
                Spacer()
                Text("\(imageRecords.count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AeroTheme.secondaryText)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(AeroTheme.sky.opacity(0.2))
                    .clipShape(Circle())

                if !imageRecords.isEmpty {
                    Button("清空", systemImage: "trash") {
                        isClearHistoryRequested = true
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(AeroTheme.destructive)
                }
            }

            if imageRecords.isEmpty {
                ContentUnavailableView("暂无图片记录", systemImage: "photo.stack")
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 142, maximum: 192), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(imageRecords) { record in
                        imageHistoryCard(record)
                    }
                }
            }
        }
        .padding(22)
        .aeroGlass(cornerRadius: 24)
    }

    private func imageHistoryCard(_ record: MediaRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                activeRecordID = record.id
                status = nil
            } label: {
                LocalImagePreview(
                    relativePath: record.localRelativePath,
                    fileStore: fileStore,
                    maximumPixelSize: 280
                )
                .frame(maxWidth: .infinity)
                .frame(height: 116)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("查看这条图片记录")

            Text(record.prompt)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AeroTheme.text)
                .lineLimit(2)

            HStack(spacing: 5) {
                Text(record.modelDisplayName)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button(role: .destructive) {
                    deleteRequest = ImageDeleteRequest(record: record)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除图片")
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

    private func referenceImageStrip(
        _ images: [ImageInputFile],
        onRemove: @escaping (ImageInputFile) -> Void
    ) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(images) { input in
                    ZStack(alignment: .topTrailing) {
                        InputImageThumbnail(input: input, size: 64)
                        Button {
                            onRemove(input)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(AeroTheme.destructive)
                        }
                        .buttonStyle(.borderless)
                        .help("移除 \(input.fileName)")
                        .disabled(isBusy)
                        .offset(x: 6, y: -6)
                    }
                    .padding(4)
                }
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 5)
        }
        .scrollIndicators(.hidden)
        .frame(height: 82)
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(AeroTheme.secondaryText)
    }

    private func synchronizeSelectedModel() {
        guard let preferred = ModelConfigurationStore.preferredModel(
            in: .image,
            selectedID: selectedImageModelID,
            from: models
        ) else {
            selectedImageModelID = nil
            return
        }
        selectedImageModelID = preferred.id
    }

    private func importImages(_ result: Result<[URL], Error>) {
        switch imageImportTarget {
        case .referenceImages:
            importReferenceImages(result)
        case .mask:
            importMaskImage(result)
        }
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

    private func importMaskImage(_ result: Result<[URL], Error>) {
        guard !isBusy else { return }
        do {
            guard let url = try result.get().first else { return }
            maskImage = try ImageInputLoader.load(url: url)
            status = nil
        } catch is CancellationError {
            return
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func submitRequest() {
        guard !isBusy, let model = selectedImageModel else {
            status = .failure("请先选择可用的图片模型。")
            return
        }

        let request: ImageToolRequest
        switch selectedMode {
        case .generate:
            request = .generate(prompt: generatePrompt.trimmingCharacters(in: .whitespacesAndNewlines))
        case .process:
            request = .process(
                prompt: processPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                inputs: referenceImages,
                mode: processingMode,
                mask: maskImage
            )
        }

        let target = ImageModelTarget(model: model)
        let newRequestID = UUID()
        let recordID = UUID()
        requestID = newRequestID
        requestStartedAt = .now
        status = nil

        requestTask = Task {
            defer {
                if requestID == newRequestID {
                    requestTask = nil
                    requestID = nil
                    requestStartedAt = nil
                }
            }

            do {
                let result = try await imageService.perform(request, target: target, recordID: recordID)
                guard !Task.isCancelled, requestID == newRequestID else {
                    try? fileStore.remove(relativePath: result.localRelativePath)
                    return
                }

                let record = MediaRecord(
                    id: recordID,
                    mediaKind: .image,
                    operation: request.operation,
                    prompt: request.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                    modelIdentifier: target.modelIdentifier,
                    modelDisplayName: target.displayName,
                    localRelativePath: result.localRelativePath,
                    resultSummary: result.resultSummary,
                    responseJSON: result.responseJSON
                )
                modelContext.insert(record)
                do {
                    try modelContext.save()
                } catch {
                    modelContext.rollback()
                    try? fileStore.remove(relativePath: result.localRelativePath)
                    throw error
                }

                activeRecordID = record.id
                status = .success("图片已保存到本机媒体库。")
            } catch is CancellationError {
                guard requestID == newRequestID else { return }
                status = .success("图片请求已取消。")
            } catch {
                guard requestID == newRequestID else { return }
                status = .failure(error.localizedDescription)
            }
        }
    }

    private func cancelRequest(showStatus: Bool) {
        guard requestTask != nil else { return }
        requestTask?.cancel()
        if showStatus {
            status = .success("正在取消图片请求。")
        }
    }

    private func deleteRecord(id: UUID) {
        guard let record = imageRecords.first(where: { $0.id == id }) else { return }
        let staged: StagedImageFile?
        do {
            staged = try stageFileForDeletion(record)
        } catch {
            status = .failure("删除图片失败：\(error.localizedDescription)")
            return
        }

        modelContext.delete(record)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            try? restoreStagedFile(staged)
            status = .failure("删除图片失败：\(error.localizedDescription)")
            return
        }

        if activeRecordID == id {
            activeRecordID = nil
        }
        if previewRecordID == id {
            previewRecordID = nil
        }

        do {
            try discardStagedFile(staged)
            status = .success("图片记录已删除。")
        } catch {
            status = .success("图片记录已删除；暂存文件将在下次启动时自动清理。")
        }
    }

    private func clearImageHistory() {
        let records = imageRecords
        guard !records.isEmpty else { return }
        var stagedFiles: [StagedImageFile?] = []

        do {
            for record in records {
                stagedFiles.append(try stageFileForDeletion(record))
            }
        } catch {
            for stagedFile in stagedFiles.reversed() {
                try? restoreStagedFile(stagedFile)
            }
            status = .failure("清空图片历史失败：\(error.localizedDescription)")
            return
        }

        records.forEach { record in
            modelContext.delete(record)
        }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            for stagedFile in stagedFiles.reversed() {
                try? restoreStagedFile(stagedFile)
            }
            status = .failure("清空图片历史失败：\(error.localizedDescription)")
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
            status = .success("本机图片历史已清空。")
        } else {
            status = .success("图片历史已清空；\(cleanupFailures) 个暂存文件将在下次启动时自动清理。")
        }
    }

    private func stageFileForDeletion(_ record: MediaRecord) throws -> StagedImageFile? {
        guard fileStore.fileExists(relativePath: record.localRelativePath) else { return nil }
        return try fileStore.stageForDeletion(relativePath: record.localRelativePath)
    }

    private func restoreStagedFile(_ stagedFile: StagedImageFile?) throws {
        guard let stagedFile else { return }
        try fileStore.restore(stagedFile)
    }

    private func discardStagedFile(_ stagedFile: StagedImageFile?) throws {
        guard let stagedFile else { return }
        try fileStore.discard(stagedFile)
    }

    private func revealInFinder(_ record: MediaRecord) {
        guard let url = try? fileStore.url(for: record.localRelativePath) else {
            status = .failure("无法找到图片文件。")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func exportRecord(_ record: MediaRecord) {
        guard let sourceURL = try? fileStore.url(for: record.localRelativePath),
              FileManager.default.fileExists(atPath: sourceURL.path) else {
            status = .failure("无法找到图片文件。")
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = sourceURL.lastPathComponent
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try fileStore.export(relativePath: record.localRelativePath, to: destination)
            status = .success("图片副本已导出。")
        } catch {
            status = .failure("导出图片失败：\(error.localizedDescription)")
        }
    }
}

private enum ImageWorkspaceMode: String, CaseIterable, Identifiable {
    case generate
    case process

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .generate: "文字生图"
        case .process: "图像处理"
        }
    }
}

private enum ImageImportTarget {
    case referenceImages
    case mask
}

private struct ImageWorkspaceStatus {
    let message: String
    let isError: Bool

    static func success(_ message: String) -> ImageWorkspaceStatus {
        ImageWorkspaceStatus(message: message, isError: false)
    }

    static func failure(_ message: String) -> ImageWorkspaceStatus {
        ImageWorkspaceStatus(message: message, isError: true)
    }
}

private struct ImageDeleteRequest: Identifiable {
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
            return "对应的本机图片文件也会被删除。"
        }
        return "“\(String(preview.prefix(48)))”及对应的本机图片文件会被删除。"
    }
}

private struct InputImageThumbnail: View {
    let input: ImageInputFile
    let size: CGFloat

    var body: some View {
        Group {
            if let image = NSImage(data: input.data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: size * 0.35))
                    .foregroundStyle(AeroTheme.faintText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white.opacity(0.5))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(AeroTheme.deepSky.opacity(0.18), lineWidth: 1)
        }
    }
}

private struct LocalImagePreview: View {
    let relativePath: String
    let fileStore: ImageFileStore
    let maximumPixelSize: Int

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white.opacity(0.35))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(AeroTheme.faintText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white.opacity(0.35))
            }
        }
        .task(id: relativePath) {
            image = LocalImagePreview.loadThumbnail(
                relativePath: relativePath,
                fileStore: fileStore,
                maximumPixelSize: maximumPixelSize
            )
        }
    }

    private static func loadThumbnail(
        relativePath: String,
        fileStore: ImageFileStore,
        maximumPixelSize: Int
    ) -> NSImage? {
        guard let url = try? fileStore.url(for: relativePath),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: thumbnail, size: .zero)
    }
}

private struct ImagePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let record: MediaRecord
    let fileStore: ImageFileStore

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

            LocalImagePreview(
                relativePath: record.localRelativePath,
                fileStore: fileStore,
                maximumPixelSize: 3_000
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 520)
    }
}

private extension View {
    func imageInputSurface() -> some View {
        aeroInputSurface(cornerRadius: 10)
    }

    func imageModelSurface(isSelected: Bool) -> some View {
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
