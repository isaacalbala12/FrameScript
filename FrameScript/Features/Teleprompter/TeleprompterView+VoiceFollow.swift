import SwiftUI

// MARK: - Voice controls row

struct TeleprompterVoiceControls: View {
    @Bindable var model: TeleprompterModel

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.toggleVoiceFollow()
                model.showControlsTemporarily()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: model.voiceFollow.isEnabled ? "waveform" : "waveform.slash")
                        .font(.system(size: 12, weight: .semibold))
                    Text(model.localized("voiceFollow.toggle"))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                    Text("V")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.white.opacity(model.voiceFollow.isEnabled ? 0.16 : 0.10))
                        }
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background {
                    Capsule().fill(
                        model.voiceFollow.isEnabled
                            ? Color.white.opacity(0.92)
                            : Color.white.opacity(0.10)
                    )
                }
                .foregroundStyle(
                    model.voiceFollow.isEnabled
                        ? Color.black
                        : Color.white.opacity(0.88)
                )
            }
            .buttonStyle(.plain)
            .help(model.localized("voiceFollow.toggleHelp"))
            .accessibilityLabel(model.localized("voiceFollow.toggle"))

            if model.voiceFollow.isEnabled {
                microphoneMenu
                Text(model.localized(model.voiceFollow.statusKey))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.48))
                    .lineLimit(1)
            }

            Spacer(minLength: 12)
        }
        .onAppear {
            model.refreshVoiceInputDevices()
        }
    }

    private var microphoneMenu: some View {
        Menu {
            Button {
                model.selectAudioInput(uid: nil)
            } label: {
                if model.settings.preferredAudioInputUID == nil {
                    Label(model.localized("voiceFollow.systemMicrophone"), systemImage: "checkmark")
                } else {
                    Text(model.localized("voiceFollow.systemMicrophone"))
                }
            }
            if model.voiceFollow.availableInputDevices.isEmpty {
                Divider()
                Text(model.localized("voiceFollow.noMicrophones"))
            } else {
                Divider()
                ForEach(model.voiceFollow.availableInputDevices) { device in
                    Button {
                        model.selectAudioInput(uid: device.uid)
                    } label: {
                        if model.settings.preferredAudioInputUID == device.uid {
                            Label(device.name, systemImage: "checkmark")
                        } else {
                            Text(device.name)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "mic")
                    .font(.system(size: 11, weight: .semibold))
                Text(model.selectedAudioInputName)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.72))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background {
                Capsule().fill(.white.opacity(0.08))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(model.localized("voiceFollow.microphone"))
    }
}

// MARK: - Status indicator

struct VoiceFollowStatusIndicator: View {
    @Bindable var model: TeleprompterModel

    var body: some View {
        if model.voiceFollow.phase != .off {
            HStack(spacing: 5) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 5, height: 5)
                Text(model.localized(model.voiceFollow.statusKey))
                    .lineLimit(1)
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.42))
            .accessibilityElement(children: .combine)
        }
    }

    private var indicatorColor: Color {
        switch model.voiceFollow.phase {
        case .following:
            Color(red: 0.42, green: 0.90, blue: 0.62)
        case .timedFallback:
            Color(red: 1.0, green: 0.76, blue: 0.36)
        case .preparing:
            Color.white.opacity(0.45)
        case .listening, .off:
            Color(red: 0.58, green: 0.80, blue: 1.0)
        }
    }
}

// MARK: - Alerts

private struct VoiceFollowAlertModifier: ViewModifier {
    @Bindable var model: TeleprompterModel

    func body(content: Content) -> some View {
        content.alert(item: $model.voiceFollowAlert) { alert in
            switch alert.kind {
            case .explanation:
                Alert(
                    title: Text(model.localized("voiceFollow.permission.title")),
                    message: Text(model.localized("voiceFollow.permission.message")),
                    primaryButton: .default(Text(model.localized("voiceFollow.activate"))) {
                        model.confirmVoiceFollowPermissions()
                    },
                    secondaryButton: .cancel(Text(model.localized("voiceFollow.cancel")))
                )
            case .denied:
                Alert(
                    title: Text(model.localized("voiceFollow.denied.title")),
                    message: Text(model.localized("voiceFollow.error.permissions")),
                    primaryButton: .default(Text(model.localized("voiceFollow.openSettings"))) {
                        model.openPrivacySettings()
                    },
                    secondaryButton: .cancel(Text(model.localized("voiceFollow.cancel")))
                )
            case .failure(let failure):
                Alert(
                    title: Text(model.localized("voiceFollow.error.title")),
                    message: Text(model.localized(failure.messageKey)),
                    dismissButton: .default(Text(model.localized("voiceFollow.ok")))
                )
            case .noText:
                Alert(
                    title: Text(model.localized("voiceFollow.error.title")),
                    message: Text(model.localized("voiceFollow.error.noText")),
                    dismissButton: .default(Text(model.localized("voiceFollow.ok")))
                )
            }
        }
    }
}

extension View {
    func voiceFollowAlerts(model: TeleprompterModel) -> some View {
        modifier(VoiceFollowAlertModifier(model: model))
    }
}
