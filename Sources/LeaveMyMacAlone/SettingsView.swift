import AppKit
import SwiftUI
import LeaveMyMacAloneCore

/// The menu-bar panel: live lock-screen preview, the Lock button, the lock-screen
/// message and moving icon, quick toggles, and update/quit.
struct SettingsView: View {
    @ObservedObject var store: AppSettingsStore
    @ObservedObject var updates: UpdateController
    let onLockNow: () -> Void
    let onQuit: () -> Void
    // true while the user is dragging the opacity slider; drives the live preview.
    let onSliderEditing: (Bool) -> Void
    // Called when the user turns the intruder-capture toggle ON (prime perms).
    let onCaptureIntruderEnabled: () -> Void
    // Open the captured-photos folder in Finder.
    let onOpenIntruderPhotos: () -> Void
    // User-initiated update check (Sparkle's standard UI).
    let onCheckForUpdates: () -> Void
    // Pick an image file for the moving icon (closes the panel while choosing).
    let onChooseImage: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            MiniLockPreview(store: store)

            LockNowButton(action: onLockNow)

            MessageCard(store: store)

            FloatingIconCard(store: store,
                             onSliderEditing: onSliderEditing,
                             onChooseImage: onChooseImage)

            QuickToggles(store: store,
                         updates: updates,
                         onCaptureIntruderEnabled: onCaptureIntruderEnabled,
                         onOpenIntruderPhotos: onOpenIntruderPhotos,
                         onCheckForUpdates: onCheckForUpdates)

            HStack {
                Button("Güncellemeleri kontrol et", action: onCheckForUpdates)
                    .buttonStyle(.link)
                    .font(.caption)
                Spacer()
                Button(action: onQuit) {
                    Label("Çık", systemImage: "power")
                        .font(.caption)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 300)
        // The panel window is borderless/clear, so the card draws its own frosted
        // background + rounded corners (matches a native menu-bar dropdown).
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - Preview

/// A small live replica of the lock screen. The real lock dims whatever is on
/// screen (it does not show the wallpaper), so the backdrop is an abstract
/// desktop with a few windows under the chosen darkness, plus the message,
/// return time, clock and the drifting icon.
private struct MiniLockPreview: View {
    @ObservedObject var store: AppSettingsStore

    private let inset: CGFloat = 8

    var body: some View {
        // A fixed-size base keeps every layer (and the pills) inside the box.
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 124)
            .background(AbstractDesktop())
            .overlay(Color.black.opacity(store.overlayOpacity))
            .overlay(content)
            .overlay {
                if let icon = previewIcon {
                    BouncingIconView(icon: icon, size: 22, speed: 34)
                        .padding(6)
                        // Restart the drift when the icon changes.
                        .id(iconIdentity)
                }
            }
            .overlay(alignment: .topLeading) {
                Pill(text: Text("Önizleme")).padding(inset)
            }
            .overlay(alignment: .topTrailing) {
                Pill(text: Text(verbatim: "v\(UpdateController.currentVersion)")).padding(inset)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var content: some View {
        TimelineView(.everyMinute) { context in
            let status = store.awayStatus(lockedAt: context.date)
            VStack(spacing: 2) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 15, weight: .semibold))
                Text("Kilitli")
                    .font(.system(size: 10))
                    .opacity(0.8)
                if let headline = status?.headline {
                    headlineText(headline)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                }
                if let returnTime = status?.returnTime {
                    Text("Dönüş: \(Text(returnTime, style: .time))")
                        .font(.system(size: 10))
                        .opacity(0.85)
                }
                Text(context.date, style: .time)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .padding(.top, 2)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 30)
            .padding(.top, 14)
        }
    }

    private var previewIcon: FloatingIcon? {
        // Re-read when the imported image changes (floatingImageName is re-set on import).
        _ = store.floatingImageName
        return store.floatingIcon()
    }

    private var iconIdentity: String {
        "\(store.floatingKind.rawValue)|\(store.floatingEmoji)|\(store.floatingImageName ?? "")"
    }

