//
//  VideoTimelineSheet.swift
//  VoiceOverStudio
//
//  Playhead-driven narration editor. The lower band is the voice track: each
//  paragraph is a clip laid down at its start time whose length is the real
//  duration of its generated audio (estimated from the text until generated).
//  The editor below shows the one text item at the playhead.
//

import AVFoundation
import SwiftUI

struct VideoTimelineSheet: View {
    @EnvironmentObject private var viewModel: ProjectViewModel

    var body: some View {
        VideoTimelineContent(controller: viewModel.videoController)
            .environmentObject(viewModel)
            .frame(minWidth: 1040, minHeight: 760)
            .onAppear {
                Task {
                    await viewModel.prepareVideoPreview()
                    if let seek = viewModel.pendingTimelineSeek {
                        viewModel.pendingTimelineSeek = nil
                        if viewModel.videoController.duration > 0 {
                            viewModel.videoController.seek(to: seek)
                        }
                    }
                }
            }
            .onDisappear {
                viewModel.videoController.pause()
            }
    }
}

private struct VideoTimelineContent: View {
    @ObservedObject var controller: VideoTimelineController
    @EnvironmentObject private var viewModel: ProjectViewModel
    @State private var thumbnails: [Double: NSImage] = [:]
    @State private var pinnedParagraphID: UUID?
    @State private var followedSlot: Double?
    @State private var isBeginningNewClip = false
    @State private var playheadDragOrigin: Double?
    @State private var isScrubbingPlayhead = false
    @State private var viewportWidth: CGFloat = 900
    /// True after a manual scroll: the user owns the window and the follow
    /// stops fighting them until they move the playhead themselves.
    @State private var scrollFollowSuspended = false
    /// Bounds changes within this window are our own programmatic scrolls.
    @State private var programmaticScrollUntil = Date.distantPast
    @FocusState private var textIsFocused: Bool

    private let slotWidth: CGFloat = 128
    private let slotSpacing: CGFloat = 4
    private let trackHeight: CGFloat = 46
    /// After a voice generates, the playhead jumps this far past the clip's end
    /// so the next line is written where it will be needed.
    private let postVoiceAdvanceSeconds: Double = 8.0

