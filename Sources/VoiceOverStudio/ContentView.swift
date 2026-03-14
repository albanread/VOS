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
            VStack(spacing: 0) {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach($viewModel.paragraphs) { $paragraph in
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
                                         })
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
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 620)
        .onAppear {
            guard !didApplyInitialPaneVisibility else { return }
            didApplyInitialPaneVisibility = true
            uiState.splitVisibility = viewModel.shouldHideSettingsPaneOnLaunch() ? .detailOnly : .all
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
                        Picker("Computer Tier", selection: $viewModel.modelComputeTierRaw) {
                            ForEach(ProjectViewModel.ComputeTier.allCases) { tier in
                                Text(tier.title).tag(tier.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
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
            GeometryReader { geometry in
                let useVerticalLayout = geometry.size.width < 820

                Group {
                    if useVerticalLayout {
                        VStack(alignment: .leading, spacing: 12) {
                            textEditorPanel
                            controlsPanel
                        }
                    } else {
                        HStack(alignment: .top, spacing: 12) {
                            textEditorPanel
                                .frame(minWidth: 320, maxWidth: .infinity)
                            controlsPanel
                                .frame(width: 240, alignment: .topLeading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(height: 380)
            
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
