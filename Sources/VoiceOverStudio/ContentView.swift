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

                    if viewModel.clipSummaries.contains(where: { !$0.isTranscript }) {
                        Button(action: viewModel.openTimelineFromToolbar) {
                            Label("Timeline", systemImage: "film")
                        }
                        .keyboardShortcut("t", modifiers: [.command])
                        .help("Open the video timeline (Cmd-T)")
                    }

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
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, VideoTimelineService.isMovieURL(url) else { return false }
            Task { await viewModel.attachVideoDropped(url) }
            return true
        }
        .sheet(isPresented: $viewModel.isReferenceVoiceSheetPresented) {
            ReferenceVoiceEnrollmentSheet()
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $viewModel.isJingleLibrarySheetPresented) {
            JingleLibrarySheet()
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $viewModel.isVideoTimelineSheetPresented) {
            VideoTimelineSheet()
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $viewModel.isNewProjectSheetPresented) {
            NewProjectSheet()
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $viewModel.isOpenProjectSheetPresented) {
            OpenProjectSheet()
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $viewModel.isClipManagerSheetPresented) {
            ClipManagerSheet()
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

            Section("Project") {
                TextField("Project name", text: Binding(
                    get: { viewModel.projectName },
                    set: { viewModel.renameCurrentProject(to: $0) }
                ))
                .textFieldStyle(.roundedBorder)

                Button {
                    viewModel.isNewProjectSheetPresented = true
                } label: {
                    Label("New Project…", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .help("Start a fresh project; this one stays in the database")

                Button {
                    viewModel.openClipManager()
                } label: {
                    Label("Manage Clips…", systemImage: "film.stack")
                        .frame(maxWidth: .infinity)
                }
                .help("List, open, add, and remove this project's video clips")

                if viewModel.clipSummaries.count > 1 {
                    Picker("Clip", selection: Binding(
                        get: { viewModel.activeClip?.id ?? -1 },
                        set: { viewModel.switchToClip($0) }
                    )) {
                        ForEach(viewModel.clipSummaries, id: \.id) { clip in
                            Text(clip.displayName).tag(clip.id)
                        }
                    }
                    .help("Switch between this project's clips (video attachments and the voice-only transcript)")
                }
            }

            Section("Video") {
                Text(viewModel.videoPath == nil
                    ? "Attach a screen recording, view its frames, and place voice-over at the right moments."
                    : "Video attached — open the timeline to anchor paragraphs and export a mixed video.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if viewModel.videoPath != nil, let clip = viewModel.activeClip {
                    Text(clip.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Button(viewModel.videoPath == nil ? "Add Video Clip…" : "Open Video Timeline…") {
                    viewModel.openVideoTimeline()
                }
                .help("Attach another video to this project, or open the timeline for the active clip")

                if viewModel.videoPath != nil {
                    Button("Switch to Voice-Only") {
                        viewModel.detachVideo()
                    }
                    .help("Return to the project's voice-only transcript; the video clip stays in the project")
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

struct NewProjectSheet: View {
    @EnvironmentObject private var viewModel: ProjectViewModel
    @State private var name = ""

    var body: some View {
        VStack(spacing: 14) {
            Text("New Project")
                .font(.headline)
            TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)
            Text("The current project stays in the database.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") {
                    viewModel.isNewProjectSheetPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func create() {
        viewModel.startNewProject(named: name)
        viewModel.isNewProjectSheetPresented = false
    }
}

struct OpenProjectSheet: View {
    @EnvironmentObject private var viewModel: ProjectViewModel
    @State private var selected: Int64?
    @State private var listings: [ProjectListing] = []

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selected) {
                ForEach(listings, id: \.id) { listing in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(listing.name)
                                .font(.body.weight(listing.id == viewModel.activeProjectID ? .semibold : .regular))
                            Text("\(listing.clipCount) clip\(listing.clipCount == 1 ? "" : "s") · \(listing.voiceOverCount) voice-over\(listing.voiceOverCount == 1 ? "" : "s") · updated \(listing.updatedAt.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 3)
                    .tag(listing.id)
                    .onTapGesture(count: 2) { open() }
                }
            }
            .listStyle(.inset)
            .frame(minWidth: 460, minHeight: 300)

            HStack {
                if listings.isEmpty {
                    Text("No projects yet — create one to start.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    viewModel.isOpenProjectSheetPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Open", action: open)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil)
            }
            .padding(12)
        }
        .frame(minWidth: 480, minHeight: 380)
        .onAppear {
            listings = viewModel.recentProjectListings()
        }
    }

    private func open() {
        guard let selected else { return }
        viewModel.openProject(selected)
        viewModel.isOpenProjectSheetPresented = false
    }
}

struct ClipManagerSheet: View {
    @EnvironmentObject private var viewModel: ProjectViewModel
    @State private var listings: [ClipListing] = []
    @State private var selected: Int64?
    @State private var confirmRemove: ClipListing?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selected) {
                ForEach(listings, id: \.id) { listing in
                    HStack(spacing: 10) {
                        Image(systemName: listing.isTranscript ? "waveform.path" : "film")
                            .foregroundStyle(listing.id == viewModel.activeClip?.id ? Color.accentColor : .secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(listing.displayName)
                                    .font(.body.weight(listing.id == viewModel.activeClip?.id ? .semibold : .regular))
                                if listing.id == viewModel.activeClip?.id {
                                    Text("current")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(.quaternary.opacity(0.6), in: Capsule())
                                }
                            }
                            Text(caption(for: listing))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 3)
                    .tag(listing.id)
                    .onTapGesture(count: 2) { open(listing) }
                }
            }
            .listStyle(.inset)
            .frame(minWidth: 560, minHeight: 300)

            HStack {
                Button {
                    viewModel.attachVideo()
                    // The attach panel blocks; refresh when it returns.
                    Task {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        refresh()
                    }
                } label: {
                    Label("Add Video Clip…", systemImage: "plus")
                }
                .help("Attach another video to this project (or drop one anywhere on this window)")

                if let victim = confirmRemove {
                    Button(role: .destructive) {
                        viewModel.removeClip(victim.id)
                        confirmRemove = nil
                        refresh()
                    } label: {
                        Text("Remove \"\(victim.displayName)\"")
                    }
                } else if let selected, let listing = listings.first(where: { $0.id == selected }), !listing.isTranscript {
                    Button(role: .destructive) {
                        confirmRemove = listing
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .help("Remove this clip and its voice-overs from the project (the workspace folder is kept)")
                }

                Spacer()

                Button("Done") {
                    viewModel.isClipManagerSheetPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Open", action: openSelection)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil)
            }
            .padding(12)
        }
        .frame(minWidth: 600, minHeight: 420)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: VideoTimelineService.isMovieURL) else { return false }
            Task {
                _ = await viewModel.attachVideoFile(at: url)
                refresh()
            }
            return true
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        listings = viewModel.clipManagerListings()
        selected = viewModel.activeClip?.id ?? listings.first?.id
    }

    private func caption(for listing: ClipListing) -> String {
        let minutes = Int(listing.voicedSeconds) / 60
        let seconds = Int(listing.voicedSeconds) % 60
        var parts = ["\(listing.voiceOverCount) voice-over\(listing.voiceOverCount == 1 ? "" : "s")",
                     "\(minutes)m \(String(format: "%02d", seconds))s voiced"]
        if listing.recordedCount > 0 {
            parts.append("\(listing.recordedCount) recorded")
        }
        parts.append("updated \(listing.updatedAt.formatted(.relative(presentation: .named)))")
        return parts.joined(separator: " · ")
    }

    private func openSelection() {
        guard let selected, let listing = listings.first(where: { $0.id == selected }) else { return }
        open(listing)
    }

    private func open(_ listing: ClipListing) {
        viewModel.switchToClip(listing.id)
        viewModel.isClipManagerSheetPresented = false
    }
}

struct JingleLibrarySheet: View {
    @EnvironmentObject private var viewModel: ProjectViewModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { viewModel.selectedJingleCardID },
                set: { viewModel.selectJingleCard($0) }
            )) {
                ForEach(viewModel.jingleCards) { card in
                    HStack(spacing: 8) {
                        Image(systemName: "music.note")
                            .foregroundStyle(.orange)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.name.isEmpty ? "Untitled Jingle" : card.name)
                            Text(card.promptSpec.cueRole.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        SpeechSafetyBadge(safety: card.speechSafety, compact: true)
                    }
                    .tag(card.id)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
            .toolbar {
                ToolbarItemGroup {
                    Menu {
                        ForEach(ABCJinglePreset.builtIn) { preset in
                            Button(preset.name) {
                                viewModel.addJingleCard(from: preset)
                            }
                        }
                        Divider()
                        Button("Blank Jingle") {
                            viewModel.addJingleCard(from: nil)
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .help("Add a jingle from a preset or start blank")

                    if let selectedID = viewModel.selectedJingleCardID {
                        Button {
                            viewModel.duplicateJingleCard(selectedID)
                        } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                        .help("Duplicate the selected jingle")

                        Button(role: .destructive) {
                            viewModel.removeJingleCard(selectedID)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .help("Remove the selected jingle")
                    }
                }
            }
        } detail: {
            if let selectedID = viewModel.selectedJingleCardID,
               viewModel.jingleCards.contains(where: { $0.id == selectedID }) {
                JingleCardEditor(card: viewModel.jingleCardBinding(selectedID))
            } else {
                ContentUnavailableView(
                    "No Jingle Selected",
                    systemImage: "music.note",
                    description: Text("Select a jingle, or add one from a preset.")
                )
            }
        }
        .frame(minWidth: 940, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    viewModel.isJingleLibrarySheetPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
        }
    }
}

struct SpeechSafetyBadge: View {
    let safety: ABCJingleSpeechSafety
    var compact = false

    private var color: Color {
        switch safety {
        case .safe: return .green
        case .review: return .orange
        case .risky: return .red
        }
    }

    var body: some View {
        if compact {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .help("Speech safety: \(safety.rawValue.capitalized)")
        } else {
            Text(safety.rawValue.capitalized)
                .font(.caption2.weight(.medium))
                .foregroundStyle(color)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(color.opacity(0.14), in: Capsule())
                .help("How safely this cue sits under speech")
        }
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
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            fieldLabel("Name")
                            TextField("Jingle name", text: $card.name)
                                .textFieldStyle(.roundedBorder)
                                .gridCellColumns(3)
                        }
                        GridRow {
                            fieldLabel("Role")
                            Picker("Role", selection: $card.promptSpec.cueRole) {
                                ForEach(ABCJingleCueRole.allCases, id: \.self) { role in
                                    Text(role.description).tag(role)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 180)

                            fieldLabel("Target length")
                            HStack(spacing: 4) {
                                TextField("2.0", value: $card.promptSpec.targetDurationSeconds, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 64)
                                Text("sec").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        GridRow {
                            fieldLabel("Notes")
                            TextField("Template notes for generation", text: $card.promptSpec.promptText)
                                .textFieldStyle(.roundedBorder)
                                .gridCellColumns(3)
                        }
                        GridRow {
                            fieldLabel("Style tags")
                            TextField("news, confident, clean", text: styleTagsText)
                                .textFieldStyle(.roundedBorder)
                                .gridCellColumns(2)
                            SpeechSafetyBadge(safety: card.speechSafety)
                                .gridColumnAlignment(.trailing)
                        }
                    }
                    .padding(14)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("ABC Source")
                                .font(.headline)
                            Spacer()
                            if let path = card.cachedMIDIPath, !path.isEmpty {
                                Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "checkmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .help("Rendered MIDI is cached at \(path)")
                            }
                        }

                        TextEditor(text: $card.abcSource)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 220)
                            .padding(6)
                            .background(Color(NSColor.textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 1)
                            )
                            .overlay(alignment: .topLeading) {
                                if card.abcSource.isEmpty {
                                    Text("No ABC yet. Generate Template writes a starting point from the role and length above.")
                                        .font(.callout)
                                        .foregroundStyle(.tertiary)
                                        .padding(12)
                                        .allowsHitTesting(false)
                                }
                            }
                    }
                }
                .padding(16)
            }

            Divider()

            HStack(spacing: 8) {
                Menu {
                    Button("Before first paragraph") {
                        viewModel.addJingleCardToTimeline(card.id, afterParagraphID: nil)
                    }
                    ForEach(Array(viewModel.paragraphs.enumerated()), id: \.element.id) { index, paragraph in
                        Button("After paragraph \(index + 1)") {
                            viewModel.addJingleCardToTimeline(card.id, afterParagraphID: paragraph.id)
                        }
                    }
                } label: {
                    Label("Timeline", systemImage: "text.insert")
                }
                .help("Insert this cue into the export sequence")

                Divider().frame(height: 16)

                Button("Validate") {
                    viewModel.validateJingleCard(card.id)
                }
                .help("Parse the ABC and report warnings")

                Button {
                    viewModel.playJingleCardPreview(card.id)
                } label: {
                    Label("Preview", systemImage: "play.fill")
                }
                .help("Play the cue as MIDI")

                Button {
                    viewModel.stopPlayback()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .help("Stop playback")

                Button("Export MIDI…") {
                    viewModel.exportJingleCardMIDI(card.id)
                }
                .help("Write the rendered MIDI to the jingle cache")

                Spacer()

                Button("Generate ABC") {
                    viewModel.generateTemplateJingle(for: card.id)
                }
                .buttonStyle(.borderedProminent)
                .help("Write deterministic ABC from the role and target length")
            }
            .padding(12)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
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
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reference Voice")
                        .font(.title2.weight(.bold))
                    Text("Record about 10 seconds of clean speech to clone your voice as a speaker preset.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") {
                    viewModel.isReferenceVoiceSheetPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }

            stepBox(number: 1, title: "Model") {
                HStack(spacing: 10) {
                    Image(systemName: viewModel.isPreferredReferenceVoiceModelCached ? "checkmark.circle.fill" : "arrow.down.circle")
                        .foregroundStyle(viewModel.isPreferredReferenceVoiceModelCached ? .green : .secondary)
                    Text(viewModel.isPreferredReferenceVoiceModelCached
                        ? "Cloning model (Qwen3-TTS 1.7B Base) is cached locally."
                        : "Voice cloning needs the Qwen3-TTS 1.7B Base model.")
                        .font(.callout)
                    Spacer()
                    Button(viewModel.isPreferredReferenceVoiceModelCached ? "Load Model" : "Download Model") {
                        Task { await viewModel.prepareReferenceVoiceModelIfNeeded(forceDownload: false) }
                    }
                    .disabled(viewModel.isPreparingReferenceVoiceModel || viewModel.isUpdatingModels)
                }
                if viewModel.isPreparingReferenceVoiceModel || viewModel.isUpdatingModels {
                    HStack(spacing: 8) {
                        ProgressView(value: viewModel.modelUpdateProgress)
                        Text(viewModel.modelUpdateNarrative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            stepBox(number: 2, title: "Script") {
                TextEditor(text: $viewModel.referenceVoiceScript)
                    .font(.body)
                    .frame(minHeight: 90, maxHeight: 140)
                    .padding(6)
                    .background(Color(NSColor.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(NSColor.separatorColor).opacity(0.5), lineWidth: 1)
                    )
                HStack {
                    Button("Generate with AI") {
                        Task { await viewModel.generateReferenceVoiceScript() }
                    }
                    .disabled(viewModel.isGeneratingReferenceVoiceScript || viewModel.isRecordingReferenceVoice)
                    Button("Use Default") {
                        viewModel.referenceVoiceScript = ProjectViewModel.defaultReferenceVoiceScript
                    }
                    .disabled(viewModel.isRecordingReferenceVoice)
                    Spacer()
                    Text("Aim for 8–12 seconds read naturally, without long pauses.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .controlSize(.small)
            }

            stepBox(number: 3, title: "Record") {
                HStack(spacing: 10) {
                    if viewModel.isRecordingReferenceVoice {
                        Button {
                            viewModel.stopReferenceVoiceRecording()
                        } label: {
                            Label("Stop Recording", systemImage: "stop.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        ProgressView().controlSize(.small)
                        Text("Recording… read the script now.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            Task { await viewModel.startReferenceVoiceRecording() }
                        } label: {
                            Label("Start Recording", systemImage: "record.circle")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                }
                Text(viewModel.referenceVoiceEnrollmentStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            HStack {
                if viewModel.referenceVoiceProfile != nil {
                    Button("Delete Reference Voice", role: .destructive) {
                        viewModel.deleteReferenceVoiceProfile()
                    }
                }
                Spacer()
                Button(viewModel.isCleaningReferenceVoice ? "Cleaning…" : "Clean & Save") {
                    Task { await viewModel.cleanAndSaveReferenceVoiceProfile() }
                }
                .disabled(viewModel.isRecordingReferenceVoice || viewModel.isCleaningReferenceVoice)
                .help("Runs speech enhancement on the recording before saving")

                Button("Save Reference Voice") {
                    viewModel.saveReferenceVoiceProfile()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isRecordingReferenceVoice || viewModel.isCleaningReferenceVoice)
            }
        }
        .padding(18)
        .frame(minWidth: 680, minHeight: 560)
    }

    @ViewBuilder
    private func stepBox(number: Int, title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.tint))
                Text(title)
                    .font(.headline)
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
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

            if timelineStart != nil {
                Label(timelineBadge, systemImage: "clock")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
                    .help(videoPlacementHelp)
            }

            Button {
                viewModel.openTimeline(at: timelineStart)
            } label: {
                Image(systemName: viewModel.hasVideoClip ? "film.stack" : "waveform.path")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(viewModel.hasVideoClip
                ? "Open the video timeline for this clip"
                : "Open the voice timeline (sequential, podcast style)")

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

    /// Every voice is over a timeline: anchored times on a video clip,
    /// stacked sequentially on a voice-only clip.
    private var timelineStart: Double? {
        viewModel.timelineStart(forParagraphID: paragraph.id)
    }

    private var timelineBadge: String {
        guard let start = timelineStart,
              let end = viewModel.timelineEnd(forParagraphID: paragraph.id)
        else { return "—:—" }
        return "\(Paragraph.timecode(start)) → \(Paragraph.timecode(end))"
    }

    private var videoPlacementHelp: String {
        guard let start = timelineStart,
              let end = viewModel.timelineEnd(forParagraphID: paragraph.id)
        else { return "" }
        let duration = viewModel.audioDuration(forParagraphID: paragraph.id)
        let qualifier = viewModel.hasMeasuredAudioDuration(paragraph.id) ? "measured" : "estimated"
        return viewModel.hasVideoClip
            ? "Voiced \(Paragraph.timecode(start)) → \(Paragraph.timecode(end)) (\(String(format: "%.1f", duration))s, \(qualifier)) in this video clip"
            : "Runs \(Paragraph.timecode(start)) → \(Paragraph.timecode(end)) (\(String(format: "%.1f", duration))s, \(qualifier)) in the sequential voice timeline"
    }

    private var videoRangeBadge: LocalizedStringKey? {
        guard timelineStart != nil else { return nil }
        return "\(timelineBadge)"
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
            if let videoBadge = videoRangeBadge {
                settingBadge(videoBadge)
                if !viewModel.hasMeasuredAudioDuration(paragraph.id) {
                    settingBadge("≈ length")
                }
            }
            if paragraph.isRecorded {
                settingBadge("Recorded")
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
