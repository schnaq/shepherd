import ShepherdCore
import SwiftUI

/// A folder the user picked for "Add a local repository…", and what git said about it.
///
/// Made in one step before any sheet is shown — the open panel, then ``LocalRepositoryProbe`` —
/// so the sheet opens on an answer rather than on a spinner, and a cancelled panel shows nothing
/// at all. Each surface that offers the action holds its own draft: the main window's rail and ⌘K
/// through ``AppEnvironment/localRepositoryDraft``, Settings in its own state, because a sheet
/// belongs to the window the click came from and Settings is a window of its own.
struct LocalRepositoryDraft: Identifiable {
    /// Identity for `.sheet(item:)`.
    let id = UUID()
    /// What the user picked.
    let folder: URL
    /// What git said, or why git could not be asked.
    let finding: Result<LocalRepositoryProbe.Finding, any Error>

    /// Asks for a folder and inspects it.
    /// - Parameter probe: The git seam.
    /// - Returns: The draft, or `nil` when the user cancelled the panel.
    @MainActor
    static func choose(probe: LocalRepositoryProbe = LocalRepositoryProbe()) async -> LocalRepositoryDraft? {
        guard let folder = FolderPicker.choose(
            title: String(localized: "Choose your local clone of a GitHub repository")
        ) else { return nil }
        do {
            return LocalRepositoryDraft(folder: folder, finding: .success(try await probe.inspect(folder)))
        } catch {
            return LocalRepositoryDraft(folder: folder, finding: .failure(error))
        }
    }
}

/// Links a local clone and watches its repository, in one confirmation (ADR 0011's 2026-09-23
/// amendment).
///
/// The one question the user is asked is whether this is right: "schnaq/shepherd — ~/code/shepherd".
/// Both halves are ticked by default because that is what "add my repository" means — agents can
/// start in it, and every pull request in it reaches the inbox — and either can be unticked. A
/// half that is already done is shown ticked and disabled with a sentence saying so, which is what
/// makes adding the same clone twice a harmless no-op (``ShepherdCore/LocalRepositoryLink``).
///
/// When `origin` does not name a github.com repository the sheet says why and asks for the name
/// instead, except for a GitHub Enterprise host: Shepherd only talks to github.com, so there is no
/// name that would make that clone work, and offering a field would suggest there were.
struct AddLocalRepositorySheet: View {
    @Environment(\.dismiss) private var dismiss
    /// The folder and the finding.
    let draft: LocalRepositoryDraft
    /// Where the checkout map and the watch list live.
    let settings: AppSettings
    /// Where the success is announced.
    let toasts: ToastCenter
    /// Picks another folder, after this sheet is gone.
    var onChooseAnother: () -> Void

