import PippaCore
import SwiftUI

// MARK: - 13 Willkommen, erstes Laden

struct OnboardingContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        // Pi path (the default): setup without technical questions, the only question is the download.
        if let setup = PiSetupController.shared {
            PiOnboarding(model: model, setup: setup, permissions: model.permissions)
        } else {
            // Give and the scan tools work independently of the local language model.
            ViewThatFits(in: .vertical) {
                WelcomeContent(model: model)
                ScrollView(.vertical) { WelcomeContent(model: model) }.scrollIndicators(.automatic)
            }
        }
    }
}

/// After "Load", once: "What Pippa may do" (PermissionViews.swift), then the setup as before.
private struct PiOnboarding: View {
    @ObservedObject var model: AppModel
    @ObservedObject var setup: PiSetupController
    @ObservedObject var permissions: PermissionsModel

    var body: some View {
        if PermissionsOnboardingPage.shows(permissions, setup) {
            // Scrolls only its list (sized to the panel's room), so "Continue" never scrolls away.
            PermissionsOnboardingPage(permissions: permissions, setup: setup)
        } else {
            ViewThatFits(in: .vertical) {
                PiSetupContent(model: model, setup: setup)
                ScrollView(.vertical) { PiSetupContent(model: model, setup: setup) }.scrollIndicators(.automatic)
            }
        }
    }
}

struct WelcomeContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            MarkSlot(size: 48)
            Text(T("Drop photos or a document on me.", table: "Settings"))
                .font(Fonts.lead)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(T("I can make one PDF from your photos, right here on your Mac.", table: "Settings"))
                .font(Fonts.body)
                .foregroundStyle(Theme.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(T("Choose Files…", table: "Settings")) { model.chooseFolder() }
                    .pippa(.secondary)
                    .keyboardShortcut(.defaultAction)
                Button(T("Get Started", table: "Settings")) { model.collapse() }
                    .pippa(.quiet)
            }
        }
        .padding(24)
        .padding(.top, 12)
        .workflowWidth(Theme.inputWidth)
        .overlay(alignment: .topTrailing) {
            CloseButton { model.collapse() }.padding(12)
        }
    }
}

struct LearningContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                MarkSlot(size: 48).padding(.bottom, 14)
                Text(heading)
                    .font(Fonts.resultL)
                    .foregroundStyle(Theme.ink)
                    .stagger(0)
                if model.needsDownloadConsent {
                    DownloadConsent(model: model).padding(.top, 14)
                } else if model.downloadStalled {
                    Text(AppModel.offlineText).font(Fonts.body).foregroundStyle(Theme.ink2).padding(.top, 12)
                    Button(T("Try Again", table: "Settings")) { model.retryDownloadNow() }.pippa(.secondary).padding(.top, 8)
                } else if let progress = model.progressValue {
                Text(T("%lld%%", table: "Settings", Int((progress * 100).rounded())))
                    .font(.scaled(size: 52, weight: .heavy, design: .rounded).monospacedDigit())
                    .tracking(-1)
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                    .padding(.top, 6)
                ThinProgress(value: progress)
                    .padding(.top, 18)
                    .padding(.bottom, 10)
                HStack {
                    Text(remaining)
                    Spacer()
                    Text(T("Loading", table: "Settings"))
                }
                .font(.scaled(size: 12.5))
                .foregroundStyle(Theme.ink3)
                } else if let status = model.learningText {
                    Text(status).font(Fonts.body).foregroundStyle(Theme.ink2).padding(.top, 12)
                }
                Text(model.capabilityText)
                    .font(Fonts.lead)
                    .foregroundStyle(Theme.ink2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 18)
            }
            .padding(.top, 30)
            .padding(.horizontal, 32)
            .padding(.bottom, 4)
            if let ctx = model.context {
                Well(padding: 12) {
                    HStack(spacing: 12) {
                        FolderArt(width: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(T("%@ is remembered", table: "Settings", ctx.name)).font(.scaled(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                            Text(T("You can pick up here later.", table: "Settings")).font(.scaled(size: 13)).foregroundStyle(Theme.ink2)
                        }
                        Spacer(minLength: 6)
                        Chip(text: T("ready", table: "Settings"), kind: .ok, icon: "checkmark")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .stagger(4)
            }
            ActionBar {
                Button(T("Hide", table: "Settings")) { model.collapse() }.pippa(.quiet)
            }
            TrustSill(left: T("Load once, then everything runs on your Mac", table: "Settings"), leftIcon: "lock", right: .none)
        }
        .workflowWidth(Theme.wideWidth)
    }

    private var heading: String {
        if model.needsDownloadConsent { return T("Pippa’s AI isn’t here yet", table: "Settings") }
        return T("Pippa is loading her AI", table: "Settings")
    }

    private var remaining: String {
        if case .downloading(_, let r) = model.modelStatus, let r, r > 0 {
            return AppModel.remainingText(r).replacingOccurrences(of: "Min.", with: "Minuten")
        }
        return T("Estimating time…", table: "Settings")
    }
}

/// Before the first load: state size and duration, the person decides. Nothing goes to the internet without "Load now".
struct DownloadConsent: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let size = model.downloadSize {
                Text(T("Pippa loads her AI once: %@.", table: "Settings", ModelDownloadSize.gigabytes(size.remaining)))
                    .font(.scaled(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(T("With a fast connection, this takes %@. After that, everything runs on your Mac.", table: "Settings", ModelDownloadSize.durationText(size.remaining)))
                    .font(Fonts.body).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(T("Pippa loads her AI once. After that, everything runs on your Mac.", table: "Settings"))
                    .font(.scaled(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
            }
            Text(model.capabilityText)
                .font(Fonts.body).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(T("Load Now", table: "Settings")) { model.startModelDownload() }.pippa(.primary)
                Button(T("Later", table: "Settings")) { model.collapse() }.pippa(.quiet)
            }.padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.fill))
    }
}

struct UnsupportedContent: View {
    @ObservedObject var model: AppModel
    var reason: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHead(title: "Pippa", meta: reason.isEmpty ? nil : reason)
            VStack(alignment: .leading, spacing: 8) {
                ResultTitle(text: T("Not everything is available yet", table: "Settings"), large: false)
                Lead(text: T("You can still look at an overview of your files.", table: "Settings"))
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            ActionBar {
                Button(T("Quit Pippa", table: "Settings")) { NSApp.terminate(nil) }.pippa(.quiet)
                Button(T("Look at Files…", table: "Settings")) { model.chooseFolder() }.pippa(.secondary)
            }
            TrustSill(right: .none)
        }
        .workflowWidth(Theme.workWidth)
    }
}