    var body: some View {
        Group {
            if controller.isLoading {
                ProgressView("Loading video…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if controller.isLoaded {
                loadedContent
            } else {
                emptyState
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                viewModel.isVideoTimelineSheetPresented = false
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .padding(6)
            .help("Close the video timeline (Esc)")
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, VideoTimelineService.isMovieURL(url) else { return false }
            Task { _ = await viewModel.attachVideoFile(at: url) }
            return true
        }
        .onChange(of: textIsFocused) {
            // While typing, the editor stays on the paragraph being edited;
            // once focus leaves, the playhead decides again.
            if !textIsFocused {
                pinnedParagraphID = nil
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if viewModel.isVideoExporting {
                    ProgressView()
                        .controlSize(.small)
                        .help("Exporting video…")
                }
                Button("Refresh Preview") {
                    Task {
                        await viewModel.refreshParagraphAudioDurations()
                        await viewModel.refreshVideoPreview()
                    }
                }
                .controlSize(.small)
                .disabled(!controller.isLoaded || viewModel.isVideoExporting)
                .help("Re-measure clip lengths and rebuild preview playback")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Export Video…") {
                    Task { await viewModel.exportVideoWithVoiceOver() }
                }
                .disabled(!controller.isLoaded || viewModel.videoAnchoredClips().isEmpty || viewModel.isVideoExporting)
                .help("Export the video with the voice track mixed in")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Export Track…") {
                    Task { await viewModel.exportVoiceTrackOnly() }
                }
                .disabled(!controller.isLoaded || viewModel.videoAnchoredClips().isEmpty || viewModel.isVideoExporting)
                .help("Export a full-length WAV of just the voice track, for attaching in another video editor")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    viewModel.isVideoTimelineSheetPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            ContentUnavailableView {
                Label("No Video Attached", systemImage: "film")
            } description: {
                Text("Drag a QuickTime screen capture or other video anywhere onto this window — or use Attach. Scrub the frames, lay voice clips on the track, and write each line where it belongs.")
            } actions: {
                Button("Attach Video…") {
                    viewModel.attachVideo()
                }
                .buttonStyle(.borderedProminent)
            }
            if let loadError = controller.loadError {
                Text(loadError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Loaded layout

    private var loadedContent: some View {
        VStack(spacing: 12) {
            videoHeader
            videoSection
            Divider()
            segmentSection
            statusFooter
        }
        .padding(12)
    }

    private var videoHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Image(systemName: "film")
                        .foregroundStyle(.secondary)
                    Text(viewModel.videoPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Video")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(viewModel.videoPath ?? "")
                }
                if let workspace = viewModel.videoWorkspaceURL {
                    Text(workspace.path)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("Working folder for this video's audio and project")
                }
            }

            Spacer()

            Label("", systemImage: viewModel.videoOriginalAudioVolume < 0.01 ? "speaker.slash" : "speaker.wave.2")
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .help("Volume of the video's original audio in the mix")
            Slider(value: $viewModel.videoOriginalAudioVolume, in: 0...1) { editing in
                if !editing {
                    viewModel.commitVideoVolume()
                }
            }
            .frame(width: 110)
            Text("\(Int(viewModel.videoOriginalAudioVolume * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)

            Button("Change…") {
                viewModel.attachVideo()
            }
            .controlSize(.small)
            Button("Detach", role: .destructive) {
                viewModel.detachVideo()
            }
            .controlSize(.small)
        }
    }

    private var videoSection: some View {
        VStack(spacing: 8) {
            if !viewModel.hasVideoClip {
                Label("Voice-only timeline — clips play in sequence", systemImage: "waveform.path")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if viewModel.hasVideoClip {
                videoPlayerAndFilmstrip
            }
            transportRow
            timelineBands
        }
    }

    @ViewBuilder
    private var videoPlayerAndFilmstrip: some View {
        VideoPlayerLayerView(player: controller.player)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(height: 260)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(NSColor.separatorColor).opacity(0.6), lineWidth: 1)
            )
    }

    private var transportRow: some View {
        HStack(spacing: 12) {
            Button {
                engageFollow()
                controller.rewindToStart()
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .buttonStyle(.borderless)
            .help("Return to start")

            Button {
                engageFollow()
                controller.playPause()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 24)
            }
            .buttonStyle(.borderless)
            .help(controller.isPlaying ? "Pause" : "Play")

            Text("\(Paragraph.timecode(controller.playbackTime)) / \(Paragraph.timecode(controller.duration))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 128, alignment: .leading)

            Text("Drag the red line to scrub · click frames or the voice track to jump")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer()
        }
    }

    // MARK: Timeline bands: frames on top, voice track under, shared scale

    /// Mark the scroll window as ours so the observer does not read the
    /// programmatic scrollTo as a user scroll.
    private func markProgrammaticScroll() {
        programmaticScrollUntil = Date().addingTimeInterval(0.5)
    }

    /// Give the follow back to the playhead: called from every direct
    /// playhead interaction (scrub, frame/clip tap, jump, transport).
    private func engageFollow() {
        scrollFollowSuspended = false
    }

    private var filmstripInterval: Double {
        let total = controller.duration
        guard total > 0 else { return 1 }
        let candidates: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        return candidates.first { total / $0 <= 60 } ?? (total / 60).rounded(.up)
    }

    private var filmstripTimes: [Double] {
        let total = controller.duration
        guard total > 0 else { return [] }
        let interval = filmstripInterval
        var times: [Double] = []
        var time: Double = 0
        while time < total {
            times.append(time)
            time += interval
        }
        return times
    }

    private var trackWidth: CGFloat {
        CGFloat(filmstripTimes.count) * (slotWidth + slotSpacing) - slotSpacing
    }

    private var playheadX: CGFloat {
        guard controller.duration > 0 else { return 0 }
        return trackWidth * controller.playbackTime / controller.duration
    }

    /// Clips on the active timeline: anchored starts on a video clip,
    /// computed sequential starts on a voice-only clip. Voice is always over
    /// a timeline.
    private var trackParagraphs: [(paragraph: Paragraph, start: Double)] {
        if viewModel.hasVideoClip {
            return viewModel.paragraphs
                .compactMap { paragraph in paragraph.startTime.map { (paragraph, $0) } }
                .sorted { $0.start < $1.start }
        }
        return viewModel.paragraphs
            .compactMap { paragraph in
                viewModel.timelineStart(forParagraphID: paragraph.id).map { (paragraph, $0) }
            }
    }

    private var anchoredParagraphs: [Paragraph] {
        trackParagraphs.map(\.paragraph)
    }

    private var timelineBands: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 8) {
                        LazyHStack(spacing: slotSpacing) {
                            ForEach(filmstripTimes, id: \.self) { time in
                                FilmstripSlot(
                                    time: time,
                                    interval: filmstripInterval,
                                    image: thumbnails[time],
                                    isActive: abs(controller.playbackTime - time) < filmstripInterval / 2
                                ) {
                                    engageFollow()
                                    controller.seek(to: time)
                                }
                                .id("slot-\(time)")
                                .task(id: time) {
                                    thumbnails[time] = await controller.thumbnail(at: time)
                                }
                            }
                        }

                        voiceTrack
                    }

                    // Playhead line spanning frames and voice track.
                    Rectangle()
                        .fill(Color.red.opacity(0.9))
                        .frame(width: 1.5)
                        .offset(x: playheadX + 4.75)
                        .allowsHitTesting(false)

                    // The red line is the scrub control: an invisible strip
                    // with a grab dot at the top, dragged anywhere along the
                    // timeline.
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 11)
                        .contentShape(Rectangle())
                        .overlay(alignment: .top) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 10, height: 10)
                                .offset(y: -3)
                                .help("Drag to scrub")
                        }
                        .overlay(alignment: .top) {
                            Rectangle()
                                .fill(Color.red.opacity(0.9))
                                .frame(width: 1.5)
                                .offset(y: 3)
                                .allowsHitTesting(false)
                        }
                        .offset(x: playheadX)
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    guard trackWidth > 0, controller.duration > 0 else { return }
                                    if playheadDragOrigin == nil {
                                        playheadDragOrigin = controller.playbackTime
                                        isScrubbingPlayhead = true
                                        engageFollow()
                                    }
                                    guard let origin = playheadDragOrigin else { return }
                                    // Drag by hand movement, not cursor position in the
                                    // content: the scroll-follow shifts the content under
                                    // the cursor, and absolute positions would feed back.
                                    let delta = Double(value.translation.width / trackWidth) * controller.duration
                                    controller.seek(to: origin + delta)
                                }
                                .onEnded { _ in
                                    playheadDragOrigin = nil
                                    isScrubbingPlayhead = false
                                }
                        )
                }
            }
            .coordinateSpace(name: "bands")
            .background(Color(NSColor.controlBackgroundColor))
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { viewportWidth = geo.size.width }
                        .onChange(of: geo.size.width) { viewportWidth = $0 }
                }
            )
            .background(
                TimelineScrollObserver {
                    // A bounds change we did not cause is the user moving the
                    // window: suspend the follow until they move the playhead.
                    if Date() >= programmaticScrollUntil {
                        scrollFollowSuspended = true
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onChange(of: controller.playbackTime) {
                // Manual scrolling owns the window: while suspended, the red
                // line moves within whatever the user is looking at and the
                // follow does not fight the scroller.
                guard !scrollFollowSuspended else { return }
                // Follow the playhead so the red line never ends up off-screen,
                // but without streaking: while it is being dragged, the view
                // only pages once the line nears the viewport edges.
                let slot = filmstripTimes.last(where: { $0 <= controller.playbackTime }) ?? 0
                if controller.isPlaying {
                    guard slot != followedSlot else { return }
                    followedSlot = slot
                    markProgrammaticScroll()
                    withAnimation(.linear(duration: 0.25)) {
                        proxy.scrollTo("slot-\(slot)", anchor: .center)
                    }
                } else if isScrubbingPlayhead {
                    let pageStride = max(2, Int(viewportWidth / (slotWidth + slotSpacing)) - 3)
                    guard abs(slot - (followedSlot ?? slot)) >= Double(pageStride) else { return }
                    followedSlot = slot
                    markProgrammaticScroll()
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo("slot-\(slot)", anchor: .center)
                    }
                } else {
                    guard slot != followedSlot else { return }
                    followedSlot = slot
                    markProgrammaticScroll()
                    proxy.scrollTo("slot-\(slot)", anchor: .center)
                }
            }
        }
    }

    /// The voice track: generated audio laid down as clips at their anchor
    /// times, lengths from the measured WAVs (dashed while still estimates).
    private var voiceTrack: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(NSColor.windowBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(NSColor.separatorColor).opacity(0.6), lineWidth: 1)
                )

            // Second ticks aligned with the filmstrip slots above.
            ForEach(filmstripInterval >= 1 ? filmstripTimes : [Double](), id: \.self) { time in
                Rectangle()
                    .fill(Color(NSColor.separatorColor).opacity(0.5))
                    .frame(width: 1, height: 6)
                    .offset(x: CGFloat(filmstripTimes.firstIndex(of: time) ?? 0)
                        * (slotWidth + slotSpacing) + slotWidth / 2 - 0.5, y: 0)
                    .allowsHitTesting(false)
            }

            ForEach(trackParagraphs, id: \.paragraph.id) { item in
                let paragraph = item.paragraph
                let start = item.start
                let duration = viewModel.audioDuration(forParagraphID: paragraph.id)
                VoiceClipView(
                    number: clipNumber(of: paragraph),
                    start: start,
                    duration: duration,
                    overlapsNext: viewModel.hasVideoClip && overlapsAnything(paragraph),
                    extendsPastEnd: start + duration > controller.duration + 0.01,
                    isEstimate: !viewModel.hasMeasuredAudioDuration(paragraph.id),
                    isPlayingNow: isClipPlaying(paragraph),
                    isRecorded: paragraph.isRecorded,
                    trackWidth: trackWidth,
                    totalDuration: controller.duration,
                    onTap: {
                        pinnedParagraphID = paragraph.id
                        engageFollow()
                        controller.seek(to: start)
                    },
                    onDrag: { seconds in
                        viewModel.moveParagraphClip(paragraph.id, to: seconds)
                    },
                    onDragEnded: {
                        viewModel.settleParagraphClip(paragraph.id)
                    }
                )
            }
        }
        .frame(width: max(trackWidth, 200), height: trackHeight)
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { location in
            guard trackWidth > 0, controller.duration > 0 else { return }
            controller.seek(to: Double(location.x / trackWidth) * controller.duration)
        }
    }

    private func overlapsAnything(_ paragraph: Paragraph) -> Bool {
        guard let start = unifiedStart(of: paragraph) else { return false }
        let end = start + viewModel.audioDuration(forParagraphID: paragraph.id)
        return trackParagraphs.contains { entry in
            guard entry.paragraph.id != paragraph.id else { return false }
            if entry.start > start {
                return end > entry.start + 0.01
            }
            return entry.start + viewModel.audioDuration(forParagraphID: entry.paragraph.id) > start + 0.01
        }
    }

    private func isClipPlaying(_ paragraph: Paragraph) -> Bool {
        guard let start = unifiedStart(of: paragraph) else { return false }
        let now = controller.playbackTime
        return now >= start && now < start + viewModel.audioDuration(forParagraphID: paragraph.id)
    }

    private func unifiedStart(of paragraph: Paragraph) -> Double? {
        if viewModel.hasVideoClip {
            return paragraph.startTime
        }
        return viewModel.timelineStart(forParagraphID: paragraph.id)
    }

    /// Move the playhead just past a freshly generated clip — plus the
    /// breathing gap — and then past any other clip already laid down, so it
    /// always lands in the next free voice segment.
    private func advancePlayheadPastClip(_ id: UUID) {
        guard let paragraph = viewModel.paragraphs.first(where: { $0.id == id }),
              let start = paragraph.startTime,
              paragraph.audioPath != nil || viewModel.hasMeasuredAudioDuration(id)
        else { return }
        let end = start + viewModel.audioDuration(forParagraphID: id)
        pinnedParagraphID = nil
        engageFollow()
        let advanced = viewModel.nextFreeVoiceSlot(after: end + postVoiceAdvanceSeconds)
        controller.seek(to: max(advanced, controller.playbackTime))
    }

    /// The "+" flow: commit the clip being edited (generating its voice if
    /// needed), advance past it into the next free voice segment, and create a
    /// fresh, empty clip there — the editor clears and is ready to type.
    private func beginNewTextFromPlayhead() async {
        // A fast double-press must not run the flow twice and stack clips.
        guard !isBeginningNewClip else { return }
        isBeginningNewClip = true
        defer { isBeginningNewClip = false }

        // Empty placeholders from earlier "+" presses that were never written
        // into are abandoned now — except the one about to be reused.
        viewModel.purgeEmptyPlaceholders(keeping: editorSegment?.paragraph.id)

        if let segment = editorSegment {
            let id = segment.paragraph.id
            let trimmed = segment.paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)

            // An anchored but empty clip is already "the new clip" — reuse it
            // rather than stacking another blank.
            guard !trimmed.isEmpty else {
                if segment.paragraph.startTime == nil {
                    _ = viewModel.setParagraphStart(id, at: controller.playbackTime)
                    viewModel.statusMessage = "Anchored at the playhead — type the narration first."
                } else {
                    viewModel.statusMessage = "This clip is empty — type its narration, or move the playhead elsewhere first."
                }
                pinnedParagraphID = nil
                textIsFocused = true
                return
            }

            // Place unanchored text at the playhead before committing it.
            if segment.paragraph.startTime == nil {
                _ = viewModel.setParagraphStart(id, at: controller.playbackTime)
            }

            // Commit: generate the voice if we don't have it yet.
            if viewModel.paragraphs.first(where: { $0.id == id })?.audioPath == nil {
                await viewModel.generateAudio(for: id)
            } else if !viewModel.hasMeasuredAudioDuration(id) {
                await viewModel.measureAudioDuration(for: id)
            }

            // If synthesis was rejected (empty, too short, engine not ready),
            // stay on this text so it can be fixed — no advance, no new clip.
            guard viewModel.paragraphs.first(where: { $0.id == id })?.audioPath != nil,
                  let start = viewModel.paragraphs.first(where: { $0.id == id })?.startTime
            else {
                textIsFocused = true
                return
            }

            await viewModel.refreshVideoPreview()
            let end = start + viewModel.audioDuration(forParagraphID: id)
            // The playhead only ever moves forward. The commit above may be
            // an older pinned clip whose end sits behind where the user has
            // scrubbed to — advancing relative to it would drag the playhead
            // and the whole view back up the timeline.
            engageFollow()
            let advanced = viewModel.nextFreeVoiceSlot(after: end + postVoiceAdvanceSeconds)
            controller.seek(to: max(advanced, controller.playbackTime))
        } else {
            // Nothing at the playhead: still never overlap what is laid down.
            controller.seek(to: viewModel.nextFreeVoiceSlot(after: controller.playbackTime))
        }

        // New clip, further along the track, empty editor, cursor ready.
        if viewModel.createParagraphAtPlayhead() != nil {
            pinnedParagraphID = nil
            textIsFocused = true
        }
    }

    // MARK: Playhead-following text editor

    /// The paragraph whose voice clip is sounding at the playhead, or the next
    /// upcoming one when the playhead sits in a gap.
    private var playheadSegment: (paragraph: Paragraph, position: Int, isCurrent: Bool)? {
        let entries = trackParagraphs
        for entry in entries {
            let end = entry.start + max(viewModel.audioDuration(forParagraphID: entry.paragraph.id), 0.25)
            if controller.playbackTime >= entry.start && controller.playbackTime < end {
                return (entry.paragraph, clipNumber(of: entry.paragraph) ?? 0, true)
            }
        }
        if let next = entries.first(where: { $0.start > controller.playbackTime }) {
            return (next.paragraph, clipNumber(of: next.paragraph) ?? 0, false)
        }
        guard let first = entries.first else { return nil }
        return (first.paragraph, clipNumber(of: first.paragraph) ?? 0, false)
    }

    /// What the editor shows: the pinned paragraph while typing (or when a
    /// chip for an unanchored paragraph was picked), otherwise the playhead's.
    private var editorSegment: (paragraph: Paragraph, position: Int, isCurrent: Bool)? {
        if let pinned = pinnedParagraphID,
           let paragraph = viewModel.paragraphs.first(where: { $0.id == pinned }) {
            if paragraph.startTime == nil {
                let position = (viewModel.scriptParagraphIndex(for: paragraph.id) ?? 0) + 1
                return (paragraph, position, false)
            }
            let position = clipNumber(of: paragraph) ?? 0
            return (paragraph, position, playheadSegment?.paragraph.id == paragraph.id)
        }
        return playheadSegment
    }

    private var unanchoredParagraphs: [Paragraph] {
        viewModel.paragraphs.filter { $0.startTime == nil }
    }

    /// Anchored clips that carry content (text or audio). Empty placeholders
    /// render as dimmed stubs and never take a clip number.
    private var contentAnchoredParagraphs: [Paragraph] {
        anchoredParagraphs.filter { paragraph in
            !paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || paragraph.audioPath != nil
        }
    }

    private func clipNumber(of paragraph: Paragraph) -> Int? {
        contentAnchoredParagraphs.firstIndex { $0.id == paragraph.id }.map { $0 + 1 }
    }

    private func stepSegment(_ direction: Int) {
        let entries = trackParagraphs
        guard !entries.isEmpty else { return }
        engageFollow()
        let playhead = controller.playbackTime
        let target: Double
        if direction < 0 {
            target = entries.last(where: { $0.start < playhead - 0.05 })?.start ?? entries[0].start
        } else {
            target = entries.first(where: { $0.start > playhead + 0.05 })?.start ?? entries[entries.count - 1].start
        }
        textIsFocused = false
        pinnedParagraphID = nil
        controller.seek(to: target)
    }

    private func segmentBadge(_ segment: (paragraph: Paragraph, position: Int, isCurrent: Bool)) -> String {
        let start = segment.paragraph.startTime ?? 0
        let duration = viewModel.audioDuration(forParagraphID: segment.paragraph.id)
        let state = segment.isCurrent ? "playing now" : "up next"
        let note = viewModel.hasMeasuredAudioDuration(segment.paragraph.id) ? "" : " · estimated"
        return "Text \(segment.position) of \(contentAnchoredParagraphs.count) · \(Paragraph.timecode(start)) → \(Paragraph.timecode(start + duration)) · voice \(String(format: "%.1f", duration))s\(note) · \(state)"
    }

    private var segmentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    stepSegment(-1)
                } label: {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(.borderless)
                .help("Jump to the previous voice clip")

                Button {
                    stepSegment(1)
                } label: {
                    Image(systemName: "forward.end.fill")
                }
                .buttonStyle(.borderless)
                .help("Jump to the next voice clip")

                if let segment = editorSegment {
                    Text(segmentBadge(segment))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(segment.isCurrent ? Color.accentColor : .secondary)
                        .lineLimit(1)
                } else {
                    Text("No voice clips in this video yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Task { await beginNewTextFromPlayhead() }
                } label: {
                    Label("New Text at Playhead", systemImage: "plus")
                }
                .controlSize(.small)
                .disabled(viewModel.isProcessing)
                .help("Generate the current text if it has no voice yet, advance past its clip, and start the next text there")
            }

            if let segment = editorSegment {
                SegmentEditor(
                    paragraph: viewModel.paragraphBinding(segment.paragraph.id),
                    isCurrent: segment.isCurrent,
                    isVideoClip: viewModel.hasVideoClip,
                    isRecorded: segment.paragraph.isRecorded,
                    voiceDuration: viewModel.audioDuration(forParagraphID: segment.paragraph.id),
                    voiceDurationIsEstimate: !viewModel.hasMeasuredAudioDuration(segment.paragraph.id),
                    isTTSReady: viewModel.isTTSReady,
                    isLLMReady: viewModel.isLLMReady,
                    voiceOptions: viewModel.voiceOptions,
                    focus: $textIsFocused,
                    onStartAtPlayhead: {
                        if viewModel.setParagraphStart(segment.paragraph.id, at: controller.playbackTime) != nil {
                            pinnedParagraphID = nil
                        }
                    },
                    onUnlock: {
                        viewModel.unlockParagraph(segment.paragraph.id)
                    },
                    onGenerate: {
                        Task {
                            // Generate, measure the real length, pull the clip
                            // into preview playback, then move the playhead
                            // past the clip so writing can continue.
                            await viewModel.generateAudio(for: segment.paragraph.id)
                            await viewModel.refreshVideoPreview()
                            advancePlayheadPastClip(segment.paragraph.id)
                        }
                    },
                    onPlay: {
                        viewModel.playAudio(for: segment.paragraph.id)
                    },
                    onImprove: {
                        Task { await viewModel.improveText(for: segment.paragraph.id) }
                    },
                    onVoiceSelectionChanged: { voiceID in
                        viewModel.handleVoiceSelectionChange(for: segment.paragraph.id, voiceID: voiceID)
                    }
                )
            } else {
                ContentUnavailableView {
                    Label("No Voice at the Playhead", systemImage: "waveform")
                } description: {
                    Text("Move the playhead where narration should begin, then add text. Generating the voice lays the clip on the track with its real length.")
                } actions: {
                    Button("New Text at Playhead") {
                        Task { await beginNewTextFromPlayhead() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 140)
            }

            if !unanchoredParagraphs.isEmpty {
                HStack(spacing: 6) {
                    Text("Not placed:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(unanchoredParagraphs) { paragraph in
                        Button {
                            pinnedParagraphID = paragraph.id
                        } label: {
                            Text(paragraph.text.isEmpty
                                ? "Text \(viewModel.scriptParagraphIndex(for: paragraph.id).map { $0 + 1 } ?? 0)"
                                : String(paragraph.text.prefix(18)))
                                .font(.caption)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary.opacity(0.6), in: Capsule())
                        }
                        .buttonStyle(.borderless)
                        .help("Edit this unplaced text, then use Start → at Playhead to place it")
                    }
                }
            }
        }
    }

    private var statusFooter: some View {
        HStack(spacing: 8) {
            if viewModel.isVideoExporting {
                ProgressView()
                    .controlSize(.small)
            }
            Text(viewModel.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
    }
}

// MARK: - Manual scroll detection

/// Reports bounds changes of the enclosing NSScrollView so the sheet can tell
/// user scrolling (window ownership moves to the person) apart from the
/// programmatic follow scrolling.
private struct TimelineScrollObserver: NSViewRepresentable {
    var onScroll: () -> Void

    final class ObserverView: NSView {
        var onScroll: (() -> Void)?
        private var observation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, observation == nil else { return }
            DispatchQueue.main.async { self.attachIfNeeded() }
        }

        private func attachIfNeeded() {
            guard observation == nil else { return }
            var candidate: NSView? = superview
            while let view = candidate, !(view is NSScrollView) {
                candidate = view.superview
            }
            guard let scrollView = candidate as? NSScrollView else { return }
            observation = scrollView.contentView.observe(\.bounds, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.onScroll?() }
            }
        }
    }

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onScroll = onScroll
    }
}

