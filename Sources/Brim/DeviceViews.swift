import SwiftUI

/// Device image, name, status and battery (a checkmark when there's no battery info).
struct DeviceContent: View {
    let event: AudioDeviceEvent

    var body: some View {
        HStack(spacing: 12) {
            DeviceVisual(visual: event.visual)
                .frame(width: 52, height: 46)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(event.status == .lowBattery ? Strings.lowBattery : Strings.connected)
                    .font(.system(size: 11))
                    .foregroundStyle(event.status == .lowBattery ? Color(nsColor: .systemOrange) : .white.opacity(0.55))
            }

            Spacer(minLength: 8)

            if let battery = event.battery {
                HStack(spacing: 6) {
                    BatteryGlyph(level: battery)
                    Text(Strings.percent(battery))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                }
            } else {
                Checkmark()
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 20)
        .padding(.bottom, 6)
    }
}

/// Whether the view already appeared, so the entrance animates once. Built without Xcode, so no @State
/// macro. It must be a DynamicProperty, otherwise SwiftUI never installs the inner State.
private struct Appeared: DynamicProperty {
    let state = State(initialValue: SnapshotRenderer.isActive)
    var value: Bool {
        get { state.wrappedValue }
        nonmutating set { state.wrappedValue = newValue }
    }
}

private struct DeviceVisual: View {
    let visual: AudioDeviceEvent.Visual
    private let appeared = Appeared()

    var body: some View {
        let on = appeared.value
        Group {
            switch visual {
            case .buds(let left, let right):
                // Earbuds slide out from the center with a slight tilt, as if leaving the case.
                ZStack {
                    Image(nsImage: left).resizable().scaledToFit()
                        .frame(height: 40)
                        .offset(x: on ? -11 : 0, y: on ? 0 : -8)
                        .rotationEffect(.degrees(on ? 0 : 12))
                        .scaleEffect(on ? 1 : 0.6)
                        .opacity(on ? 1 : 0)
                        .animation(.spring(duration: 0.64, bounce: 0.25).delay(0.09), value: on)
                    Image(nsImage: right).resizable().scaledToFit()
                        .frame(height: 40)
                        .offset(x: on ? 11 : 0, y: on ? 0 : -8)
                        .rotationEffect(.degrees(on ? 0 : -12))
                        .scaleEffect(on ? 1 : 0.6)
                        .opacity(on ? 1 : 0)
                        .animation(.spring(duration: 0.64, bounce: 0.25).delay(0.14), value: on)
                }
                .shadow(color: .black.opacity(0.4), radius: 3, y: 2)
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
                    .scaleEffect(on ? 1 : 0.5)
                    .blur(radius: on ? 0 : 3)
                    .opacity(on ? 1 : 0)
                    .animation(.spring(duration: 0.56, bounce: 0.25).delay(0.08), value: on)
            }
        }
        .onAppear { appeared.value = true }
    }
}

/// Battery like the status bar one. Fills when it appears.
private struct BatteryGlyph: View {
    let level: Int
    private let appeared = Appeared()

    private var color: Color {
        level <= 10 ? Color(nsColor: .systemRed) : level <= 20 ? Color(nsColor: .systemOrange) : Color(nsColor: .systemGreen)
    }

    var body: some View {
        HStack(spacing: 1.2) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(.white.opacity(0.38), lineWidth: 1.2)
                RoundedRectangle(cornerRadius: 1.6, style: .continuous)
                    .fill(color)
                    .frame(width: 16 * (appeared.value ? CGFloat(level) / 100 : 0), height: 6.8)
                    .padding(.leading, 2.2)
                    .animation(.smooth(duration: 0.8).delay(0.24), value: appeared.value)
            }
            .frame(width: 20.4, height: 11)
            UnevenRoundedRectangle(cornerRadii: .init(bottomTrailing: 1, topTrailing: 1))
                .fill(.white.opacity(0.38))
                .frame(width: 1.6, height: 4)
        }
        .onAppear { appeared.value = true }
    }
}

private struct Checkmark: View {
    private let appeared = Appeared()

    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Color(nsColor: .systemGreen))
            .scaleEffect(appeared.value ? 1 : 0.4)
            .opacity(appeared.value ? 1 : 0)
            .animation(.spring(duration: 0.5, bounce: 0.35).delay(0.26), value: appeared.value)
            .onAppear { appeared.value = true }
    }
}
