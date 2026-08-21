import Foundation
import Observation
import SwiftUI

/// Sampling parameters sent with every request. Only knobs that BaseRT's HTTP API
/// actually honours are exposed — `repetition_penalty` is a CLI-only flag and has
/// no effect on /v1/chat/completions, so it is deliberately absent.
@Observable
@MainActor
final class ModelSettings {
    var systemPrompt: String { didSet { store(systemPrompt, "systemPrompt") } }
    var temperature: Double { didSet { store(temperature, "temperature") } }
    var topP: Double { didSet { store(topP, "topP") } }
    var topK: Int { didSet { store(topK, "topK") } }
    var maxTokens: Int { didSet { store(maxTokens, "maxTokens") } }
    var frequencyPenalty: Double { didSet { store(frequencyPenalty, "frequencyPenalty") } }

    static let defaults = (systemPrompt: "", temperature: 0.7, topP: 0.9, topK: 40,
                           maxTokens: 4096, frequencyPenalty: 0.0)

    init() {
        let store = UserDefaults.standard
        systemPrompt = store.string(forKey: "systemPrompt") ?? Self.defaults.systemPrompt
        temperature = store.object(forKey: "temperature") as? Double ?? Self.defaults.temperature
        topP = store.object(forKey: "topP") as? Double ?? Self.defaults.topP
        topK = store.object(forKey: "topK") as? Int ?? Self.defaults.topK
        maxTokens = store.object(forKey: "maxTokens") as? Int ?? Self.defaults.maxTokens
        frequencyPenalty = store.object(forKey: "frequencyPenalty") as? Double ?? Self.defaults.frequencyPenalty
    }

    private func store(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    var isDefault: Bool {
        systemPrompt == Self.defaults.systemPrompt && temperature == Self.defaults.temperature
            && topP == Self.defaults.topP && topK == Self.defaults.topK
            && maxTokens == Self.defaults.maxTokens && frequencyPenalty == Self.defaults.frequencyPenalty
    }

    func reset() {
        systemPrompt = Self.defaults.systemPrompt
        temperature = Self.defaults.temperature
        topP = Self.defaults.topP
        topK = Self.defaults.topK
        maxTokens = Self.defaults.maxTokens
        frequencyPenalty = Self.defaults.frequencyPenalty
    }
}

// MARK: - Popover

struct ModelSettingsPopover: View {
    @Environment(ModelSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Model Settings", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
                Button("Reset", action: settings.reset)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .disabled(settings.isDefault)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("System Prompt").font(.subheadline.weight(.medium))
                TextField("Optional — sent before every conversation.",
                          text: $settings.systemPrompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .lineLimit(3...6)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
            }

            Divider()

            slider("Temperature", value: $settings.temperature, range: 0...2, step: 0.05)
            slider("Top-P", value: $settings.topP, range: 0...1, step: 0.01)
            stepper("Top-K", value: $settings.topK, range: 1...200, step: 5)
            slider("Frequency Penalty", value: $settings.frequencyPenalty, range: -2...2, step: 0.1)
            stepper("Max Tokens", value: $settings.maxTokens, range: 256...32768, step: 256)
        }
        .padding(16)
        .frame(width: 330)
    }

    private func slider(_ title: String, value: Binding<Double>,
                        range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            AmberSlider(value: value, range: range, step: step)
        }
    }

    private func stepper(_ title: String, value: Binding<Int>,
                         range: ClosedRange<Int>, step: Int) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text("\(value.wrappedValue)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Slider with an accent-coloured knob — AppKit's own knob cannot be tinted.
struct AmberSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    private let knob: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            let usable = max(geometry.size.width - knob, 1)
            let span = max(range.upperBound - range.lowerBound, .leastNonzeroMagnitude)
            let fraction = min(max((value - range.lowerBound) / span, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 4)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: fraction * usable + knob / 2, height: 4)
                Circle()
                    .fill(Color.accentColor)
                    .overlay(Circle().strokeBorder(.white.opacity(0.55), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .frame(width: knob, height: knob)
                    .offset(x: fraction * usable)
            }
            .frame(height: knob)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    let x = min(max(drag.location.x - knob / 2, 0), usable)
                    let raw = range.lowerBound + (x / usable) * span
                    let snapped = (raw / step).rounded() * step
                    value = min(max(snapped, range.lowerBound), range.upperBound)
                }
            )
        }
        .frame(height: knob)
    }
}