    private func headlineText(_ headline: AwayStatus.Headline) -> Text {
        switch headline {
        case .custom(let text): return Text(verbatim: text)
        case .preset(let preset): return Text(preset.lockScreenTitle)
        }
    }
}

private struct Pill: View {
    let text: Text

    var body: some View {
        text
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.white.opacity(0.16), in: Capsule())
    }
}

/// Stand-in for "whatever is on your screen": a desktop with a couple of windows.
private struct AbstractDesktop: View {
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            ZStack(alignment: .topLeading) {
                Color(red: 0.36, green: 0.42, blue: 0.50)
                window.frame(width: w * 0.55, height: h * 0.62).offset(x: w * 0.06, y: h * 0.20)
                window.frame(width: w * 0.42, height: h * 0.55).offset(x: w * 0.50, y: h * 0.34)
            }
        }
    }

    private var window: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color(white: 0.93))
            .overlay(alignment: .top) {
                Rectangle().fill(Color(white: 0.82)).frame(height: 9)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

// MARK: - Lock button

private struct LockNowButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                Text("Şimdi Kilitle")
                Text(verbatim: "⌃⌥⌘L")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 5))
                    .padding(.leading, 4)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(Color.primary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Message

private struct MessageCard: View {
    @ObservedObject var store: AppSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("MESAJ")

            FlowLayout(spacing: 6) {
                ForEach(AwayPreset.allCases, id: \.self) { preset in
                    ChipButton(title: preset.chipTitle,
                               systemImage: preset == .custom ? "pencil" : nil,
                               selected: store.awayPreset == preset) {
                        store.awayPreset = preset
                    }
                }
            }

            if store.awayPreset == .custom {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mesajın")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Örn. Kahve almaya gittim", text: $store.awayCustomText)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: store.awayCustomText) { _, text in
                            if text.count > AwayStatus.maxCustomLength {
                                store.awayCustomText = String(text.prefix(AwayStatus.maxCustomLength))
                            }
                        }
                }
            }

            Divider()

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Dönüş saati")
                        .font(.system(size: 13, weight: .semibold))
                    Text(store.awayReturnEnabled ? "Kilitlediğin andan itibaren" : "Kilit ekranında gösterilmez")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Toggle("Dönüş saati", isOn: $store.awayReturnEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            if store.awayReturnEnabled {
                ReturnStepper(store: store)
            }
        }
        .modifier(PanelCard())
    }
}

/// "− 14:30 +": the return time as it will appear, stepped in ReturnTimeSteps.
/// Clicking the time lets the user type any duration ("50", "1:30").
private struct ReturnStepper: View {
    @ObservedObject var store: AppSettingsStore

    @State private var editing = false
    @State private var draft = ""
    @State private var draftInvalid = false
    @FocusState private var fieldFocused: Bool

