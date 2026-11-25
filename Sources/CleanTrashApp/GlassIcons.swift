import SwiftUI

/// Layered Frosted Glass Icon Engine adapted from the Glass Dock motion system:
/// Every CleanTrash icon is constructed on a normalized 104×104 coordinate space as
/// **vibrant solid colored back geometry behind a translucent frosted tinted glass front pane**
/// (top inner specular shine + crisp 0.75 white hairline + soft contact shadow), complete with
/// bespoke spring-damped micro-interactions per icon on hover, selection, or active state:
///
/// - `.trash` (Basura / Bandeja Files): blue folder whose frosted front tips forward (`rotateX +32°`)
///   while two paper sheets (`#fff` + `#fff8ef`) spring upward and fan out (`-10°` / `+9°`).
/// - `.notch` (Centro Notch / Música): grooved violet vinyl disc behind a frosted glass sleeve;
///   on hover/active the sleeve & disc slide apart, the record spins, and 4 equalizer bars dance!
/// - `.dev` (Radar Dev / Agentes): coral back speech/terminal bubble behind a frosted glass bubble
///   with 3 animated typing dots + micro coral spark bubble rising on hover!
/// - `.disk` / `.diskmap` (Mapa de disco): sun-gold & rose-pink circles behind a frosted glass print
///   with a crisp white storage ridge that shifts with subtle parallax!
/// - `.vault` (Bóveda): emerald-mint solid shackle + core behind a frosted glass padlock whose
///   shackle lifts & tilts open with a damped spring on hover/unlock!
/// - `.smartcare` / `.mac`: indigo-blue chassis behind a frosted glass display with glowing status spark.
/// - `.cpu`, `.memory`, `.gpu`, `.performance`, `.apps`, `.settings`: tailored multi-layer frosted glass icons.
struct GlassLayeredIcon: View {
    let name: Icon3DName
    var size: CGFloat = 32
    var isActive: Bool = false
    var externalHover: Bool = false
    var interactive: Bool = true
    var tiltX: Double = 0 // -1...1 normalized horizontal cursor offset for 3D tilt

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var localHover = false
    @State private var pulsePhase = false

    /// Unit scale factor from the 104px Glass Dock design grid.
    private var u: CGFloat { size / 104.0 }

    /// Micro-interaction engagement (0 → 1) driven by hover or active state.
    private var engaged: Bool {
        guard !Mono.snapshotMode else { return isActive }
        return (interactive && (localHover || externalHover)) || isActive
    }

