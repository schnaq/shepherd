import Foundation

/// Renders the task text a delegation started from an issue runs with (ADR 0032).
///
/// ``AutoDelegationPrompt``'s twin, deliberately built the same way and for the same reason: the
/// template belongs to whoever writes it, the substitutions belong to Shepherd, and the result
/// describes the *situation* rather than dictating a solution. What differs is only the
/// vocabulary — an issue has labels and a body where a pull request has a branch, a commit and a
/// CI rollup — so the two cannot share one placeholder set without one of them offering
/// placeholders that are always empty.
///
/// Pure and in ShepherdCore, so the rendering is pinned by tests on the Linux runner rather than
/// discovered in a sheet.
public enum IssueDelegationPrompt {
    /// `{number}` — the issue number.
    public static let numberPlaceholder = "{number}"
    /// `{repo}` — `owner/name`.
    public static let repoPlaceholder = "{repo}"
    /// `{title}` — the issue title.
    public static let titlePlaceholder = "{title}"
    /// `{labels}` — the issue's labels, comma-separated, or `none`.
    public static let labelsPlaceholder = "{labels}"
    /// `{body}` — the issue body, or a sentence saying Shepherd has not read one.
    public static let bodyPlaceholder = "{body}"

    /// Every placeholder, in the order a help text would list them.
    public static let placeholders = [
        numberPlaceholder, repoPlaceholder, titlePlaceholder, labelsPlaceholder, bodyPlaceholder,
    ]

    /// The template used when the caller has none of its own.
    ///
    /// Unlocalised, like every other string that reaches an assistant's prompt: the task text is
    /// read by a tool the user configured, not by the user, and a German prompt against an
    /// English repository would be a worse brief rather than a friendlier one.
    ///
    /// It states the issue and then stops. There is deliberately no "and open a pull request"
    /// here: what the run is allowed to do belongs to the preamble Shepherd controls, not to a
    /// template anybody may rewrite.
    public static let defaultTemplate = """
        Issue {repo}#{number}: {title}
        Labels: {labels}

        {body}

        Work on this issue. Read the repository to find out how it is meant to be solved, and \
        keep the change as small as the issue allows.
        """

    /// The label the delegation reports for a template — `"default"` or `"custom"`.
    ///
    /// The outbound webhook says which template a handover used (ADR 0012's envelope), and it
    /// says it as a name rather than as the text: a template may quote an issue, and a payload
    /// that promises to describe *what happened, not what was written* must not carry the brief
    /// itself. Today only one template exists, so the honest answer is almost always the first
    /// one — and it stays honest on the day a second appears.
    /// - Parameter template: The template that was rendered.
    public static func name(of template: String) -> String {
        template == defaultTemplate ? "default" : "custom"
    }

    /// Fills the placeholders of a template.
    ///
    /// The pieces are passed rather than the row, so the one renderer serves both callers: the
    /// panel, which has read the issue body, and the delegation sheet's own default, which has
    /// only what the context carries.
    /// - Parameters:
    ///   - template: The template to render.
    ///   - number: The issue number.
    ///   - repo: The repository.
    ///   - title: The issue title.
    ///   - labels: The issue's labels; empty renders as `none`.
    ///   - body: The issue body as Markdown source. Empty renders a sentence saying Shepherd has
    ///     not read one — true both for an issue with no description and for one whose body has
    ///     not been fetched yet, which is why the sentence does not claim the issue is empty.
    /// - Returns: The task text, trimmed.
    public static func render(
        template: String,
        number: Int,
        repo: RepoRef,
        title: String,
        labels: [String] = [],
        body: String = ""
    ) -> String {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let substitutions: [(String, String)] = [
            (numberPlaceholder, String(number)),
            (repoPlaceholder, repo.fullName),
            (titlePlaceholder, title),
            (labelsPlaceholder, labels.isEmpty ? "none" : labels.joined(separator: ", ")),
            (
                bodyPlaceholder,
                trimmedBody.isEmpty
                    ? "Shepherd has not read a description for this issue. Read the issue on GitHub if the title is not enough."
                    : trimmedBody
            ),
        ]
        var text = template
        for (placeholder, value) in substitutions {
            text = text.replacingOccurrences(of: placeholder, with: value)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // An emptied template would start a run with no task at all, which the sheet refuses;
        // fall back to the default rather than starting nothing. ``AutoDelegationPrompt`` makes
        // the same choice for the same reason.
        guard !trimmed.isEmpty else {
            return render(
                template: defaultTemplate,
                number: number,
                repo: repo,
                title: title,
                labels: labels,
                body: body
            )
        }
        return trimmed
    }

    /// Fills the placeholders of a template from an issue row.
    /// - Parameters:
    ///   - template: The template to render.
    ///   - issue: The issue the task is about.
    ///   - body: The issue body as Markdown source, when the caller has read it.
    /// - Returns: The task text, trimmed.
    public static func render(
        template: String,
        issue: IssueRowSummary,
        body: String = ""
    ) -> String {
        render(
            template: template,
            number: issue.number,
            repo: issue.repo,
            title: issue.title,
            labels: issue.labels,
            body: body
        )
    }
}