    private func beginEditing() {
        draft = ""
        draftInvalid = false
        editing = true
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func commit() {
        guard let minutes = ReturnTimeSteps.parseDuration(draft) else {
            draftInvalid = true
            return
        }
        store.awayReturnMinutes = minutes
        editing = false
    }

    var body: some View {
        HStack(spacing: 10) {
            StepButton(systemImage: "minus", label: "Daha erken") {
                editing = false
                store.awayReturnMinutes = ReturnTimeSteps.previous(before: store.awayReturnMinutes)
            }
            Group {
                if editing {
                    VStack(spacing: 2) {
                        TextField("Örn. 50 veya 1:30", text: $draft)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.center)
                            .focused($fieldFocused)
                            .onSubmit(commit)
                            .onExitCommand { editing = false }
                        Text(draftInvalid ? "Dakika (en çok 12 sa)" : "Süreyi yaz, Enter'a bas")
                            .font(.caption)
                            .foregroundStyle(draftInvalid ? Color.red : .secondary)
                    }
                } else {
                    Button(action: beginEditing) {
                        TimelineView(.everyMinute) { context in
                            VStack(spacing: 0) {
                                if let time = store.awayStatus(lockedAt: context.date)?.returnTime {
                                    Text(time, style: .time)
                                        .font(.system(size: 22, weight: .semibold).monospacedDigit())
                                }
                                HStack(spacing: 3) {
                                    Text(verbatim: Self.relative(store.awayReturnMinutes))
                                    Image(systemName: "pencil").font(.system(size: 9, weight: .semibold))
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Süreyi elle yazmak için tıkla")
                }
            }
            .frame(maxWidth: .infinity)
            StepButton(systemImage: "plus", label: "Daha geç") {
                editing = false
                store.awayReturnMinutes = ReturnTimeSteps.next(after: store.awayReturnMinutes)
            }
        }
        .padding(6)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// 30 → "30 dk sonra", 60 → "1 sa sonra", 90 → "1 sa 30 dk sonra".
    static func relative(_ minutes: Int) -> String {
        let (h, m) = ReturnTimeSteps.split(minutes)
        if h == 0 {
            return String(format: NSLocalizedString("%d dk sonra", comment: "Return in minutes"), m)
        }
        if m == 0 {
            return String(format: NSLocalizedString("%d sa sonra", comment: "Return in hours"), h)
        }
        return String(format: NSLocalizedString("%d sa %d dk sonra", comment: "Return in hours and minutes"), h, m)
    }
}

private struct StepButton: View {
    let systemImage: String
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(Color.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Moving icon

private struct FloatingIconCard: View {
    @ObservedObject var store: AppSettingsStore
    let onSliderEditing: (Bool) -> Void
    let onChooseImage: () -> Void

    static let presetEmojis = ["☕", "🍔", "🎧", "💤", "👋", "🚀", "🐱", "🌴", "🏃"]

    @State private var showingPicker = false

    private var opacityPercent: Int { Int((store.overlayOpacity * 100).rounded()) }

    /// An emoji picked from the palette that isn't one of the presets.
    private var customEmoji: String? {
        Self.presetEmojis.contains(store.floatingEmoji) ? nil : store.floatingEmoji
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("HAREKETLİ SİMGE")
                Spacer()
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                IconTile(selected: store.floatingKind == .none, label: "Simge yok") {
                    Image(systemName: "nosign").foregroundStyle(.secondary)
                } action: {
                    store.floatingKind = .none
                }
                ForEach(Self.presetEmojis, id: \.self) { emoji in
                    IconTile(selected: store.floatingKind == .emoji && store.floatingEmoji == emoji,
                             label: LocalizedStringKey(emoji)) {
                        Text(verbatim: emoji).font(.system(size: 19))
                    } action: {
                        store.floatingEmoji = emoji
                        store.floatingKind = .emoji
                    }
                }
                IconTile(selected: showingPicker || (store.floatingKind == .emoji && customEmoji != nil),
                         label: "Diğer emojiler") {
                    if let custom = customEmoji, !showingPicker {
                        Text(verbatim: custom).font(.system(size: 19))
                    } else {
                        Image(systemName: showingPicker ? "chevron.up" : "ellipsis")
                            .foregroundStyle(.secondary)
                    }
                } action: {
                    showingPicker.toggle()
                }
                IconTile(selected: store.floatingKind == .image, label: "Görsel") {
                    Image(systemName: "photo")
                        .foregroundStyle(store.floatingKind == .image ? Color.accentColor : .secondary)
                } action: {
                    if store.floatingImageName != nil, FloatingImageStore.load() != nil {
                        store.floatingKind = .image
                    } else {
                        onChooseImage()
                    }
                }
            }

            if showingPicker {
                EmojiPicker { emoji in
                    store.floatingEmoji = emoji
                    store.floatingKind = .emoji
                    showingPicker = false
                }
            }

            if store.floatingKind == .image, let name = store.floatingImageName {
                HStack(spacing: 8) {
                    if let image = FloatingImageStore.load() {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 24, height: 24)
                    }
                    Text(verbatim: name)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("Değiştir", action: onChooseImage)
                        .buttonStyle(.link)
                        .font(.caption)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 8) {
                Text("Koyuluk")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .leading)
                Slider(value: $store.overlayOpacity, in: Transparency.range,
                       onEditingChanged: onSliderEditing)
                    .controlSize(.small)
                Text(verbatim: "\(opacityPercent)%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
        }
        .modifier(PanelCard())
    }

    private var caption: LocalizedStringKey {
        switch store.floatingKind {
        case .none: return "Kapalı"
        case .emoji: return customEmoji == nil ? "Emoji" : "Özel emoji"
        case .image: return "Kendi görselin"
        }
    }

}

/// The full emoji set, searchable, inside the panel. (The system Emoji &
/// Symbols window can't be used: it lives in another process — clicking it
/// dismisses this panel — and it types into the *active* app, which this
/// non-activating panel never is, so the pick would be lost.)
private struct EmojiPicker: View {
    let onPick: (String) -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var results: [String] { EmojiCatalog.search(query) }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Ara (İngilizce: cat, pizza, heart)", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 8), spacing: 2) {
                    ForEach(results, id: \.self) { emoji in
                        Button { onPick(emoji) } label: {
                            Text(verbatim: emoji)
                                .font(.system(size: 20))
                                .frame(maxWidth: .infinity, minHeight: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(EmojiCellStyle())
                    }
                }
                if results.isEmpty {
                    Text("Sonuç yok")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 20)
                }
            }
            .frame(height: 168)
        }
        .padding(6)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear { searchFocused = true }
    }
}

private struct EmojiCellStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.accentColor.opacity(0.3) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct IconTile<Content: View>: View {
    let selected: Bool
    let label: LocalizedStringKey
    @ViewBuilder let content: () -> Content
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 9))
                .background(selected ? Color.accentColor.opacity(0.25) : .clear,
                            in: RoundedRectangle(cornerRadius: 9))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Quick toggles

private struct QuickToggles: View {
    @ObservedObject var store: AppSettingsStore
    @ObservedObject var updates: UpdateController
    let onCaptureIntruderEnabled: () -> Void
    let onOpenIntruderPhotos: () -> Void
    let onCheckForUpdates: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ToggleTile(title: "Uyanık tut", systemImage: "cup.and.saucer.fill",
                       isOn: store.preventSleepWhileLocked,
                       help: "Kilitliyken Mac uykuya geçmez.") {
                store.preventSleepWhileLocked.toggle()
            }
            ToggleTile(title: "İzinsiz giriş", systemImage: "camera.fill",
                       isOn: store.captureIntruderPhoto,
                       help: "Kilidi zorlayanın ön kameradan fotoğrafını çeker. Sağ tık: fotoğraflar.") {
                store.captureIntruderPhoto.toggle()
                if store.captureIntruderPhoto { onCaptureIntruderEnabled() }
            }
            .contextMenu {
                Button("İzinsiz giriş fotoğraflarını aç", action: onOpenIntruderPhotos)
            }
            ToggleTile(title: "Güncelleme", systemImage: "arrow.triangle.2.circlepath",
                       isOn: updates.automaticallyUpdates,
                       onText: "Otomatik", offText: "Elle",
                       help: "Yeni sürümler arka planda indirilir ve kilit açıkken kurulur.") {
                updates.automaticallyUpdates.toggle()
            }
            .contextMenu {
                Button("Şimdi kontrol et", action: onCheckForUpdates)
            }
        }
    }
}

private struct ToggleTile: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isOn: Bool
    var onText: LocalizedStringKey = "Açık"
    var offText: LocalizedStringKey = "Kapalı"
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isOn ? Color.white : Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(isOn ? Color.accentColor : Color.primary.opacity(0.15), in: Circle())
                VStack(spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(isOn ? onText : offText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - Shared pieces

private struct PanelCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct SectionLabel: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(.secondary)
    }
}

private struct ChipButton: View {
    let title: LocalizedStringKey
    let systemImage: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
                }
                Text(title).lineLimit(1).fixedSize()
            }
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(selected ? Color.accentColor : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.2)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Lays children out left to right, wrapping to a new line when a row is full.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let isFirst = rows[rows.count - 1].indices.isEmpty
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += isFirst ? size.width : size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