    @State private var name = ""
    @State private var link = true
    @State private var watch = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Add a local repository"))
                .font(Theme.type(.title3, weight: .semibold))
                .foregroundStyle(Theme.textStrong)
            content
            footer
        }
        .padding(20)
        .frame(width: 480)
        .background(Theme.panel)
        .onAppear {
            if case .success(.repository(_, .github(let repo))) = draft.finding {
                name = repo.fullName
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch draft.finding {
        case .failure(let failure):
            message(String(
                localized: "Shepherd could not run git to look at this folder: \(failure.userFacingDescription)"
            ), isProblem: true)
        case .success(.notAGitRepository):
            message(String(
                localized: "\(draft.folder.path) is not inside a git clone. Choose the folder you cloned the repository into."
            ), isProblem: true)
        case .success(.repository(let root, let remote)):
            repositoryForm(root: root, remote: remote)
        }
    }

    @ViewBuilder
    private func repositoryForm(root: URL, remote: LocalRepositoryProbe.Remote) -> some View {
        if case .enterpriseHost(let host) = remote {
            message(String(
                localized: "origin points at \(host), which looks like GitHub Enterprise. Shepherd only talks to github.com, so it cannot watch this repository or start agents in it."
            ), isProblem: true)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let reason = reason(for: remote) {
                    message(reason, isProblem: false)
                }
                VStack(alignment: .leading, spacing: 4) {
                    TextField(String(localized: "owner/repository or a GitHub URL"), text: $name)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.mono(.callout))
                        .accessibilityLabel(Text(String(localized: "Repository")))
                    Text(verbatim: root.path)
                        .font(Theme.mono(.caption))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(root.path)
                }
                if let repo {
                    toggles(repo: repo, root: root)
                }
                if let error {
                    Text(error)
                        .font(Theme.type(.caption))
                        .foregroundStyle(Theme.failure)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Why the name field is empty, when it is.
    private func reason(for remote: LocalRepositoryProbe.Remote) -> String? {
        switch remote {
        case .github:
            return nil
        case .none:
            return String(
                localized: "This clone has no origin remote, so Shepherd cannot tell which repository it is. Enter it as owner/repository."
            )
        case .otherHost(let host):
            return String(
                localized: "origin points at \(host), not GitHub. If the repository is also on GitHub, enter its name as owner/repository."
            )
        case .unreadable(let url):
            return String(
                localized: "Shepherd could not read a GitHub repository out of origin (\(url)). Enter it as owner/repository."
            )
        case .enterpriseHost:
            return nil
        }
    }

    @ViewBuilder
    private func toggles(repo: RepoRef, root: URL) -> some View {
        let state = settings.localRepositoryLink(repo, folder: root)
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Toggle(
                    String(localized: "Link this folder as the local checkout"),
                    isOn: state.checkout == .linkedHere ? .constant(true) : $link
                )
                .toggleStyle(.checkbox)
                .disabled(state.checkout == .linkedHere)
                caption(checkoutCaption(state.checkout))
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle(
                    String(localized: "Watch the repository"),
                    isOn: state.watch == .notWatched ? $watch : .constant(state.watch == .watched)
                )
                .toggleStyle(.checkbox)
                .disabled(state.watch != .notWatched)
                caption(watchCaption(state.watch))
            }
        }
    }

    private func checkoutCaption(_ checkout: LocalRepositoryLink.Checkout) -> String {
        switch checkout {
        case .unlinked:
            return String(localized: "Agents you start on this repository work in worktrees built from this clone, and “Open in editor” opens its files.")
        case .linkedHere:
            return String(localized: "Already linked.")
        case .linkedElsewhere(let path):
            return String(localized: "Replaces the folder linked now: \(path)")
        }
    }

    private func watchCaption(_ watch: LocalRepositoryLink.Watch) -> String {
        switch watch {
        case .notWatched:
            return String(localized: "Every open pull request in it reaches the inbox, even the ones nobody asked you about.")
        case .watched:
            return String(localized: "Already watched.")
        case .listFull:
            return String(
                localized: "\(AppSettings.maximumWatchedRepositories) is the maximum — each repository is one more search on every sweep."
            )
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if !isRepositoryFound {
                Button(String(localized: "Choose another folder…")) {
                    dismiss()
                    onChooseAnother()
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            Spacer()
            Button(String(localized: "Cancel")) { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            if isRepositoryFound {
                Button(String(localized: "Add")) { add() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
    }

    // MARK: - Behaviour

    /// The folder's root and a repository Shepherd can work with, when there is one.
    private var root: URL? {
        guard case .success(.repository(let root, let remote)) = draft.finding else { return nil }
        if case .enterpriseHost = remote { return nil }
        return root
    }

    /// Whether the form is shown at all.
    private var isRepositoryFound: Bool { root != nil }

    /// The typed or detected repository, validated by the same rule the watch list uses.
    private var repo: RepoRef? { RepoRef.parse(userInput: name) }

    /// Whether pressing Add would change anything.
    private var canAdd: Bool {
        guard let repo, let root else { return false }
        let state = settings.localRepositoryLink(repo, folder: root)
        let linkWanted = link && state.checkout != .linkedHere
        let watchWanted = watch && state.watch == .notWatched
        return linkWanted || watchWanted
    }

    private func add() {
        guard let repo, let root else { return }
        let state = settings.localRepositoryLink(repo, folder: root)
        if let failure = settings.addLocalRepository(
            repo,
            folder: root,
            link: link && state.checkout != .linkedHere,
            watch: watch && state.watch == .notWatched
        ) {
            error = failure
            return
        }
        toasts.success(String(localized: "Added \(repo.fullName)."))
        dismiss()
    }

    // MARK: - Pieces

    private func message(_ text: String, isProblem: Bool) -> some View {
        Text(text)
            .font(Theme.type(.callout))
            .foregroundStyle(isProblem ? Theme.text : Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Theme.type(.caption))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 20)
    }
}
