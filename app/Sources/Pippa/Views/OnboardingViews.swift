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