// MARK: - Filmstrip slot

private struct FilmstripSlot: View {
    let time: Double
    let interval: Double
    let image: NSImage?
    let isActive: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 3) {
                ZStack {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle()
                            .fill(Color(NSColor.quaternaryLabelColor))
                            .overlay {
                                ProgressView()
                                    .controlSize(.small)
                            }
                    }
                }
                .frame(width: 128, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(
                            isActive ? Color.accentColor : Color(NSColor.separatorColor).opacity(0.6),
                            lineWidth: isActive ? 2 : 1
                        )
                )

                Text(Paragraph.timecode(time))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isActive ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .help("Jump to \(Paragraph.timecode(time))")
    }
}

// MARK: - Voice clip on the track

private struct VoiceClipView: View {
    /// Clip number shown on the badge; nil for empty placeholder stubs.
    let number: Int?
    let start: Double
    let duration: Double
    let overlapsNext: Bool
    let extendsPastEnd: Bool
    let isEstimate: Bool
    let isPlayingNow: Bool
    let isRecorded: Bool
    let trackWidth: CGFloat
    let totalDuration: Double
    let onTap: () -> Void
    let onDrag: (Double) -> Void
    let onDragEnded: () -> Void

    @State private var dragOriginStart: Double?

    private var isEmptyPlaceholder: Bool { number == nil }

