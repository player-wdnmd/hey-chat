import SwiftUI

enum AeroTheme {
    static let sky = Color(red: 94 / 255, green: 200 / 255, blue: 255 / 255)
    static let deepSky = Color(red: 47 / 255, green: 159 / 255, blue: 232 / 255)
    static let aqua = Color(red: 126 / 255, green: 231 / 255, blue: 255 / 255)
    static let leaf = Color(red: 62 / 255, green: 207 / 255, blue: 142 / 255)
    static let deepLeaf = Color(red: 34 / 255, green: 160 / 255, blue: 107 / 255)
    static let mint = Color(red: 154 / 255, green: 240 / 255, blue: 200 / 255)

    static let mainBackground = Color(red: 234 / 255, green: 247 / 255, blue: 255 / 255)
    static let text = Color(red: 22 / 255, green: 50 / 255, blue: 74 / 255)
    static let secondaryText = Color(red: 77 / 255, green: 109 / 255, blue: 130 / 255)
    static let faintText = Color(red: 125 / 255, green: 154 / 255, blue: 171 / 255)
    static let sidebarText = Color(red: 244 / 255, green: 252 / 255, blue: 255 / 255)
    static let accent = Color(red: 31 / 255, green: 159 / 255, blue: 224 / 255)
    static let destructive = Color(red: 180 / 255, green: 35 / 255, blue: 24 / 255)

    static let sidebarGradient = LinearGradient(
        stops: [
            .init(color: Color(red: 31 / 255, green: 134 / 255, blue: 208 / 255).opacity(0.96), location: 0),
            .init(color: Color(red: 42 / 255, green: 159 / 255, blue: 208 / 255).opacity(0.94), location: 0.4),
            .init(color: Color(red: 42 / 255, green: 170 / 255, blue: 120 / 255).opacity(0.95), location: 1),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let glassGradient = LinearGradient(
        colors: [
            Color.white.opacity(0.9),
            Color(red: 201 / 255, green: 242 / 255, blue: 255 / 255).opacity(0.64),
            Color(red: 185 / 255, green: 246 / 255, blue: 216 / 255).opacity(0.54),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let glassHighlight = LinearGradient(
        colors: [Color.white.opacity(0.72), Color.white.opacity(0.2), Color.clear],
        startPoint: .top,
        endPoint: .center
    )

    static let inputGradient = LinearGradient(
        colors: [
            Color.white.opacity(0.88),
            Color(red: 218 / 255, green: 246 / 255, blue: 255 / 255).opacity(0.72),
            Color(red: 214 / 255, green: 250 / 255, blue: 231 / 255).opacity(0.54),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let primaryButtonGradient = LinearGradient(
        colors: [
            Color(red: 127 / 255, green: 216 / 255, blue: 255 / 255),
            Color(red: 53 / 255, green: 176 / 255, blue: 239 / 255),
            Color(red: 47 / 255, green: 191 / 255, blue: 132 / 255),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static let pressedButtonGradient = LinearGradient(
        colors: [
            Color(red: 152 / 255, green: 227 / 255, blue: 255 / 255),
            Color(red: 76 / 255, green: 188 / 255, blue: 244 / 255),
            Color(red: 64 / 255, green: 201 / 255, blue: 146 / 255),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static let disabledButtonGradient = LinearGradient(
        colors: [
            Color(red: 201 / 255, green: 232 / 255, blue: 246 / 255),
            Color(red: 168 / 255, green: 213 / 255, blue: 232 / 255),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static let userBubbleGradient = LinearGradient(
        colors: [
            Color(red: 184 / 255, green: 236 / 255, blue: 255 / 255).opacity(0.86),
            Color(red: 186 / 255, green: 245 / 255, blue: 216 / 255).opacity(0.74),
        ],
        startPoint: .top,
        endPoint: .bottom
    )
}

struct AeroPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(minHeight: 38)
            .background {
                Capsule()
                    .fill(buttonGradient(isPressed: configuration.isPressed))
                    .overlay {
                        Capsule()
                            .fill(AeroTheme.glassHighlight.opacity(isEnabled ? 0.52 : 0.2))
                            .padding(1.5)
                    }
            }
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.64), lineWidth: 1))
            .overlay {
                Capsule()
                    .inset(by: 2)
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
            }
            .shadow(color: AeroTheme.deepSky.opacity(isEnabled ? 0.3 : 0), radius: 10, y: 5)
            .shadow(color: AeroTheme.leaf.opacity(isEnabled ? 0.14 : 0), radius: 7, y: 4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.72)
    }

    private func buttonGradient(isPressed: Bool) -> LinearGradient {
        if !isEnabled {
            return AeroTheme.disabledButtonGradient
        }
        return isPressed ? AeroTheme.pressedButtonGradient : AeroTheme.primaryButtonGradient
    }
}

struct AeroWorkspaceHeader<Accessory: View>: View {
    let eyebrow: String
    let title: String
    let systemImage: String
    private let accessory: Accessory

    init(
        eyebrow: String,
        title: String,
        systemImage: String,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.systemImage = systemImage
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(AeroTheme.primaryButtonGradient)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color.white.opacity(0.8), lineWidth: 1)
                }
                .shadow(color: AeroTheme.deepSky.opacity(0.2), radius: 7, y: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(eyebrow)
                    .font(.system(size: 10.5, weight: .heavy))
                    .foregroundStyle(AeroTheme.deepLeaf)
                Text(title)
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(AeroTheme.text)
            }

            Spacer(minLength: 16)
            accessory
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .aeroGlass(cornerRadius: 20)
    }
}

private struct AeroGlassModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(AeroTheme.glassGradient)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(AeroTheme.glassHighlight.opacity(0.58))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.9), lineWidth: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .inset(by: 2)
                    .stroke(AeroTheme.deepSky.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: AeroTheme.deepSky.opacity(0.18), radius: 18, y: 9)
            .shadow(color: AeroTheme.leaf.opacity(0.1), radius: 12, y: 7)
    }
}

private struct AeroInputSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.thinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(AeroTheme.inputGradient)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(AeroTheme.glassHighlight.opacity(0.46))
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.86), lineWidth: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .inset(by: 1.5)
                    .stroke(AeroTheme.deepSky.opacity(0.16), lineWidth: 1)
            }
    }
}

extension View {
    func aeroGlass(cornerRadius: CGFloat = 22) -> some View {
        modifier(AeroGlassModifier(cornerRadius: cornerRadius))
    }

    func aeroInputSurface(cornerRadius: CGFloat = 12) -> some View {
        modifier(AeroInputSurfaceModifier(cornerRadius: cornerRadius))
    }
}
