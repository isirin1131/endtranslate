import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var testing = false
    @State private var testResult: TestResult?

    private enum TestResult {
        case ok(String)
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                TextField("Base URL", text: $settings.baseURL, prompt: Text("https://api.openai.com/v1"))
                SecureField("API Key", text: $settings.apiKey, prompt: Text(settings.isLocalEndpoint ? "本地服务可留空" : "sk-…"))
                TextField("模型", text: $settings.model, prompt: Text("gpt-4o"))
            } header: {
                HStack {
                    Text("翻译服务")
                    Spacer()
                    Menu("预设") {
                        ForEach(AppSettings.presets) { preset in
                            Button(preset.name) {
                                settings.apply(preset)
                                testResult = nil
                            }
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .fixedSize()
                }
            } footer: {
                Text("模型需支持图片输入；API Key 必须与 Base URL 对应的服务商匹配，切换预设后请核对。Key 保存在钥匙串中。")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 10) {
                    Button(testing ? "测试中…" : "测试连接") { test() }
                        .disabled(testing || !settings.isConfigured)
                    if testing {
                        ProgressView().controlSize(.small)
                    }
                    switch testResult {
                    case .ok(let reply)?:
                        Label("连接正常 · \(reply)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .lineLimit(1)
                    case .failed(let message)?:
                        Label(message, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    case nil:
                        EmptyView()
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 340)
        .onChange(of: settings.baseURL) { testResult = nil }
        .onChange(of: settings.apiKey) { testResult = nil }
        .onChange(of: settings.model) { testResult = nil }
    }

    private func test() {
        testing = true
        testResult = nil
        let image = Self.makeTestImage()
        let settings = self.settings
        Task { @MainActor in
            defer { testing = false }
            do {
                let reply = try await LLMClient(settings: settings).chat(
                    system: "You are a connectivity probe. Reply with exactly: OK",
                    user: "Reply with OK.",
                    imagePNG: image
                )
                testResult = .ok(String(reply.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)))
            } catch {
                testResult = .failed(LLMClient.describe(error))
            }
        }
    }

    static func makeTestImage() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 80,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 240, height: 80).fill()
        let text = "The quick brown fox 42"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.black
        ]
        (text as NSString).draw(at: NSPoint(x: 10, y: 40), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
}
