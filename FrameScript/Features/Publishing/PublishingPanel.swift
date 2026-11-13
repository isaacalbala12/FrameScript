import FrameScriptCore
import SwiftUI

struct PublishingPanel: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: PublishingTab
    @State private var selectedLanguage: String
    @State private var showsExport = false

    init(initialTab: PublishingTab = .metadata, initialLanguage: String? = nil) {
        _selectedTab = State(initialValue: initialTab)
        _selectedLanguage = State(initialValue: initialLanguage ?? "")
    }

    private var languages: [String] {
        appState.publishingAvailableLanguageCodes
    }

    private var issues: [PublishingValidationIssue] {
        appState.publishingValidationIssues(language: selectedLanguage)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.divider)
            tabBar
            Divider().overlay(theme.divider)
            content
            Divider().overlay(theme.divider)
            footer
        }
        .frame(width: PublishingMetrics.panelWidth, height: PublishingMetrics.panelHeight)
        .background(theme.windowBackground)
        .foregroundStyle(theme.primaryText)
        .accessibilityIdentifier("publishing-panel")
        .onAppear(perform: selectDefaultLanguage)
        .onChange(of: languages) { _, _ in selectDefaultLanguage() }
        .sheet(isPresented: $showsExport) {
            PublishingExportSheet(language: selectedLanguage)
                .environment(appState)
                .environment(\.frameTheme, theme)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "megaphone")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.accent.color)
                .frame(width: 30, height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.accentSoft)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(appState.localized("publishing.title"))
                    .font(.system(size: 18, weight: .semibold))
                Text(appState.project.title)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if languages.count > 1 {
                Picker("", selection: $selectedLanguage) {
                    ForEach(languages, id: \.self) { code in
                        Text(appState.publishingLanguageDisplayName(code)).tag(code)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 190)
                .help(appState.localized("publishing.language"))
                .accessibilityIdentifier("publishing-language-picker")
            }

            Button {
                PublishingPresentation.shared.isPresented = false
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.secondaryText)
            .help(appState.localized("publishing.close"))
            .accessibilityIdentifier("publishing-close")
        }
        .padding(.horizontal, 20)
        .frame(height: PublishingMetrics.headerHeight)
    }

    // MARK: - Tabs

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(PublishingTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 11, weight: .medium))
                        Text(appState.localized(tab.titleKey))
                            .font(.system(size: 12, weight: .medium))
                        if tab == .checklist {
                            let progress = appState.publishingChecklistProgress
                            Text("\(progress.done)/\(progress.total)")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(theme.tertiaryText)
                                .padding(.horizontal, 4)
                                .frame(height: 16)
                                .background {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(theme.hover)
                                }
                        }
                    }
                    .foregroundStyle(selectedTab == tab ? theme.primaryText : theme.secondaryText)
                    .padding(.horizontal, 11)
                    .frame(height: 28)
                    .background {
                        if selectedTab == tab {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(theme.softAccent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("publishing-tab-\(tab.rawValue)")
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: PublishingMetrics.tabBarHeight)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        Group {
            switch selectedTab {
            case .metadata:
                PublishingMetadataTab(language: selectedLanguage)
            case .chapters:
                PublishingChaptersTab(language: selectedLanguage)
            case .thumbnails:
                PublishingThumbnailsTab(language: selectedLanguage)
            case .checklist:
                PublishingChecklistTab(language: selectedLanguage)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id("\(selectedTab.rawValue)-\(selectedLanguage)")
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            validationSummary

            Spacer(minLength: 12)

            Button {
                showsExport = true
            } label: {
                Label(appState.localized("publishing.export"), systemImage: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.accent.color)
            .accessibilityIdentifier("publishing-export")

            Button(appState.localized("publishing.close")) {
                PublishingPresentation.shared.isPresented = false
                dismiss()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(theme.secondaryText)
        }
        .padding(.horizontal, 20)
        .frame(height: PublishingMetrics.footerHeight)
    }

    @ViewBuilder
    private var validationSummary: some View {
        let errors = issues.filter { $0.severity == .error }.count
        let warnings = issues.filter { $0.severity == .warning }.count
        HStack(spacing: 6) {
            Image(systemName: errors > 0 ? "exclamationmark.octagon.fill" : (warnings > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(errors > 0 ? theme.destructive : (warnings > 0 ? theme.warning : theme.success))
            Text(summaryText(errors: errors, warnings: warnings))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(errors > 0 ? theme.destructive : theme.secondaryText)
                .lineLimit(1)
        }
        .accessibilityIdentifier("publishing-validation-summary")
    }

    private func summaryText(errors: Int, warnings: Int) -> String {
        if errors > 0 {
            return String(format: appState.localized("publishing.validation.errors"), errors, warnings)
        }
        if warnings > 0 {
            return String(format: appState.localized("publishing.validation.warnings"), warnings)
        }
        return appState.localized("publishing.validation.ok")
    }

    private func selectDefaultLanguage() {
        guard !languages.isEmpty else { return }
        if selectedLanguage.isEmpty
            || !languages.contains(where: {
                $0.caseInsensitiveCompare(selectedLanguage) == .orderedSame
            }) {
            selectedLanguage = appState.project.primaryLanguage.isEmpty
                ? (languages.first ?? "es")
                : appState.project.primaryLanguage
        }
    }
}
