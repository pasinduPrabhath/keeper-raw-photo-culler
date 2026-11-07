import KeeperCore
import SwiftUI

struct Pill<Content: View>: View {
    var tint: Color = .white
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 5) { content }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.stroke))
    }
}

struct StarsView: View {
    let rating: Int
    var size: CGFloat = 10
    var body: some View {
        HStack(spacing: 1) {
            ForEach(1 ... 5, id: \.self) { i in
                Image(systemName: i <= rating ? "star.fill" : "star")
                    .font(.system(size: size))
                    .foregroundStyle(i <= rating ? Theme.star : Theme.textTertiary)
            }
        }
    }
}

struct FlagBadge: View {
    let flag: Flag
    var size: CGFloat = 20
    var body: some View {
        Group {
            switch flag {
            case .pick: Image(systemName: "checkmark").foregroundStyle(.black).frame(width: size, height: size).background(Theme.pick, in: Circle())
            case .reject: Image(systemName: "xmark").foregroundStyle(.white).frame(width: size, height: size).background(Theme.reject, in: Circle())
            case .none: EmptyView()
            }
        }
        .font(.system(size: size * 0.5, weight: .black))
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
    }
}

/// Sharpness relative to the best frame in the same burst.
struct SharpnessMeter: View {
    let value: Double          // 0…1
    var width: CGFloat = 70
    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.12))
            Capsule().fill(color).frame(width: max(4, width * value))
        }
        .frame(width: width, height: 5)
    }
    private var color: Color { value > 0.85 ? Theme.pick : value > 0.5 ? Theme.star : Theme.reject }
}

struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.stroke))
    }
}

struct ToastView: View {
    let toast: Toast
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.symbol).foregroundStyle(Theme.accent)
            Text(toast.message).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
            if let title = toast.actionTitle, let action = toast.action {
                Button(title, action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.strokeStrong))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.textTertiary)
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(Theme.text).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.system(size: 12))
    }
}

extension CGImage {
    var swiftUIImage: Image { Image(decorative: self, scale: 1) }
}

/// Big stamp shown in the middle of the photo area when a flag changes.
struct FlagFlashView: View {
    let flash: FlagFlash
    @State private var shown = false

    private var color: Color { flash.flag == .pick ? Theme.pick : (flash.flag == .reject ? Theme.reject : Theme.textSecondary) }
    private var symbol: String { flash.flag == .pick ? "checkmark" : (flash.flag == .reject ? "xmark" : "circle.dashed") }
    private var label: String { flash.flag == .pick ? "Picked" : (flash.flag == .reject ? "Rejected" : "Flag cleared") }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 52, weight: .bold)).foregroundStyle(color)
            Text(label).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
        }
        .frame(width: 150, height: 150)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(color.opacity(0.8), lineWidth: 3))
        .shadow(color: color.opacity(0.35), radius: 30)
        .scaleEffect(shown ? 1 : 0.5)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.55)) { shown = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { withAnimation(.easeOut(duration: 0.3)) { shown = false } }
        }
    }
}

/// Buttons that visibly depress when clicked.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .brightness(configuration.isPressed ? -0.12 : 0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