    private var x: CGFloat {
        guard totalDuration > 0 else { return 0 }
        return trackWidth * start / totalDuration
    }

    /// True proportional width, with only a badge-sized minimum so short or
    /// empty clips never visually run over their neighbours.
    private var width: CGFloat {
        guard totalDuration > 0 else { return 18 }
        return max(isEmptyPlaceholder ? 14 : 18, trackWidth * duration / totalDuration)
    }

    /// Green clips are live: draggable and changeable. Orange clips are
    /// recorded to an export: locked until explicitly unlocked. Empty
    /// placeholders are dimmed stubs.
    private var stateColor: Color {
        if isEmptyPlaceholder {
            return .secondary
        }
        return isRecorded ? .orange : .green
    }

    private var strokeColor: Color {
        if overlapsNext || extendsPastEnd {
            return .red
        }
        return stateColor
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                if let number {
                    Text("\(number)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(stateColor))
                }

                if width > 130 {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Paragraph.timecode(start))
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.primary)
                        Text(String(format: "%.1fs", duration))
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if width > 40 {
                    Image(systemName: isEmptyPlaceholder
                        ? "plus"
                        : (isRecorded ? "lock.fill" : "waveform"))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .frame(width: width, height: 30, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isEmptyPlaceholder
                        ? Color(NSColor.quaternaryLabelColor).opacity(0.5)
                        : stateColor.opacity(isPlayingNow ? 0.40 : 0.22))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(strokeColor, style: isEstimate || isEmptyPlaceholder
                        ? StrokeStyle(lineWidth: 1, dash: [4, 3])
                        : StrokeStyle(lineWidth: isPlayingNow ? 1.5 : 1))
            )
        }
        .buttonStyle(.plain)
        .offset(x: x, y: 8)
        .gesture(
            isRecorded ? nil : DragGesture(minimumDistance: 5)
                .onChanged { value in
                    guard trackWidth > 0, totalDuration > 0 else { return }
                    if dragOriginStart == nil {
                        dragOriginStart = start
                    }
                    guard let origin = dragOriginStart else { return }
                    // Hand-movement delta: the timeline may scroll (or the clip
                    // move within the layout) mid-drag; absolute positions
                    // would feed back.
                    let delta = Double(value.translation.width / trackWidth) * totalDuration
                    onDrag(origin + delta)
                }
                .onEnded { _ in
                    dragOriginStart = nil
                    onDragEnded()
                }
        )
        .help(helpText)
    }

    private var helpText: String {
        if isEmptyPlaceholder {
            return "Empty clip at \(Paragraph.timecode(start)) — select it and type, or press + elsewhere to drop it."
        }
        var lines = ["Clip \(number ?? 0): voice at \(Paragraph.timecode(start)), \(String(format: "%.1f", duration))s"
            + (isEstimate ? " (estimated — generate to measure)" : " (measured)")]
        if isRecorded {
            lines.append("Recorded to the video — locked. Unlock it in the editor below to change.")
        } else {
            lines.append("Drag to move; too-close clips are pushed apart automatically.")
        }
        if overlapsNext {
            lines.append("Runs into the next clip.")
        }
        if extendsPastEnd {
            lines.append("Runs past the end of the video; export truncates it.")
        }
        return lines.joined(separator: " ")
    }
}

