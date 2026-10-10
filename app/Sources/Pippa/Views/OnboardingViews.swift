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