    private var iconSpring: Animation? {
        reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.64)
    }

    var body: some View {
        ZStack {
            iconLayers
        }
        .frame(width: size, height: size)
        .rotation3DEffect(
            .degrees(reduceMotion || Mono.snapshotMode ? 0 : tiltX * 15),
            axis: (x: 0, y: 1, z: 0),
            perspective: 0.45
        )
        .rotation3DEffect(
            .degrees(reduceMotion || Mono.snapshotMode ? 0 : (engaged ? -4 : 0) - 5 * abs(tiltX)),
            axis: (x: 1, y: 0, z: 0),
            perspective: 0.45
        )
        .scaleEffect(interactive && localHover && !reduceMotion && !Mono.snapshotMode ? 1.07 : 1.0)
        .shadow(
            color: shadowTint.opacity(scheme == .light ? 0.18 : 0.42),
            radius: size * (engaged ? 0.12 : 0.08),
            y: size * (engaged ? 0.07 : 0.045)
        )
        .animation(iconSpring, value: engaged)
        .animation(iconSpring, value: localHover)
        .onHover { inside in
            guard interactive, size >= 20, !Mono.snapshotMode else { return }
            localHover = inside
        }
        .accessibilityHidden(true)
    }

    private var shadowTint: Color {
        switch name {
        case .trash, .mac, .smartcare: return Color(hex: 0x2F7BFF)
        case .notch: return Color(hex: 0x7B4DFF)
        case .dev, .performance: return Color(hex: 0xFF5236)
        case .disk, .diskmap: return Color(hex: 0xFF5C93)
        case .vault, .memory: return Color(hex: 0x1FB26E)
        case .cpu: return Color(hex: 0x6366F1)
        case .gpu: return Color(hex: 0x38BDF8)
        case .apps: return Color(hex: 0x8B5CF6)
        case .settings: return Color(hex: 0x64748B)
        }
    }

    @ViewBuilder
    private var iconLayers: some View {
        switch name {
        case .trash:
            glassFilesFolderIcon
        case .notch:
            glassMusicNotchIcon
        case .dev:
            glassDevMessagesIcon
        case .disk, .diskmap:
            glassDiskPhotosIcon
        case .vault:
            glassVaultCalendarLockIcon
        case .mac, .smartcare:
            glassMacSmartCareIcon
        case .cpu:
            glassCPUIcon
        case .memory:
            glassMemoryIcon
        case .gpu:
            glassGPUIcon
        case .performance:
            glassPerformanceIcon
        case .apps:
            glassAppsIcon
        case .settings:
            glassSettingsIcon
        }
    }

    // MARK: - Shared Frosted Glass Pane Chrome (Exact Glass Dock Material)

    private func glassPane(
        cornerRadius: CGFloat,
        topTint: Color,
        midTint: Color,
        bottomTint: Color = Color.white.opacity(0.68)
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return ZStack {
            if !Mono.snapshotMode && size >= 24 {
                shape.fill(.ultraThinMaterial)
                    .opacity(scheme == .dark ? 0.55 : 0.72)
            }
            shape.fill(
                LinearGradient(
                    stops: [
                        .init(color: topTint, location: 0.0),
                        .init(color: midTint, location: 0.55),
                        .init(color: bottomTint, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            // Crisp glass hairline + top inner specular highlight
            shape.strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(0.88), Color.white.opacity(0.42), Color.white.opacity(0.62)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: max(0.75, 1.15 * u)
            )
        }
    }

    // MARK: - 1. Trash / Files (Glass Dock Files: blue folder + lifting sheets + tipping glass front)

    private var glassFilesFolderIcon: some View {
        let o: CGFloat = engaged ? 1.0 : 0.0
        return ZStack(alignment: .topLeading) {
            // Folder tab
            UnevenRoundedRectangle(
                topLeadingRadius: 10 * u,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 12 * u,
                style: .continuous
            )
            .fill(Color(hex: 0x4A95FF))
            .frame(width: 40 * u, height: 20 * u)
            .offset(x: 10 * u, y: 12 * u)

            // Solid blue folder back
            RoundedRectangle(cornerRadius: 14 * u, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x5AA2FF), Color(hex: 0x2F7BFF)], startPoint: .top, endPoint: .bottom))
                .frame(width: 84 * u, height: 66 * u)
                .offset(x: 10 * u, y: 18 * u)

            // Sheet 1 (pure white with 2 lines) — lifts & rotates -10°
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8 * u, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: Color(hex: 0x1E3C8C).opacity(0.22), radius: 3 * u, y: 2 * u)
                Capsule()
                    .fill(Color(hex: 0xCDD8EE))
                    .frame(width: 30 * u, height: 4 * u)
                    .offset(x: 10 * u, y: 12 * u)
                Capsule()
                    .fill(Color(hex: 0xCDD8EE))
                    .frame(width: 22 * u, height: 4 * u)
                    .offset(x: 10 * u, y: 22 * u)
            }
            .frame(width: 56 * u, height: 52 * u)
            .rotationEffect(.degrees(-10 * o))
            .offset(x: (22 - 6 * o) * u, y: (22 - 18 * o) * u)

            // Sheet 2 (warm cream with 1 line) — lifts higher & rotates +9°
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8 * u, style: .continuous)
                    .fill(Color(hex: 0xFFF8EF))
                    .shadow(color: Color(hex: 0x1E3C8C).opacity(0.22), radius: 3 * u, y: 2 * u)
                Capsule()
                    .fill(Color(hex: 0xF1D7BF))
                    .frame(width: 26 * u, height: 4 * u)
                    .offset(x: 10 * u, y: 12 * u)
            }
            .frame(width: 52 * u, height: 50 * u)
            .rotationEffect(.degrees(9 * o))
            .offset(x: (30 + 6 * o) * u, y: (24 - 24 * o) * u)

            // Frosted blue glass front pane — tips forward about its bottom edge!
            glassPane(
                cornerRadius: 14 * u,
                topTint: Color(red: 150/255, green: 180/255, blue: 1.0, opacity: 0.56),
                midTint: Color(red: 120/255, green: 150/255, blue: 1.0, opacity: 0.36),
                bottomTint: Color.white.opacity(0.70)
            )
            .frame(width: 92 * u, height: 58 * u)
            .rotation3DEffect(
                .degrees(reduceMotion ? 0 : 30 * o),
                axis: (x: 1, y: 0, z: 0),
                anchor: .bottom,
                perspective: 0.5
            )
            .offset(x: 6 * u, y: (36 + 2 * o) * u)
        }
        .frame(width: size, height: size, alignment: .topLeading)
    }

    // MARK: - 2. Notch / Music (Glass Dock Music: violet grooved vinyl + frosted sleeve + dancing EQ)

    private var glassMusicNotchIcon: some View {
        let p: CGFloat = engaged ? 1.0 : 0.0
        return TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !engaged || reduceMotion || Mono.snapshotMode)) { timeline in
            let t = engaged && !reduceMotion && !Mono.snapshotMode ? timeline.date.timeIntervalSinceReferenceDate : 0
            ZStack(alignment: .topLeading) {
                // Violet grooved vinyl disc
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color(hex: 0x7B4DFF), Color(hex: 0x6A3CF0), Color(hex: 0x7B4DFF), Color(hex: 0x5B2CE0)],
                                center: .center,
                                startRadius: 4 * u,
                                endRadius: 35 * u
                            )
                        )
                    ForEach([0.48, 0.66, 0.84], id: \.self) { ring in
                        Circle()
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: max(0.5, 1.0 * u))
                            .frame(width: 70 * u * ring, height: 70 * u * ring)
                    }
                    Circle()
                        .strokeBorder(Color.white.opacity(0.32), lineWidth: max(0.6, 1.1 * u))
                    // Lavender center label + notch dot highlight (makes rotation visibly silky!)
                    Circle()
                        .fill(Color(hex: 0xC9B6FF))
                        .frame(width: 20 * u, height: 20 * u)
                        .overlay(alignment: .top) {
                            Circle()
                                .fill(Color.white.opacity(0.85))
                                .frame(width: 3.5 * u, height: 3.5 * u)
                                .offset(y: 2.5 * u)
                        }
                    Circle()
                        .fill(Color(hex: 0xF7F8FB))
                        .frame(width: 6 * u, height: 6 * u)
                }
                .frame(width: 70 * u, height: 70 * u)
                .rotationEffect(.degrees(engaged ? (t.truncatingRemainder(dividingBy: 360) * 95) : 0))
                .offset(x: (28 + 11 * p) * u, y: 16 * u)

                // Frosted violet-tinted glass sleeve with 4 dancing equalizer bars
                ZStack(alignment: .bottomLeading) {
                    glassPane(
                        cornerRadius: 16 * u,
                        topTint: Color(red: 200/255, green: 185/255, blue: 1.0, opacity: 0.56),
                        midTint: Color(red: 170/255, green: 150/255, blue: 1.0, opacity: 0.36),
                        bottomTint: Color.white.opacity(0.72)
                    )

                    // Top notch pill emblem inside sleeve
                    Capsule()
                        .fill(Color(hex: 0x161822).opacity(0.82))
                        .frame(width: 28 * u, height: 7 * u)
                        .overlay(
                            HStack(spacing: 4 * u) {
                                Circle().fill(Color(hex: 0x38BDF8)).frame(width: 3 * u, height: 3 * u)
                                Circle().fill(Color(hex: 0x6EE7B7)).frame(width: 3 * u, height: 3 * u)
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 9 * u)

                    // 4 dancing equalizer bars
                    HStack(alignment: .bottom, spacing: 6 * u) {
                        ForEach(0..<4, id: \.self) { k in
                            let h: CGFloat = engaged
                                ? (6 + 10 + 11 * CGFloat(abs(sin(t * (6.8 + Double(k) * 1.7) + Double(k)))))
                                : [9, 17, 13, 20][k]
                            Capsule()
                                .fill(Color.white.opacity(0.45 + 0.55 * p))
                                .frame(width: 6 * u, height: max(4 * u, h * u))
                        }
                    }
                    .padding(.leading, 14 * u)
                    .padding(.bottom, 14 * u)
                }
                .frame(width: 72 * u, height: 76 * u)
                .rotationEffect(.degrees(-6 * p))
                .offset(x: (6 - 10 * p) * u, y: 14 * u)
            }
            .frame(width: size, height: size, alignment: .topLeading)
        }
    }

    // MARK: - 3. Dev / Agents (Glass Dock Messages: coral bubble behind frosted bubble + typing dots + flying spark)

    private var glassDevMessagesIcon: some View {
        let k: CGFloat = engaged ? 1.0 : 0.0
        return TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !engaged || reduceMotion || Mono.snapshotMode)) { timeline in
            let t = engaged && !reduceMotion && !Mono.snapshotMode ? timeline.date.timeIntervalSinceReferenceDate : 0
            ZStack(alignment: .topLeading) {
                // Solid coral back speech/terminal bubble
                GlassSpeechBubbleShape(tailRight: true)
                    .fill(LinearGradient(colors: [Color(hex: 0xFF9A7C), Color(hex: 0xFF5236)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 62 * u, height: 52 * u)
                    .offset(x: (36 + 4 * k) * u, y: (8 - 5 * k) * u)

                // Flying mini coral spark bubble on engage
                GlassSpeechBubbleShape(tailRight: true)
                    .fill(LinearGradient(colors: [Color(hex: 0xFF9A7C), Color(hex: 0xFF5236)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 24 * u, height: 20 * u)
                    .scaleEffect(0.65 + 0.35 * k)
                    .opacity(Double(k) * 0.85)
                    .offset(x: (52 + 10 * k) * u, y: (10 - 14 * k) * u)

                // Frosted coral-tinted glass front bubble
                ZStack {
                    if !Mono.snapshotMode && size >= 24 {
                        GlassSpeechBubbleShape(tailRight: false)
                            .fill(.ultraThinMaterial)
                            .opacity(scheme == .dark ? 0.52 : 0.72)
                    }
                    GlassSpeechBubbleShape(tailRight: false)
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: Color(red: 1.0, green: 206/255, blue: 192/255, opacity: 0.54), location: 0),
                                    .init(color: Color(red: 1.0, green: 176/255, blue: 156/255, opacity: 0.32), location: 0.55),
                                    .init(color: Color.white.opacity(0.74), location: 1.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    GlassSpeechBubbleShape(tailRight: false)
                        .stroke(Color.white.opacity(0.90), lineWidth: max(0.8, 1.2 * u))

                    // 3 typing / AI agent dots that bounce rhythmically!
                    HStack(spacing: 7 * u) {
                        ForEach(0..<3, id: \.self) { idx in
                            let bounce: CGFloat = engaged
                                ? -4.5 * CGFloat(max(0, sin(t * 9.5 - Double(idx) * 1.1)))
                                : 0
                            Circle()
                                .fill(Color.white)
                                .frame(width: 8 * u, height: 8 * u)
                                .offset(y: bounce * u)
                        }
                    }
                    .offset(y: -4 * u)
                }
                .frame(width: 78 * u, height: 66 * u)
                .scaleEffect(1 + 0.03 * k)
                .offset(x: 4 * u, y: (28 - 3 * k) * u)
            }
            .frame(width: size, height: size, alignment: .topLeading)
        }
    }

    // MARK: - 4. Disk / DiskMap (Glass Dock Photos: sun & pink circles behind frosted glass mountain/chart)

    private var glassDiskPhotosIcon: some View {
        let k: CGFloat = engaged ? 1.0 : 0.0
        return ZStack(alignment: .topLeading) {
            // Warm sun circle
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0xFFD36B), Color(hex: 0xFFAB1F)], center: UnitPoint(x: 0.4, y: 0.35), startRadius: 2 * u, endRadius: 26 * u))
                .frame(width: 46 * u, height: 46 * u)
                .offset(x: (46 + 5 * k) * u, y: (10 - 5 * k) * u)

            // Vibrant rose-pink circle
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0xFF9EC2), Color(hex: 0xFF5C93)], center: UnitPoint(x: 0.4, y: 0.35), startRadius: 2 * u, endRadius: 24 * u))
                .frame(width: 40 * u, height: 40 * u)
                .offset(x: (20 - 5 * k) * u, y: (28 - 4 * k) * u)

            // Frosted warm glass print pane with white storage mountain/ridge
            ZStack(alignment: .bottom) {
                glassPane(
                    cornerRadius: 16 * u,
                    topTint: Color(red: 1.0, green: 236/255, blue: 200/255, opacity: 0.48),
                    midTint: Color(red: 1.0, green: 220/255, blue: 190/255, opacity: 0.30),
                    bottomTint: Color.white.opacity(0.74)
                )

                GlassMountainShape()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: 52 * u, height: 29 * u)
                    .scaleEffect(x: 1, y: 1 + 0.08 * k, anchor: .bottom)
                    .padding(.bottom, 12 * u)
            }
            .frame(width: 86 * u, height: 62 * u)
            .offset(x: 9 * u, y: (30 + 2 * k) * u)
        }
        .frame(width: size, height: size, alignment: .topLeading)
    }

    // MARK: - 5. Vault (Glass Dock Emerald Green: lifting shackle behind frosted padlock body)

    private var glassVaultCalendarLockIcon: some View {
        let k: CGFloat = engaged ? 1.0 : 0.0
        return ZStack(alignment: .topLeading) {
            // Emerald-mint shackle arch — lifts & tilts open on hover/unlock!
            RoundedRectangle(cornerRadius: 22 * u, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [Color(hex: 0x43D38F), Color(hex: 0x1FB26E)], startPoint: .top, endPoint: .bottom),
                    lineWidth: max(2.2, 10 * u)
                )
                .frame(width: 46 * u, height: 48 * u)
                .rotationEffect(.degrees(-14 * k), anchor: .bottomLeading)
                .offset(x: 29 * u, y: (10 - 7 * k) * u)

            // Solid emerald anchor bar behind top of lock
            RoundedRectangle(cornerRadius: 14 * u, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x43D38F), Color(hex: 0x1FB26E)], startPoint: .top, endPoint: .bottom))
                .frame(width: 74 * u, height: 36 * u)
                .offset(x: 15 * u, y: 30 * u)

            // Frosted mint-tinted glass lock body
            ZStack {
                glassPane(
                    cornerRadius: 18 * u,
                    topTint: Color(red: 190/255, green: 245/255, blue: 215/255, opacity: 0.54),
                    midTint: Color(red: 160/255, green: 235/255, blue: 195/255, opacity: 0.34),
                    bottomTint: Color.white.opacity(0.76)
                )

                // Crisp keyhole emblem
                VStack(spacing: 1.5 * u) {
                    Circle()
                        .fill(Color.white.opacity(0.95))
                        .frame(width: 14 * u, height: 14 * u)
                    Capsule()
                        .fill(Color.white.opacity(0.95))
                        .frame(width: 6.5 * u, height: 14 * u)
                }
                .shadow(color: Color(hex: 0x1A9A5E).opacity(0.35), radius: 3 * u, y: 1.5 * u)
                .scaleEffect(1 + 0.08 * k)
            }
            .frame(width: 84 * u, height: 60 * u)
            .offset(x: 10 * u, y: 34 * u)
        }
        .frame(width: size, height: size, alignment: .topLeading)
    }

    // MARK: - 6. Mac / SmartCare (Vibrant indigo-sky core + frosted glass display + breathing sparkle)

    private var glassMacSmartCareIcon: some View {
        let k: CGFloat = engaged ? 1.0 : 0.0
        return ZStack(alignment: .topLeading) {
            // Solid indigo-blue display core
            RoundedRectangle(cornerRadius: 16 * u, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x60A5FA), Color(hex: 0x4F46E5)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 74 * u, height: 54 * u)
                .offset(x: 15 * u, y: (12 - 3 * k) * u)

            // Emerald health orb glowing behind corner
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0x6EE7B7), Color(hex: 0x10B981)], center: .center, startRadius: 1 * u, endRadius: 16 * u))
                .frame(width: 28 * u, height: 28 * u)
                .offset(x: (66 + 4 * k) * u, y: (8 - 3 * k) * u)

            // Frosted glass screen pane
            ZStack {
                glassPane(
                    cornerRadius: 16 * u,
                    topTint: Color(red: 175/255, green: 205/255, blue: 1.0, opacity: 0.54),
                    midTint: Color(red: 140/255, green: 175/255, blue: 1.0, opacity: 0.34),
                    bottomTint: Color.white.opacity(0.72)
                )
                Image(systemName: "sparkle")
                    .font(.system(size: max(8, 28 * u), weight: .bold))
                    .foregroundStyle(.white.opacity(0.95))
                    .rotationEffect(.degrees(22 * k))
                    .scaleEffect(1 + 0.14 * k)
                    .shadow(color: Color(hex: 0x3B82F6).opacity(0.4), radius: 4 * u)
            }
            .frame(width: 86 * u, height: 62 * u)
            .offset(x: 9 * u, y: 24 * u)

            // Mac sleek glass base bar
            Capsule()
                .fill(LinearGradient(colors: [Color.white.opacity(0.92), Color(hex: 0x94A3B8)], startPoint: .leading, endPoint: .trailing))
                .frame(width: 56 * u, height: 7 * u)
                .offset(x: 24 * u, y: 89 * u)
        }
        .frame(width: size, height: size, alignment: .topLeading)
    }

    // MARK: - 7. CPU (Violet-indigo processor die behind frosted glass wafer)

    private var glassCPUIcon: some View {
        let k: CGFloat = engaged ? 1.0 : 0.0
        return ZStack {
            // Edge pins
            HStack(spacing: 12 * u) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule().fill(Color(hex: 0x818CF8)).frame(width: 6 * u, height: 86 * u)
                }
            }
            VStack(spacing: 12 * u) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule().fill(Color(hex: 0x818CF8)).frame(width: 86 * u, height: 6 * u)
                }
            }

            // Solid indigo silicon core
            RoundedRectangle(cornerRadius: 16 * u, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x818CF8), Color(hex: 0x4F46E5)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 58 * u, height: 58 * u)
                .rotationEffect(.degrees(6 * k))

            // Frosted glass chip lid
            ZStack {
                glassPane(
                    cornerRadius: 18 * u,
                    topTint: Color(red: 195/255, green: 200/255, blue: 1.0, opacity: 0.56),
                    midTint: Color(red: 155/255, green: 165/255, blue: 1.0, opacity: 0.34),
                    bottomTint: Color.white.opacity(0.72)
                )
                RoundedRectangle(cornerRadius: 8 * u, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.92), lineWidth: max(1, 3.2 * u))
                    .frame(width: 28 * u, height: 28 * u)
                    .scaleEffect(1 + 0.12 * k)
            }
            .frame(width: 72 * u, height: 72 * u)
        }
        .frame(width: size, height: size)
    }

    // MARK: - 8. Memory RAM (Mint-emerald chip banks behind frosted glass DIMM pane)

    private var glassMemoryIcon: some View {
        let k: CGFloat = engaged ? 1.0 : 0.0
        return ZStack(alignment: .topLeading) {
            // Solid emerald-teal PCB back
            RoundedRectangle(cornerRadius: 14 * u, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x34D399), Color(hex: 0x059669)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 82 * u, height: 48 * u)
                .offset(x: 11 * u, y: (16 - 4 * k) * u)

            // Frosted mint glass memory front with 4 glowing modules
            ZStack {
                glassPane(
                    cornerRadius: 16 * u,
                    topTint: Color(red: 175/255, green: 245/255, blue: 220/255, opacity: 0.54),
                    midTint: Color(red: 120/255, green: 225/255, blue: 195/255, opacity: 0.32),
                    bottomTint: Color.white.opacity(0.72)
                )

                HStack(alignment: .bottom, spacing: 6 * u) {
                    ForEach(0..<4, id: \.self) { i in
                        let baseH: CGFloat = [18, 26, 22, 30][i]
                        RoundedRectangle(cornerRadius: 3.5 * u, style: .continuous)
                            .fill(Color.white.opacity(0.92))
                            .frame(width: 11 * u, height: (baseH + (i.isMultiple(of: 2) ? 6 : -3) * k) * u)
                    }
                }
            }
            .frame(width: 86 * u, height: 58 * u)
            .offset(x: 9 * u, y: 30 * u)
        }
        .frame(width: size, height: size, alignment: .topLeading)
    }

    // MARK: - 9. GPU (Cyan-violet twin orbs behind frosted prism lens)

    private var glassGPUIcon: some View {
        let k: CGFloat = engaged ? 1.0 : 0.0
        return ZStack(alignment: .topLeading) {
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0x38BDF8), Color(hex: 0x0284C7)], center: .center, startRadius: 2 * u, endRadius: 28 * u))
                .frame(width: 50 * u, height: 50 * u)
                .offset(x: (12 - 4 * k) * u, y: (12 - 3 * k) * u)

            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0xA78BFA), Color(hex: 0x6366F1)], center: .center, startRadius: 2 * u, endRadius: 24 * u))
                .frame(width: 44 * u, height: 44 * u)
                .offset(x: (48 + 4 * k) * u, y: (16 + 3 * k) * u)

            ZStack {
                glassPane(
                    cornerRadius: 18 * u,
                    topTint: Color(red: 180/255, green: 230/255, blue: 1.0, opacity: 0.54),
                    midTint: Color(red: 150/255, green: 205/255, blue: 1.0, opacity: 0.32),
                    bottomTint: Color.white.opacity(0.74)
                )
                Image(systemName: "bolt.fill")
                    .font(.system(size: max(8, 28 * u), weight: .bold))
                    .foregroundStyle(.white.opacity(0.95))
                    .scaleEffect(1 + 0.12 * k)
                    .offset(y: -2 * k * u)
            }
            .frame(width: 82 * u, height: 64 * u)
            .offset(x: 11 * u, y: 26 * u)
        }
        .frame(width: size, height: size, alignment: .topLeading)
    }

    // MARK: - 10. Performance (Coral-amber boost core behind frosted glass gauge)

    private var glassPerformanceIcon: some View {
        let k: CGFloat = engaged ? 1.0 : 0.0
        return ZStack(alignment: .topLeading) {
            Circle()
                .fill(LinearGradient(colors: [Color(hex: 0xFFB067), Color(hex: 0xFF5236)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 64 * u, height: 64 * u)
                .offset(x: 20 * u, y: (10 - 4 * k) * u)

            ZStack {
                glassPane(
                    cornerRadius: 20 * u,
                    topTint: Color(red: 1.0, green: 215/255, blue: 185/255, opacity: 0.54),
                    midTint: Color(red: 1.0, green: 180/255, blue: 150/255, opacity: 0.34),
                    bottomTint: Color.white.opacity(0.74)
                )
                Image(systemName: "gauge.with.needle.fill")
                    .font(.system(size: max(8, 32 * u), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.96))
                    .rotationEffect(.degrees(12 * k))
                    .scaleEffect(1 + 0.1 * k)
            }
            .frame(width: 84 * u, height: 66 * u)
            .offset(x: 10 * u, y: 26 * u)
        }
        .frame(width: size, height: size, alignment: .topLeading)
    }

    // MARK: - 11. Apps (Jewel 2×2 backplates behind frosted glass grid that fans open)

    private var glassAppsIcon: some View {
        let k: CGFloat = engaged ? 1.0 : 0.0
        return ZStack {
            // 4 colorful back tiles that subtly fan outward on hover
            VStack(spacing: (6 + 5 * k) * u) {
                HStack(spacing: (6 + 5 * k) * u) {
                    RoundedRectangle(cornerRadius: 9 * u, style: .continuous)
                        .fill(LinearGradient(colors: [Color(hex: 0x5AA2FF), Color(hex: 0x2F7BFF)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 30 * u, height: 30 * u)
                    RoundedRectangle(cornerRadius: 9 * u, style: .continuous)
                        .fill(LinearGradient(colors: [Color(hex: 0xFF9A7C), Color(hex: 0xFF5236)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 30 * u, height: 30 * u)
                }
                HStack(spacing: (6 + 5 * k) * u) {
                    RoundedRectangle(cornerRadius: 9 * u, style: .continuous)
                        .fill(LinearGradient(colors: [Color(hex: 0x8B5CF6), Color(hex: 0x6A3CF0)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 30 * u, height: 30 * u)
                    RoundedRectangle(cornerRadius: 9 * u, style: .continuous)
                        .fill(LinearGradient(colors: [Color(hex: 0x43D38F), Color(hex: 0x1FB26E)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 30 * u, height: 30 * u)
                }
            }
            .offset(y: -4 * u)

            // Frosted glass front overlay
            ZStack {
                glassPane(
                    cornerRadius: 18 * u,
                    topTint: Color.white.opacity(0.44),
                    midTint: Color(red: 215/255, green: 225/255, blue: 1.0, opacity: 0.28),
                    bottomTint: Color.white.opacity(0.72)
                )
                VStack(spacing: 6 * u) {
                    HStack(spacing: 6 * u) {
                        RoundedRectangle(cornerRadius: 4 * u).fill(.white.opacity(0.92)).frame(width: 15 * u, height: 15 * u)
                        RoundedRectangle(cornerRadius: 4 * u).fill(.white.opacity(0.78)).frame(width: 15 * u, height: 15 * u)
                    }
                    HStack(spacing: 6 * u) {
                        RoundedRectangle(cornerRadius: 4 * u).fill(.white.opacity(0.78)).frame(width: 15 * u, height: 15 * u)
                        RoundedRectangle(cornerRadius: 4 * u).fill(.white.opacity(0.92)).frame(width: 15 * u, height: 15 * u)
                    }
                }
                .scaleEffect(1 + 0.08 * k)
            }
            .frame(width: 78 * u, height: 64 * u)
            .offset(y: 10 * u)
        }
        .frame(width: size, height: size)
    }

    // MARK: - 12. Settings (Slate-sky dial behind frosted glass pane; gear rotates +45° on hover)

    private var glassSettingsIcon: some View {
        let k: CGFloat = engaged ? 1.0 : 0.0
        return ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color(hex: 0x94A3B8), Color(hex: 0x475569)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 68 * u, height: 68 * u)
                .offset(x: 6 * u, y: -6 * u)

            ZStack {
                glassPane(
                    cornerRadius: 20 * u,
                    topTint: Color(red: 215/255, green: 228/255, blue: 245/255, opacity: 0.54),
                    midTint: Color(red: 185/255, green: 202/255, blue: 225/255, opacity: 0.34),
                    bottomTint: Color.white.opacity(0.74)
                )
                Image(systemName: "gearshape.fill")
                    .font(.system(size: max(9, 36 * u), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .rotationEffect(.degrees(45 * k))
            }
            .frame(width: 78 * u, height: 72 * u)
            .offset(y: 6 * u)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Custom Vector Shapes from Glass Dock

private struct GlassSpeechBubbleShape: Shape {
    let tailRight: Bool

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let bodyH = h * 0.84
        let r = min(w, bodyH) * 0.28

        var p = Path()
        p.addRoundedRect(in: CGRect(x: 0, y: 0, width: w, height: bodyH), cornerSize: CGSize(width: r, height: r))
        if tailRight {
            p.move(to: CGPoint(x: w * 0.64, y: bodyH - 1))
            p.addLine(to: CGPoint(x: w * 0.82, y: h))
            p.addLine(to: CGPoint(x: w * 0.78, y: bodyH - 1))
        } else {
            p.move(to: CGPoint(x: w * 0.36, y: bodyH - 1))
            p.addLine(to: CGPoint(x: w * 0.18, y: h))
            p.addLine(to: CGPoint(x: w * 0.24, y: bodyH - 1))
        }
        p.closeSubpath()
        return p
    }
}

private struct GlassMountainShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 50.0
        let sy = rect.height / 28.0
        var p = Path()
        p.move(to: CGPoint(x: 2 * sx, y: 26 * sy))
        p.addLine(to: CGPoint(x: 17 * sx, y: 10 * sy))
        p.addLine(to: CGPoint(x: 27 * sx, y: 20 * sy))
        p.addLine(to: CGPoint(x: 34 * sx, y: 13 * sy))
        p.addLine(to: CGPoint(x: 48 * sx, y: 26 * sy))
        p.closeSubpath()
        return p
    }
}

// MARK: - Glass Dock Magnification & Hover Micro-Interaction Physics (Adapted from render.ts)

enum GlassDockPhysics {
    /// Gaussian magnification scale (adapted from Glass Dock's `1 + MAGNIFY * exp(-((c - px)/FALLOFF)^2)`).
    static func magnification(distance: CGFloat, maxBoost: CGFloat = 0.34, falloff: CGFloat = 68) -> CGFloat {
        1.0 + maxBoost * exp(-pow(distance / falloff, 2))
    }

    /// Normalized 3D tilt angle factor (-1...1) pointing toward the cursor.
    static func tiltFactor(delta: CGFloat, range: CGFloat = 54) -> Double {
        let clamped = min(1, max(-1, delta / range))
        return Double(clamped) * Double(exp(-pow(delta / (range * 1.8), 2)))
    }
}

/// Floating Frosted Label Pill (`tip` in Glass Dock) that rises cleanly above a hovered dock item.
struct GlassDockTooltipPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.95))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color(hex: 0x161822).opacity(0.84))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            .allowsHitTesting(false)
    }
}
