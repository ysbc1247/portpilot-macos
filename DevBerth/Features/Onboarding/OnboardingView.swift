import SwiftUI

enum OnboardingDestination {
    case runtime
    case importProject
    case managedService
    case session
}

struct OnboardingView: View {
    let complete: (OnboardingDestination) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DevBerthSpacing.xLarge) {
                    HStack(alignment: .top, spacing: DevBerthSpacing.large) {
                        principle(
                            symbol: "desktopcomputer.and.macbook",
                            title: "Local by design",
                            detail: "Runtime evidence, project metadata, history, and logs stay on this Mac. DevBerth has no account and uploads nothing."
                        )
                        principle(
                            symbol: "checkmark.shield",
                            title: "Evidence before control",
                            detail: "Discovery is observational. A process is not restartable until its exact service definition is reviewed and validated."
                        )
                        principle(
                            symbol: "key.fill",
                            title: "Secrets stay in Keychain",
                            detail: "Managed-service secrets use macOS Keychain references; secret values are excluded from the local database, logs, and diagnostics."
                        )
                    }

                    GroupBox("What DevBerth can see") {
                        VStack(alignment: .leading, spacing: DevBerthSpacing.medium) {
                            fact(
                                "Same-user processes",
                                "macOS may make command, working-directory, or executable metadata unavailable for system processes and processes owned by other users."
                            )
                            fact(
                                "Observed is not managed",
                                "A discovered listener remains inspection-only unless an explicit owner supports safe control or you create and validate a managed service."
                            )
                            fact(
                                "Destructive actions revalidate",
                                "Before stopping anything, DevBerth rechecks the process fingerprint, listener ownership, and controlling runtime to avoid acting on a reused PID or stale observation."
                            )
                        }
                        .padding(.vertical, DevBerthSpacing.small)
                    }

                    VStack(alignment: .leading, spacing: DevBerthSpacing.medium) {
                        Text("Choose a starting point").font(.title3.bold())
                        HStack(spacing: DevBerthSpacing.medium) {
                            startButton("Review Runtime", symbol: "point.3.connected.trianglepath.dotted", destination: .runtime, prominent: true)
                            startButton("Import Project", symbol: "folder.badge.plus", destination: .importProject)
                            startButton("Create Managed Service", symbol: "play.square.stack", destination: .managedService)
                            startButton("Capture Session", symbol: "camera", destination: .session)
                        }
                    }
                }
                .padding(DevBerthSpacing.xLarge)
            }
        }
        .frame(width: 860, height: 650)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Welcome to DevBerth")
    }

    private var header: some View {
        HStack(spacing: DevBerthSpacing.large) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 64, height: 64)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: DevBerthSpacing.xSmall) {
                Text("Make local development legible").font(.largeTitle.bold())
                Text("DevBerth explains what is listening, why it is running, and which actions are actually safe.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("No account required")
                .font(.caption.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
        }
        .padding(DevBerthSpacing.xLarge)
    }

    private func principle(symbol: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: DevBerthSpacing.small) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DevBerthSpacing.large)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
    }

    private func fact(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: DevBerthSpacing.medium) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func startButton(
        _ title: String,
        symbol: String,
        destination: OnboardingDestination,
        prominent: Bool = false
    ) -> some View {
        let button = Button {
            complete(destination)
        } label: {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)

        if prominent {
            button.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}