// MARK: - Segment editor

private struct SegmentEditor: View {
    @Binding var paragraph: Paragraph
    let isCurrent: Bool
    let isVideoClip: Bool
    let isRecorded: Bool
    let voiceDuration: Double
    let voiceDurationIsEstimate: Bool
    let isTTSReady: Bool
    let isLLMReady: Bool
    let voiceOptions: [VoiceOption]
    let focus: FocusState<Bool>.Binding
    let onStartAtPlayhead: () -> Void
    let onUnlock: () -> Void
    let onGenerate: () -> Void
    let onPlay: () -> Void
    let onImprove: () -> Void
    let onVoiceSelectionChanged: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Type the narration for this part of the video…", text: $paragraph.text, axis: .vertical)
                .focused(focus)
                .disabled(isRecorded)
                .font(.body)
                .lineSpacing(3)
                .lineLimit(2...8)
                .padding(10)
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            isRecorded ? Color.orange.opacity(0.7)
                                : (isCurrent ? Color.accentColor.opacity(0.55) : Color(NSColor.separatorColor).opacity(0.5)),
                            lineWidth: 1
                        )
                )
                .frame(minHeight: 84)

            if isRecorded {
                HStack(spacing: 8) {
                    Label("Recorded to the video — locked. Unlock to move or change it; exporting again will include the new version.", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button(action: onUnlock) {
                        Label("Unlock", systemImage: "lock.open")
                    }
                    .controlSize(.small)
                }
            }

            HStack(spacing: 14) {
                if isVideoClip {
                    HStack(spacing: 6) {
                        Text("Start")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(paragraph.startTime.map { Paragraph.timecode($0) } ?? "—:—")
                            .font(.callout.monospacedDigit())
                            .frame(minWidth: 44, alignment: .leading)
                        Button("at Playhead", action: onStartAtPlayhead)
                            .controlSize(.small)
                            .disabled(isRecorded)
                    }

                    Divider()
                        .frame(height: 16)
                }

                // The clip's length on the voice track: computed from the
                // generated WAV, estimated from the text until then.
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.1fs", voiceDuration))
                        .font(.callout.monospacedDigit())
                    Text(voiceDurationIsEstimate ? "estimated" : "measured")
                        .font(.caption)
                        .foregroundStyle(voiceDurationIsEstimate ? Color.secondary : Color.green)
                    if let start = paragraph.startTime {
                        Text("→ ends \(Paragraph.timecode(start + voiceDuration))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Picker(selection: $paragraph.voiceID) {
                    ForEach(voiceOptions) { option in
                        Text(option.name).tag(option.id)
                    }
                } label: {
                    Label("Voice", systemImage: "person.wave.2")
                }
                .labelsHidden()
                .fixedSize()
                .disabled(isRecorded)
                .onChange(of: paragraph.voiceID) {
                    onVoiceSelectionChanged(paragraph.voiceID)
                }
                .help("Voice preset for this voice-over")

                if paragraph.isGenerating {
                    ProgressView()
                        .controlSize(.small)
                    Text("Generating…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    if !isTTSReady {
                        Text("Speech engine not loaded")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("Initialize the speech engine in Settings before generating")
                    }
                    Button(action: onImprove) {
                        Image(systemName: "wand.and.stars")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!isLLMReady || paragraph.isGenerating || isRecorded)
                    .help("Improve the text for speech with the local language model")

                    if paragraph.audioPath != nil {
                        Button(action: onPlay) {
                            Image(systemName: "play.fill")
                                .frame(width: 22)
                        }
                        .buttonStyle(.borderless)
                        .help("Play this text's audio")

                        Button(action: onGenerate) {
                            Image(systemName: "arrow.clockwise")
                                .frame(width: 22)
                        }
                        .buttonStyle(.borderless)
                        .disabled(!isTTSReady || isRecorded)
                        .help(isRecorded ? "Recorded clip — unlock to regenerate" : "Regenerate audio from the current text; the clip length updates")
                    } else {
                        Button(action: onGenerate) {
                            Label("Generate", systemImage: "waveform")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!isTTSReady || isRecorded)
                        .help("Compute the voice, measure its length, and lay the clip on the track")
                    }
                }
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
}

// MARK: - AVPlayerLayer host

struct VideoPlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerContainerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }

    final class PlayerContainerView: NSView {
        private let playerLayer = AVPlayerLayer()
        var player: AVPlayer? {
            didSet {
                playerLayer.player = player
            }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) {
            fatalError("PlayerContainerView is created in code only")
        }

        override func layout() {
            super.layout()
            playerLayer.frame = bounds
        }
    }
}
