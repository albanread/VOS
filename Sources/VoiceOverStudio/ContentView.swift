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

                            ForEach($viewModel.paragraphs) { $paragraph in
                                VStack(alignment: .leading, spacing: 10) {
                                    ParagraphRow(paragraph: $paragraph,
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

                    HStack {
                        Text(viewModel.statusMessage)
                            .font(.callout)
                            .foregroundStyle(viewModel.isProcessing ? .blue : .secondary)
                        if viewModel.isProcessing {
                            ProgressView().controlSize(.small)
                        }
                        Spacer()
                        Text("Paragraphs: \(viewModel.paragraphs.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

                    Button(action: viewModel.saveTranscript) {
                        Label("Save Transcript", systemImage: "square.and.arrow.down")
                    }

                    Button(action: viewModel.loadTranscript) {
                        Label("Load Transcript", systemImage: "square.and.arrow.up")
                    }

                    Button(action: {
                        Task { await viewModel.generateAllAudio() }
                    }) {
                        Label("Generate All", systemImage: "waveform.badge.plus")
                    }
                    .disabled(!viewModel.isTTSReady || viewModel.isProcessing)

                    Button(action: {
                        Task { await viewModel.exportFullSequence() }
                    }) {
                        Label("Export Sequence", systemImage: "square.and.arrow.down")
                    }
                    .disabled(viewModel.paragraphs.isEmpty)

                    Button(action: viewModel.openJingleLibrary) {
                        Label("Jingles", systemImage: "music.note.list")
                    }
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
        } else if let index = viewModel.activeVoiceConfigurationIndex {
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
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                Text("VoiceOver Studio")
                    .font(.title2)
                    .fontWeight(.bold)
                    .padding(.bottom)

                Group {
                    Text("Settings")
                        .font(.headline)

                    Text("Model folders are auto-managed")
                        .font(.subheadline)
                        .padding(.top, 5)
                    Text(viewModel.managedModelsRootDisplay)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Qwen cache: \(viewModel.ttsCacheDisplay)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Divider().padding(.vertical, 4)

                    Text("Model Updater")
                        .font(.subheadline)

                    HStack {
                        Text("Computer Tier")
                        Picker("", selection: $viewModel.modelComputeTierRaw) {
                            ForEach(ProjectViewModel.ComputeTier.allCases) { tier in
                                Text(tier.title).tag(tier.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .accessibilityLabel("Computer Tier")
                        Button("Auto-detect This Mac") {
                            viewModel.autoDetectModelTier()
                        }
                    }

                    Text("LLM (script advice): \(viewModel.currentRecommendation.llmName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("TTS (voice synthesis): \(viewModel.currentRecommendation.ttsName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(viewModel.currentRecommendation.rationale)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 10)

                    Button(action: {
                        Task { await viewModel.autoSetup() }
                    }) {
                        VStack(spacing: 4) {
                            Text("1-Click Auto Setup")
                                .font(.headline)
                            Text("Download and configure everything automatically")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(viewModel.isUpdatingModels)

                    if viewModel.isUpdatingModels || !viewModel.modelUpdateNarrative.contains("Idle") {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: viewModel.modelUpdateProgress)
                                .frame(maxWidth: .infinity)
                            Text(viewModel.modelUpdateNarrative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.05))
                        .cornerRadius(6)
                    }

                    DisclosureGroup("Advanced Settings") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Manual URL Overrides")
                                .font(.caption)
                                .bold()
                            
                            TextField("LLM URL", text: $viewModel.modelUpdateURLLLM)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)

                            TextField("Qwen TTS Model Repo", text: $viewModel.ttsModelRepo)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)

                            HStack {
                                Button("Download Qwen Model") {
                                    Task { await viewModel.downloadTTSModel() }
                                }
                                .controlSize(.small)
                                .disabled(viewModel.isUpdatingModels)

                                Button("Open Qwen Repo") {
                                    viewModel.openTTSDownloadPage()
                                }
                                .controlSize(.small)
                            }
                                
                            Button("Re-Initialize Engines") {
                                viewModel.initializeEngines()
                            }
                            .controlSize(.small)
                        }
                        .padding(.top, 5)
                    }
                    .padding(.top, 10)

                    Divider().padding(.vertical, 4)

                    Text("Reference Voice")
                        .font(.subheadline)

                    Text(viewModel.referenceVoiceProfile == nil ? "Enroll a microphone recording to create a stable speaker identity for Qwen." : "Reference Voice enrolled and available in the paragraph voice picker.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Best results come from a VoiceDesign Qwen model and a clean, quiet microphone recording.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(viewModel.referenceVoiceEnrollmentStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Button(viewModel.referenceVoiceProfile == nil ? "Create Reference Voice" : "Manage Reference Voice") {
                        viewModel.openReferenceVoiceEnrollment()
                    }
                    .buttonStyle(.bordered)

                    Divider().padding(.vertical, 4)

                    Text("Jingle Cards")
                        .font(.subheadline)

                    Text("Prompt-first or ABC-first reusable music cues for intros, transitions, bumpers, and outros.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Open Jingle Library") {
                        viewModel.openJingleLibrary()
                    }
                    .buttonStyle(.bordered)
                }

                Spacer(minLength: 8)

                Button(action: {
                    Task { await viewModel.exportFullSequence() }
                }) {
                    Label("Export Full Sequence", systemImage: "waveform.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(viewModel.paragraphs.isEmpty)

                HStack {
                    Button("Save Transcript") { viewModel.saveTranscript() }
                    Button("Load Transcript") { viewModel.loadTranscript() }
                }
                .controlSize(.small)

                Divider().padding(.vertical, 6)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Defaults")
                        .font(.headline)
                    HStack {
                        Text("Default Gap (sec)")
                        TextField("0.5", value: $viewModel.defaultGap, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                    }
                    HStack {
                        Text("Export Format")
                        Picker("Export Format", selection: $viewModel.exportFormatRaw) {
                            Text("M4A (AAC)").tag(ProjectViewModel.ExportFormat.m4a.rawValue)
                            Text("WAV").tag(ProjectViewModel.ExportFormat.wav.rawValue)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                    }
                }
            }
            .padding()
        }
        .background(Color(NSColor.controlBackgroundColor))
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
    var viewModel: ProjectViewModel // Access tagging methods
    var onGenerate: () -> Void
    var onPlay: () -> Void
    var onImprove: () -> Void
    var onRephrase: () -> Void
    var onDuplicate: () -> Void
    var onRemove: () -> Void
    var onConfigureVoice: () -> Void
    var onVoiceSelectionChanged: (String) -> Void

    private var textEditorPanel: some View {
        TextEditor(text: $paragraph.text)
            .font(.body)
            .frame(minHeight: 220, alignment: .topLeading)
            .padding(4)
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(5)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
    }

    private var controlsPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button(action: onImprove) {
                    Label("Improve", systemImage: "wand.and.stars")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!isLLMReady || paragraph.isGenerating)
                .help("Optimise text for TTS: expand numbers, add pauses, fix pronunciation")

                Button(action: onRephrase) {
                    Label("Rephrase", systemImage: "text.quote")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!isLLMReady || paragraph.isGenerating)
                .help("Rephrase for spoken clarity: simplify sentences, improve flow")
            }

            HStack(spacing: 6) {
                Button(action: onDuplicate) {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(action: onRemove) {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Divider().padding(.vertical, 2)

            Text("Voice")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Voice", selection: $paragraph.voiceID) {
                ForEach(voiceOptions) { option in
                    Text(option.name).tag(option.id)
                }
            }
            .labelsHidden()
            .onChange(of: paragraph.voiceID) {
                onVoiceSelectionChanged(paragraph.voiceID)
            }

            Text("Voice profile")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(viewModel.voiceSummary(for: paragraph.voiceID))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onConfigureVoice) {
                Label(paragraph.voiceID == ReferenceVoiceProfile.voiceID ? "Reference Voice Details" : "Configure Voice", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Text(viewModel.voicePromptPreview(for: paragraph.voiceID))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 2)

            Text("Output name")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("para_x.wav", text: $paragraph.outputFilename)
                .textFieldStyle(.roundedBorder)

            Divider().padding(.vertical, 2)

            HStack {
                Text("Gap after:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("0.5", value: $paragraph.gapDuration, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 50)
                Text("sec")
                    .font(.caption)
            }

            Divider().padding(.vertical, 2)

            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Text("Speed:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $paragraph.speed) {
                        ForEach(Paragraph.SpeedPreset.allCases, id: \.self) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 80)
                }

                HStack(spacing: 4) {
                    Text("Pitch:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $paragraph.pitch) {
                        ForEach(Paragraph.PitchPreset.allCases, id: \.self) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 80)
                }
            }
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    textEditorPanel
                        .frame(minWidth: 320, maxWidth: .infinity)
                    controlsPanel
                        .frame(width: 240, alignment: .topLeading)
                }

                VStack(alignment: .leading, spacing: 12) {
                    textEditorPanel
                    controlsPanel
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            HStack {
                Button(action: onGenerate) {
                    if paragraph.isGenerating {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Generate Audio", systemImage: "waveform")
                    }
                }
                .disabled(!isTTSReady || paragraph.isGenerating)
                
                if paragraph.audioPath != nil && !paragraph.isGenerating {
                    Button(action: onPlay) {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 10)
                    .foregroundStyle(.green)
                    
                    Text("✓ Ready")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if paragraph.isGenerating {
                    Image(systemName: "play.fill")
                        .foregroundStyle(.gray.opacity(0.4))
                        .padding(.leading, 10)
                    Text("Generating…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No Audio")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 10)
                }
                
                Spacer()
            }
        }
        .padding(10)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(8)
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
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
