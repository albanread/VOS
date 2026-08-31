//
//  ContentView.swift
//  VoiceOverStudio
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var viewModel: ProjectViewModel
    @EnvironmentObject private var uiState: AppUIState
    @State private var didApplyInitialPaneVisibility = false
    
    var body: some View {
        NavigationSplitView(columnVisibility: $uiState.splitVisibility) {
            settingsPane
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 360)
        } detail: {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(viewModel.jingleTimelineItems(after: nil)) { item in
                                JingleTimelineRow(
                                    title: "Jingle",
                                    startTime: viewModel.timelineStartText(for: item.id),
                                    duration: viewModel.timelineJingleDurationText(for: item.jingleCardID),
                                    onOpen: { viewModel.openTimelineJingle(item.id) },
                                    onRemove: { viewModel.removeTimelineJingle(item.id) }
                                )
                                .frame(maxWidth: 980)
                                .frame(maxWidth: .infinity, alignment: .center)
                            }

                            ForEach(viewModel.paragraphs) { paragraph in
                                VStack(alignment: .leading, spacing: 10) {
                                    ParagraphRow(paragraph: viewModel.paragraphBinding(paragraph.id),
                                                 voiceOptions: viewModel.voiceOptions,
                                                 isTTSReady: viewModel.isTTSReady,
                                                 isLLMReady: viewModel.isLLMReady,
                                                 viewModel: viewModel,
                                                 onGenerate: {
                                                     Task { await viewModel.generateAudio(for: paragraph.id) }
                                                 },
                                                 onPlay: {
                                                     viewModel.playAudio(for: paragraph.id)
                                                 },
                                                 onImprove: {
                                                     Task { await viewModel.improveText(for: paragraph.id) }
                                                 },
                                                 onRephrase: {
                                                     Task { await viewModel.rephraseText(for: paragraph.id) }
                                                 },
                                                 onDuplicate: {
                                                     viewModel.duplicateParagraph(paragraph.id)
                                                 },
                                                 onRemove: {
                                                     viewModel.removeParagraph(paragraph.id)
                                                 },
                                                 onConfigureVoice: {
                                                     viewModel.openVoiceConfiguration(for: paragraph.id)
                                                 },
                                                 onVoiceSelectionChanged: { selectedVoiceID in
                                                     viewModel.handleVoiceSelectionChange(for: paragraph.id, voiceID: selectedVoiceID)
                                                 })

                                    ForEach(viewModel.jingleTimelineItems(after: paragraph.id)) { item in
                                        JingleTimelineRow(
                                            title: "Jingle",
                                            startTime: viewModel.timelineStartText(for: item.id),
                                            duration: viewModel.timelineJingleDurationText(for: item.jingleCardID),
                                            onOpen: { viewModel.openTimelineJingle(item.id) },
                                            onRemove: { viewModel.removeTimelineJingle(item.id) }
                                        )
                                    }
                                }
                                .frame(maxWidth: 980)
                                .frame(maxWidth: .infinity, alignment: .center)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 16)
                    }
                    .defaultScrollAnchor(.top)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                    HStack(spacing: 8) {
                        if viewModel.isProcessing {
                            ProgressView().controlSize(.small)
                        }
                        Text(viewModel.statusMessage)
                            .font(.callout)
                            .foregroundStyle(viewModel.isProcessing ? .primary : .secondary)
                            .lineLimit(1)
                        Spacer()
                        Text("\(viewModel.paragraphs.filter { $0.audioPath != nil }.count) of \(viewModel.paragraphs.count) generated")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .overlay(
                        Rectangle()
                            .frame(height: 1)
                            .foregroundColor(Color.gray.opacity(0.2)),
                        alignment: .top
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if viewModel.isVoiceConfigurationPanePresented {
                    voiceConfigurationPane
                        .frame(width: 340)
                        .frame(maxHeight: .infinity)
                        .background(Color(NSColor.windowBackgroundColor))
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .frame(width: 1)
                                .foregroundStyle(Color.gray.opacity(0.2))
                        }
                        .shadow(color: .black.opacity(0.12), radius: 10, x: -2, y: 0)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: viewModel.isVoiceConfigurationPanePresented)
            .toolbar {
                ToolbarItemGroup {
                    Button(action: viewModel.addParagraph) {
                        Label("Add Paragraph", systemImage: "plus")
                    }
                    .help("Add a paragraph")

                    Button(action: {
                        Task { await viewModel.generateAllAudio() }
                    }) {
                        Label("Generate All", systemImage: "waveform.badge.plus")
                    }
                    .disabled(!viewModel.isTTSReady || viewModel.isProcessing)
                    .help("Synthesize audio for every paragraph")

                    Button(action: {
                        Task { await viewModel.exportFullSequence() }
                    }) {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .disabled(viewModel.paragraphs.isEmpty)
                    .help("Export the stitched sequence")

                    Button(action: viewModel.openJingleLibrary) {
                        Label("Jingles", systemImage: "music.note.list")
                    }
                    .help("Open the jingle library")

                    Menu {
                        Button("Save Transcript…") { viewModel.saveTranscript() }
                        Button("Load Transcript…") { viewModel.loadTranscript() }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .help("Transcript save and load")
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 620)
        .sheet(isPresented: $viewModel.isReferenceVoiceSheetPresented) {
            ReferenceVoiceEnrollmentSheet()
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $viewModel.isJingleLibrarySheetPresented) {
            JingleLibrarySheet()
                .environmentObject(viewModel)
        }
        .onChange(of: viewModel.voiceConfigurations) {
            viewModel.persistVoiceConfigurationStore()
            viewModel.refreshVoiceOptions()
        }
        .onChange(of: viewModel.jingleCards) {
            viewModel.persistJingleCardStore()
        }
        .onChange(of: viewModel.jingleTimelineItems) {
            viewModel.persistJingleTimelineStore()
        }
        .onAppear {
            guard !didApplyInitialPaneVisibility else { return }
            didApplyInitialPaneVisibility = true
            uiState.splitVisibility = viewModel.shouldHideSettingsPaneOnLaunch() ? .detailOnly : .all
        }
    }

    @ViewBuilder
    private var voiceConfigurationPane: some View {
        if viewModel.isEditingReferenceVoiceConfiguration {
            ReferenceVoicePaneSummary(closeAction: viewModel.closeVoiceConfigurationPane)
                .environmentObject(viewModel)
        } else if let index = viewModel.activeVoiceConfigurationIndex, viewModel.voiceConfigurations.indices.contains(index) {
            VoiceConfigurationPane(
                configuration: $viewModel.voiceConfigurations[index],
                baseVoiceOptions: viewModel.baseVoiceOptions,
                promptPreview: viewModel.voiceConfigurations[index].promptText,
                onDuplicate: viewModel.duplicateSelectedVoiceConfiguration,
                onClose: viewModel.closeVoiceConfigurationPane,
                onChanged: viewModel.persistVoiceConfigurationStore
            )
        } else {
            EmptyView()
        }
    }

    private var settingsPane: some View {
        Form {
            Section("Models") {
                Picker("Machine tier", selection: $viewModel.modelComputeTierRaw) {
                    ForEach(ProjectViewModel.ComputeTier.allCases) { tier in
                        Text(tier.title).tag(tier.rawValue)
                    }
                }
                .help("Chooses the recommended model pair for this Mac")

                LabeledContent("Recommended") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(viewModel.currentRecommendation.llmName)
                        Text(viewModel.currentRecommendation.ttsName)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                }
                .help(viewModel.currentRecommendation.rationale)

                Button("Auto-Detect This Mac") {
                    viewModel.autoDetectModelTier()
                }

                Button {
                    Task { await viewModel.autoSetup() }
                } label: {
                    Label("Download & Set Up Models", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isUpdatingModels)
                .help("Downloads the recommended models and initializes both engines")

                if viewModel.isUpdatingModels || !viewModel.modelUpdateNarrative.contains("Idle") {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: viewModel.modelUpdateProgress)
                        Text(viewModel.modelUpdateNarrative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Reference Voice") {
                Text(viewModel.referenceVoiceProfile == nil
                    ? "Record ~10 seconds of your voice to clone it as a speaker preset."
                    : "Enrolled and available in the paragraph voice picker.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(viewModel.referenceVoiceProfile == nil ? "Create Reference Voice…" : "Manage Reference Voice…") {
                    viewModel.openReferenceVoiceEnrollment()
                }
            }

            Section("Jingles") {
                Button("Open Jingle Library…") {
                    viewModel.openJingleLibrary()
                }
                .help("Reusable music cues for intros, transitions, bumpers, and outros")
            }

            Section("Project") {
                Button {
                    Task { await viewModel.exportFullSequence() }
                } label: {
                    Label("Export Full Sequence…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .disabled(viewModel.paragraphs.isEmpty)

                HStack {
                    Button("Save Transcript…") { viewModel.saveTranscript() }
                    Button("Load Transcript…") { viewModel.loadTranscript() }
                }
                .controlSize(.small)
            }

            Section("Defaults") {
                LabeledContent("Gap after paragraph (sec)") {
                    TextField("", value: $viewModel.defaultGap, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                        .labelsHidden()
                }

                Picker("Export format", selection: $viewModel.exportFormatRaw) {
                    Text("M4A (AAC)").tag(ProjectViewModel.ExportFormat.m4a.rawValue)
                    Text("WAV").tag(ProjectViewModel.ExportFormat.wav.rawValue)
                }
                .pickerStyle(.segmented)
            }

            Section {
                DisclosureGroup("Advanced") {
                    TextField("LLM download URL", text: $viewModel.modelUpdateURLLLM)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    TextField("Qwen TTS model repo", text: $viewModel.ttsModelRepo)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    HStack {
                        Button("Download Qwen Model") {
                            Task { await viewModel.downloadTTSModel() }
                        }
                        .disabled(viewModel.isUpdatingModels)
                        Button("Open Repo Page") {
                            viewModel.openTTSDownloadPage()
                        }
                    }
                    .controlSize(.small)
                    Button("Re-Initialize Engines") {
                        viewModel.initializeEngines()
                    }
                    .controlSize(.small)

                    Text("Models live in \(viewModel.managedModelsRootDisplay)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("Qwen cache: \(viewModel.ttsCacheDisplay)")
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct JingleLibrarySheet: View {
    @EnvironmentObject private var viewModel: ProjectViewModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Jingle Cards")
                        .font(.title3)
                        .fontWeight(.bold)
                    Spacer()
                    Menu("Add") {
                        ForEach(ABCJinglePreset.builtIn) { preset in
                            Button(preset.name) {
                                viewModel.addJingleCard(from: preset)
                            }
                        }
                        Divider()
                        Button("Blank Jingle") {
                            viewModel.addJingleCard(from: nil)
                        }
                    }
                }

                List(selection: Binding(get: {
                    viewModel.selectedJingleCardID
                }, set: { newValue in
                    viewModel.selectJingleCard(newValue)
                })) {
                    ForEach(viewModel.jingleCards) { card in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(card.name)
                            Text(card.promptSpec.cueRole.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(card.id)
                    }
                }

                HStack {
                    if let selectedID = viewModel.selectedJingleCardID {
                        Button("Duplicate") {
                            viewModel.duplicateJingleCard(selectedID)
                        }
                        Button("Remove") {
                            viewModel.removeJingleCard(selectedID)
                        }
                    }
                }
                .controlSize(.small)
            }
            .frame(width: 240)
            .padding(16)

            Divider()

            Group {
                if let index = viewModel.activeJingleCardIndex {
                    JingleCardEditor(card: $viewModel.jingleCards[index])
                } else {
                    ContentUnavailableView("No Jingle Selected", systemImage: "music.note")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 580)
    }
}

struct JingleCardEditor: View {
    @EnvironmentObject private var viewModel: ProjectViewModel
    @Binding var card: ABCJingleCard

    private var styleTagsText: Binding<String> {
        Binding(
            get: { card.promptSpec.styleTags.joined(separator: ", ") },
            set: { card.promptSpec.styleTags = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 12) {
                        TextField("Jingle name", text: $card.name)
                            .textFieldStyle(.roundedBorder)

                        TextField("Category", text: $card.category)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)

                        Picker("Role", selection: $card.promptSpec.cueRole) {
                            ForEach(ABCJingleCueRole.allCases, id: \.self) { role in
                                Text(role.description).tag(role)
                            }
                        }
                        .frame(width: 180)

                        Text("Seconds")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("2.0", value: $card.promptSpec.targetDurationSeconds, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 72)
                    }

                    HStack(alignment: .center, spacing: 12) {
                        TextField("Template notes", text: $card.promptSpec.promptText)
                            .textFieldStyle(.roundedBorder)
                        TextField("Style tags", text: styleTagsText)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 220)
                        Text("Speech safety: \(card.speechSafety.rawValue.capitalized)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(10)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Editable ABC")
                        .font(.headline)
                    TextEditor(text: $card.abcSource)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 320)
                        .padding(6)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)
                }

                HStack {
                    Menu("Add to Timeline") {
                        Button("Before first paragraph") {
                            viewModel.addJingleCardToTimeline(card.id, afterParagraphID: nil)
                        }

                        ForEach(Array(viewModel.paragraphs.enumerated()), id: \.element.id) { index, paragraph in
                            Button("After paragraph \(index + 1)") {
                                viewModel.addJingleCardToTimeline(card.id, afterParagraphID: paragraph.id)
                            }
                        }
                    }
                    Button("Generate Template") {
                        viewModel.generateTemplateJingle(for: card.id)
                    }
                    Button("Validate") {
                        viewModel.validateJingleCard(card.id)
                    }
                    Button("Preview") {
                        viewModel.playJingleCardPreview(card.id)
                    }
                    Button("Stop") {
                        viewModel.stopPlayback()
                    }
                    Button("Export MIDI") {
                        viewModel.exportJingleCardMIDI(card.id)
                    }
                    Spacer()
                    if let path = card.cachedMIDIPath, !path.isEmpty {
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(18)
        }
    }
}

struct JingleTimelineRow: View {
    let title: String
    let startTime: String
    let duration: String
    let onOpen: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .foregroundStyle(.orange)
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(startTime)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(duration)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}

struct ReferenceVoiceEnrollmentSheet: View {
    @EnvironmentObject private var viewModel: ProjectViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Reference Voice")
                .font(.title2)
                .fontWeight(.bold)

            Text("Generate a short script, read it into your Mac microphone, and save the recording as a reusable speaker profile. The app trims silence and works best with a VoiceDesign Qwen model.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Target a clean sample of about 8 to 12 seconds. Keep the read natural and avoid long pauses.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text(viewModel.isPreferredReferenceVoiceModelSelected ? "Reference model: VoiceDesign selected" : "Reference model: switching to VoiceDesign")
                    .font(.caption)
                    .fontWeight(.semibold)

                Text(viewModel.isPreferredReferenceVoiceModelCached ? "The VoiceDesign model is cached locally." : "The VoiceDesign model is required for Reference Voice and will be downloaded here.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button(viewModel.isPreferredReferenceVoiceModelCached ? "Load VoiceDesign Model" : "Download VoiceDesign Model") {
                        Task { await viewModel.prepareReferenceVoiceModelIfNeeded(forceDownload: false) }
                    }
                    .disabled(viewModel.isPreparingReferenceVoiceModel || viewModel.isUpdatingModels)

                    if viewModel.isPreparingReferenceVoiceModel || viewModel.isUpdatingModels {
                        ProgressView(value: viewModel.modelUpdateProgress)
                            .frame(width: 160)
                        Text(viewModel.modelUpdateNarrative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 10) {
                Button("Generate Script with AI") {
                    Task { await viewModel.generateReferenceVoiceScript() }
                }
                .disabled(viewModel.isGeneratingReferenceVoiceScript || viewModel.isRecordingReferenceVoice)

                Button("Use Default Script") {
                    viewModel.referenceVoiceScript = ProjectViewModel.defaultReferenceVoiceScript
                }
                .disabled(viewModel.isRecordingReferenceVoice)

                if viewModel.isRecordingReferenceVoice {
                    Button("Stop Recording") {
                        viewModel.stopReferenceVoiceRecording()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Start Recording") {
                        Task { await viewModel.startReferenceVoiceRecording() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            TextEditor(text: $viewModel.referenceVoiceScript)
                .font(.body)
                .frame(minHeight: 160)
                .padding(6)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )

            Text(viewModel.referenceVoiceEnrollmentStatus)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Save Reference Voice") {
                    viewModel.saveReferenceVoiceProfile()
                }
                .disabled(viewModel.isRecordingReferenceVoice || viewModel.isCleaningReferenceVoice)

                Button(viewModel.isCleaningReferenceVoice ? "Cleaning..." : "Clean and Save") {
                    Task { await viewModel.cleanAndSaveReferenceVoiceProfile() }
                }
                .disabled(viewModel.isRecordingReferenceVoice || viewModel.isCleaningReferenceVoice)

                if viewModel.referenceVoiceProfile != nil {
                    Button("Delete Reference Voice") {
                        viewModel.deleteReferenceVoiceProfile()
                    }
                }

                Spacer()
            }
        }
        .padding(18)
        .frame(minWidth: 720, minHeight: 520)
    }
}

struct ParagraphRow: View {
    @Binding var paragraph: Paragraph
    var voiceOptions: [VoiceOption]
    var isTTSReady: Bool
    var isLLMReady: Bool
    var viewModel: ProjectViewModel
    var onGenerate: () -> Void
    var onPlay: () -> Void
    var onImprove: () -> Void
    var onRephrase: () -> Void
    var onDuplicate: () -> Void
    var onRemove: () -> Void
    var onConfigureVoice: () -> Void
    var onVoiceSelectionChanged: (String) -> Void

    @State private var showDetails = false

    private var position: Int {
        (viewModel.scriptParagraphIndex(for: paragraph.id) ?? 0) + 1
    }

    private var selectedVoiceName: String {
        voiceOptions.first(where: { $0.id == paragraph.voiceID })?.name ?? "Voice"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            editor
            footer
            if showDetails {
                detailsPanel
            }
        }
        .padding(12)
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(NSColor.separatorColor).opacity(0.6), lineWidth: 1)
        )
    }

    // MARK: Header — number, voice, actions

    private var header: some View {
        HStack(spacing: 10) {
            Text("\(position)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 22)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))

            Picker(selection: $paragraph.voiceID) {
                ForEach(voiceOptions) { option in
                    Text(option.name).tag(option.id)
                }
            } label: {
                Label("Voice", systemImage: "person.wave.2")
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: paragraph.voiceID) {
                onVoiceSelectionChanged(paragraph.voiceID)
            }
            .help("Voice preset for this paragraph")

            Spacer()

            HStack(spacing: 2) {
                iconButton("wand.and.stars", help: "Improve: expand numbers and symbols for speech", action: onImprove)
                    .disabled(!isLLMReady || paragraph.isGenerating)
                iconButton("text.quote", help: "Rephrase for spoken clarity", action: onRephrase)
                    .disabled(!isLLMReady || paragraph.isGenerating)
                iconButton("plus.square.on.square", help: "Duplicate paragraph", action: onDuplicate)
                Divider().frame(height: 14).padding(.horizontal, 4)
                iconButton("trash", help: "Remove paragraph", role: .destructive, action: onRemove)
            }
        }
    }

    private func iconButton(
        _ systemImage: String,
        help: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .frame(width: 24, height: 20)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(role == .destructive ? AnyShapeStyle(.red.opacity(0.85)) : AnyShapeStyle(.secondary))
        .help(help)
    }

    // MARK: Editor — grows with content instead of a fixed void

    private var editor: some View {
        TextField("Narration text…", text: $paragraph.text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.body)
            .lineSpacing(3)
            .lineLimit(2...16)
            .padding(8)
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 1)
            )
    }

    // MARK: Footer — generation, status, non-default badges, details toggle

    private var hasAudio: Bool {
        paragraph.audioPath != nil && !paragraph.isGenerating
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if paragraph.isGenerating {
                ProgressView().controlSize(.small)
                Text("Generating…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if hasAudio {
                Button(action: onPlay) {
                    Label("Play", systemImage: "play.fill")
                }
                .controlSize(.small)
                .help("Play the generated audio")

                Button(action: onGenerate) {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(!isTTSReady)
                .help("Regenerate audio")

                Label("Ready", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Button(action: onGenerate) {
                    Label("Generate", systemImage: "waveform")
                }
                .controlSize(.small)
                .disabled(!isTTSReady)
                .help("Synthesize audio for this paragraph")
            }

            Spacer()

            if paragraph.speed != .normal {
                settingBadge("Speed \(paragraph.speed.label)")
            }
            if paragraph.pitch != .normal {
                settingBadge("Pitch \(paragraph.pitch.label)")
            }
            if abs(paragraph.gapDuration - 0.5) > 0.001 {
                settingBadge("Gap \(paragraph.gapDuration, specifier: "%.2g")s")
            }

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showDetails.toggle() }
            } label: {
                Label("Details", systemImage: showDetails ? "chevron.up" : "chevron.down")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Voice profile, output name, gap, speed, and pitch")
        }
    }

    private func settingBadge(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.5), in: Capsule())
    }

    // MARK: Details — secondary settings, collapsed by default

    private var detailsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(viewModel.voiceSummary(for: paragraph.voiceID))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(paragraph.voiceID == ReferenceVoiceProfile.voiceID ? "Reference Voice…" : "Configure Voice…") {
                    onConfigureVoice()
                }
                .controlSize(.small)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Output name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    TextField("para_x.wav", text: $paragraph.outputFilename)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(maxWidth: 260)
                }
                GridRow {
                    Text("Gap after")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        TextField("0.5", value: $paragraph.gapDuration, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .frame(width: 56)
                        Text("sec").font(.caption).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Speed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Speed", selection: $paragraph.speed) {
                        ForEach(Paragraph.SpeedPreset.allCases, id: \.self) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                GridRow {
                    Text("Pitch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Pitch", selection: $paragraph.pitch) {
                        ForEach(Paragraph.PitchPreset.allCases, id: \.self) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
            }
        }
    }
}

struct VoiceConfigurationPane: View {
    @Binding var configuration: VoiceConfiguration
    var baseVoiceOptions: [VoiceOption]
    var promptPreview: String
    var onDuplicate: () -> Void
    var onClose: () -> Void
    var onChanged: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Voice Details")
                        .font(.title3)
                        .fontWeight(.bold)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                }

                Text("Tune the selected voice with structured acoustic controls instead of freeform prompt writing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Voice Name", text: $configuration.name)
                        .textFieldStyle(.roundedBorder)

                    Text("Base Voice")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Base Voice", selection: $configuration.baseVoiceID) {
                        ForEach(baseVoiceOptions) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)

                    pickerRow("Anchor", selection: $configuration.anchor)
                    pickerRow("Timbre", selection: $configuration.timbre)
                    pickerRow("Prosody", selection: $configuration.prosody)
                    pickerRow("Pacing", selection: $configuration.pacing)
                    pickerRow("Emotion", selection: $configuration.emotionalContour)
                    pickerRow("Delivery", selection: $configuration.deliveryStrength)
                }

                Text("Prompt Preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(promptPreview)
                    .font(.caption2)
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)

                HStack {
                    Button("Duplicate Voice", action: onDuplicate)
                        .buttonStyle(.bordered)
                    Spacer()
                }
            }
            .padding(16)
        }
        .onChange(of: configuration) {
            onChanged()
        }
    }

    private func pickerRow<Value: CaseIterable & Hashable>(_ title: String, selection: Binding<Value>) -> some View where Value.AllCases: RandomAccessCollection, Value: CustomStringConvertible {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                ForEach(Array(Value.allCases), id: \.self) { option in
                    Text(option.description).tag(option)
                }
            }
            .pickerStyle(.menu)
        }
    }
}

struct ReferenceVoicePaneSummary: View {
    @EnvironmentObject private var viewModel: ProjectViewModel
    var closeAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Reference Voice")
                    .font(.title3)
                    .fontWeight(.bold)
                Spacer()
                Button(action: closeAction) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
            }

            Text("The reference voice uses the single enrolled sample stored by the app. Voice style comes primarily from the recording and transcript, not from the structured sliders.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(viewModel.referenceVoiceEnrollmentStatus)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(viewModel.referenceVoiceProfile == nil ? "Create Reference Voice" : "Manage Reference Voice") {
                viewModel.openReferenceVoiceEnrollment()
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .padding(16)
    }
}
