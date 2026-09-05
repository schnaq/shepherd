import XCTest
@testable import ShepherdCore

/// The `shepherd://` grammar (ADR 0013).
///
/// Deep-link input is untrusted, so the interesting half of this suite is what is *rejected*:
/// unknown commands, extra segments, encoded separators, non-ASCII look-alikes and overlong
/// numbers all have to come back as `nil` rather than as an approximate match.
final class DeepLinkParsingTests: XCTestCase {
    private func parse(_ string: String) -> DeepLink? {
        guard let url = URL(string: string) else { return nil }
        return DeepLink.parse(url)
    }

    // MARK: - Pull requests

    func testParsesPullRequest() {
        XCTAssertEqual(
            parse("shepherd://pr/schnaq/review/42"),
            .pullRequest(repo: RepoRef(owner: "schnaq", name: "review"), number: 42)
        )
    }

    func testCommandWordIsCaseInsensitiveButOwnerAndRepoKeepTheirCasing() {
        XCTAssertEqual(
            parse("shepherd://PR/Schnaq/Review/7"),
            .pullRequest(repo: RepoRef(owner: "Schnaq", name: "Review"), number: 7)
        )
        XCTAssertEqual(parse("SHEPHERD://inbox"), .inbox(filter: nil))
    }

    func testAcceptsTheSchemeWithoutAnAuthority() {
        // `open shepherd:pr/…` and a hand-typed link both have to work.
        XCTAssertEqual(
            parse("shepherd:pr/schnaq/review/3"),
            .pullRequest(repo: RepoRef(owner: "schnaq", name: "review"), number: 3)
        )
    }

    func testPercentEncodedSegmentsAreDecoded() {
        XCTAssertEqual(
            parse("shepherd://pr/schnaq/re%76iew/9"),
            .pullRequest(repo: RepoRef(owner: "schnaq", name: "review"), number: 9)
        )
    }

    func testEncodedSeparatorCannotCreateStructure() {
        // Decoding happens after the split, so this is one invalid owner, not two segments.
        XCTAssertNil(parse("shepherd://pr/sch%2Fnaq/review/1"))
        XCTAssertNil(parse("shepherd://pr/%2E%2E/review/1"))
    }

    func testRejectsMalformedPullRequestLinks() {
        XCTAssertNil(parse("shepherd://pr/schnaq/review"))
        XCTAssertNil(parse("shepherd://pr/schnaq/review/42/files"))
        XCTAssertNil(parse("shepherd://pr/schnaq/review/0"))
        XCTAssertNil(parse("shepherd://pr/schnaq/review/-1"))
        XCTAssertNil(parse("shepherd://pr/schnaq/review/1e3"))
        XCTAssertNil(parse("shepherd://pr/schnaq/review/9999999999"))
        XCTAssertNil(parse("shepherd://pr/schnaq/review/％４２"))
        XCTAssertNil(parse("shepherd://pr//review/1"))
        XCTAssertNil(parse("shepherd://pr/-schnaq/review/1"))
        XCTAssertNil(parse("shepherd://pr/schnaq/.././etc/1"))
        XCTAssertNil(parse("shepherd://pr/schnaq/review/1?x=y#anchor"))
    }

    func testRejectsNonASCIIOwners() {
        // "ѕchnaq" starts with Cyrillic "ѕ", which must not resolve like the ASCII login.
        XCTAssertNil(parse("shepherd://pr/%D1%95chnaq/review/1"))
    }

    func testRejectsForeignSchemesAndAuthorityTricks() {
        XCTAssertNil(parse("https://pr/schnaq/review/1"))
        XCTAssertNil(parse("shepherdx://pr/schnaq/review/1"))
        XCTAssertNil(parse("shepherd://user:secret@pr/schnaq/review/1"))
        XCTAssertNil(parse("shepherd://pr:8080/schnaq/review/1"))
        XCTAssertNil(parse("shepherd://"))
        XCTAssertNil(parse("shepherd://reboot"))
    }

    // MARK: - Issues (ADR 0032)

    func testParsesIssue() {
        XCTAssertEqual(
            parse("shepherd://issue/schnaq/review/128"),
            .issue(repo: RepoRef(owner: "schnaq", name: "review"), number: 128)
        )
        XCTAssertEqual(
            parse("shepherd://ISSUE/Schnaq/Review/7"),
            .issue(repo: RepoRef(owner: "Schnaq", name: "Review"), number: 7)
        )
        XCTAssertEqual(
            parse("shepherd:issue/schnaq/review/3"),
            .issue(repo: RepoRef(owner: "schnaq", name: "review"), number: 3)
        )
    }

    func testIssueLinksAreValidatedExactlyLikePullRequestLinks() {
        XCTAssertNil(parse("shepherd://issue/schnaq/review"))
        XCTAssertNil(parse("shepherd://issue/schnaq/review/128/comments"))
        XCTAssertNil(parse("shepherd://issue/schnaq/review/0"))
        XCTAssertNil(parse("shepherd://issue/sch%2Fnaq/review/1"))
        XCTAssertNil(parse("shepherd://issue/-schnaq/review/1"))
        XCTAssertNil(parse("shepherd://issue/%D1%95chnaq/review/1"))
        XCTAssertNil(parse("shepherd://issue/schnaq/review/9999999999"))
        XCTAssertNil(parse("shepherd://issues/schnaq/review/1"))
    }

    func testTheIssuesFilterTokenParses() {
        XCTAssertEqual(parse("shepherd://inbox?filter=issues"), .inbox(filter: .issues))
        XCTAssertEqual(parse("shepherd://inbox?filter=ISSUES"), .inbox(filter: .issues))
        // A near miss is a rejection, not an approximate match.
        XCTAssertNil(parse("shepherd://inbox?filter=issue"))
        XCTAssertNil(parse("shepherd://inbox?filter=issues:open"))
    }

    // MARK: - Inbox

    func testParsesInboxWithAndWithoutFilter() {
        XCTAssertEqual(parse("shepherd://inbox"), .inbox(filter: nil))
        XCTAssertEqual(parse("shepherd://inbox/"), .inbox(filter: nil))
        XCTAssertEqual(parse("shepherd://inbox?filter="), .inbox(filter: nil))
        XCTAssertEqual(parse("shepherd://inbox?filter=mine"), .inbox(filter: .myPullRequests))
        XCTAssertEqual(
            parse("shepherd://inbox?filter=needs-my-review"),
            .inbox(filter: .needsMyReview)
        )
        XCTAssertEqual(parse("shepherd://inbox?filter=BOTS"), .inbox(filter: .bots))
        XCTAssertEqual(
            parse("shepherd://inbox?filter=agent:Claude-Code"),
            .inbox(filter: .agent(id: "claude-code"))
        )
        XCTAssertEqual(
            parse("shepherd://inbox?filter=repo%3Aschnaq%2Freview"),
            .inbox(filter: .repository(RepoRef(owner: "schnaq", name: "review")))
        )
        XCTAssertEqual(
            parse("shepherd://inbox?filter=repo:schnaq/review"),
            .inbox(filter: .repository(RepoRef(owner: "schnaq", name: "review")))
        )
    }

    func testUnknownQueryItemsAreIgnored() {
        XCTAssertEqual(
            parse("shepherd://inbox?filter=mine&sort=priority"),
            .inbox(filter: .myPullRequests)
        )
    }

    func testRejectsMalformedInboxLinks() {
        XCTAssertNil(parse("shepherd://inbox?filter=everything"))
        XCTAssertNil(parse("shepherd://inbox?filter=agent:"))
        XCTAssertNil(parse("shepherd://inbox?filter=agent:claude%20code"))
        XCTAssertNil(parse("shepherd://inbox?filter=repo:schnaq"))
        XCTAssertNil(parse("shepherd://inbox?filter=repo:schnaq/review/extra"))
        XCTAssertNil(parse("shepherd://inbox?filter=mine&filter=bots"))
        XCTAssertNil(parse("shepherd://inbox/mine"))
    }

    // MARK: - The fleet (ADR 0035)

    func testParsesTheFleet() {
        XCTAssertEqual(parse("shepherd://fleet"), .fleet(agentID: nil))
        XCTAssertEqual(parse("shepherd://fleet/"), .fleet(agentID: nil))
        XCTAssertEqual(parse("shepherd:fleet"), .fleet(agentID: nil))
        XCTAssertEqual(
            parse("shepherd://fleet/claude-code"),
            .fleet(agentID: "claude-code")
        )
        // Registry ids are lower-cased, exactly as `filter=agent:<id>` lower-cases them: one id
        // spelled two ways must not become two agents.
        XCTAssertEqual(
            parse("shepherd://FLEET/Claude-Code"),
            .fleet(agentID: "claude-code")
        )
        XCTAssertEqual(
            parse("shepherd://fleet/re%76iewer.bot_2"),
            .fleet(agentID: "reviewer.bot_2")
        )
    }

    func testRejectsMalformedFleetLinks() {
        // One segment or none. A second segment is a rejection rather than something to ignore,
        // for the reason `pr/…/files` is.
        XCTAssertNil(parse("shepherd://fleet/claude-code/repos"))
        XCTAssertNil(parse("shepherd://fleet/a/b"))
        // An id that is not an id: a space, an encoded separator, a non-ASCII look-alike, and one
        // over the sixty-four character limit.
        XCTAssertNil(parse("shepherd://fleet/claude%20code"))
        XCTAssertNil(parse("shepherd://fleet/claude%2Fcode"))
        XCTAssertNil(parse("shepherd://fleet/%D1%95chnaq"))
        XCTAssertNil(parse("shepherd://fleet/" + String(repeating: "a", count: 65)))
        // The authority tricks the whole grammar refuses, on this command too.
        XCTAssertNil(parse("shepherd://fleet/claude-code#top"))
        XCTAssertNil(parse("shepherd://fleet:8080/claude-code"))
        XCTAssertNil(parse("shepherd://user:secret@fleet/claude-code"))
        // A near miss on the command word is not the command.
        XCTAssertNil(parse("shepherd://fleets"))
    }

    // MARK: - Sync and settings

    func testParsesSync() {
        XCTAssertEqual(parse("shepherd://sync"), .sync)
        XCTAssertEqual(parse("shepherd://sync/"), .sync)
        XCTAssertNil(parse("shepherd://sync/now"))
    }

    func testParsesSettings() {
        XCTAssertEqual(parse("shepherd://settings"), .settings(tab: .account))
        XCTAssertEqual(parse("shepherd://settings/automation"), .settings(tab: .automation))
        XCTAssertEqual(parse("shepherd://settings/Delegation"), .settings(tab: .delegation))
        XCTAssertNil(parse("shepherd://settings/keychain"))
        XCTAssertNil(parse("shepherd://settings/automation/webhook"))
    }

    // MARK: - Serialisation

    func testCanonicalURLStrings() {
        XCTAssertEqual(
            DeepLink.pullRequest(repo: RepoRef(owner: "schnaq", name: "review"), number: 42)
                .urlString,
            "shepherd://pr/schnaq/review/42"
        )
        XCTAssertEqual(
            DeepLink.issue(repo: RepoRef(owner: "schnaq", name: "review"), number: 128).urlString,
            "shepherd://issue/schnaq/review/128"
        )
        XCTAssertEqual(
            DeepLink.inbox(filter: .issues).urlString,
            "shepherd://inbox?filter=issues"
        )
        XCTAssertEqual(DeepLink.inbox(filter: nil).urlString, "shepherd://inbox")
        XCTAssertEqual(
            DeepLink.inbox(filter: .agent(id: "claude-code")).urlString,
            "shepherd://inbox?filter=agent%3Aclaude-code"
        )
        XCTAssertEqual(
            DeepLink.inbox(filter: .repository(RepoRef(owner: "schnaq", name: "review")))
                .urlString,
            "shepherd://inbox?filter=repo%3Aschnaq%2Freview"
        )
        XCTAssertEqual(DeepLink.fleet(agentID: nil).urlString, "shepherd://fleet")
        XCTAssertEqual(
            DeepLink.fleet(agentID: "claude-code").urlString,
            "shepherd://fleet/claude-code"
        )
        XCTAssertEqual(DeepLink.sync.urlString, "shepherd://sync")
        XCTAssertEqual(
            DeepLink.settings(tab: .intelligence).urlString,
            "shepherd://settings/intelligence"
        )
    }

    func testEveryLinkRoundTrips() {
        let links: [DeepLink] = [
            .pullRequest(repo: RepoRef(owner: "schnaq", name: "review.swift"), number: 1),
            .pullRequest(repo: RepoRef(owner: "a-b", name: "c_d.e"), number: 999_999_999),
            .issue(repo: RepoRef(owner: "schnaq", name: "review.swift"), number: 1),
            .issue(repo: RepoRef(owner: "a-b", name: "c_d.e"), number: 999_999_999),
            .inbox(filter: nil),
            .inbox(filter: .needsMyReview),
            .inbox(filter: .myPullRequests),
            .inbox(filter: .involved),
            .inbox(filter: .approvedByMe),
            .inbox(filter: .humans),
            .inbox(filter: .bots),
            .inbox(filter: .agent(id: "claude-code")),
            .inbox(filter: .repository(RepoRef(owner: "schnaq", name: "review"))),
            .inbox(filter: .issues),
            .fleet(agentID: nil),
            .fleet(agentID: "claude-code"),
            .fleet(agentID: "a.b_c-2"),
            .sync,
        ] + SettingsDeepLinkTab.allCases.map { DeepLink.settings(tab: $0) }

        for link in links {
            guard let url = link.url else {
                XCTFail("\(link) produced no URL")
                continue
            }
            XCTAssertEqual(DeepLink.parse(url), link, "round trip failed for \(link.urlString)")
        }
    }
}

/// The `shepherd` CLI's argument grammar (ADR 0013).
final class ShepherdCommandLineTests: XCTestCase {
    private func invocation(_ arguments: String...) throws -> ShepherdCommandLine.Invocation {
        try ShepherdCommandLine.parse(arguments)
    }

    func testBareInvocationPrintsUsage() throws {
        XCTAssertEqual(try ShepherdCommandLine.parse([]), .help)
        XCTAssertEqual(try invocation("--help"), .help)
        XCTAssertEqual(try invocation("-h"), .help)
        XCTAssertEqual(try invocation("help"), .help)
        XCTAssertEqual(try invocation("open", "--help"), .help)
        XCTAssertEqual(try invocation("--version"), .version)
        XCTAssertEqual(try invocation("-v"), .version)
    }

    func testOpenAcceptsEveryPullRequestSpelling() throws {
        let expected = ShepherdCommandLine.Invocation.open(
            .pullRequest(repo: RepoRef(owner: "schnaq", name: "review"), number: 42)
        )
        XCTAssertEqual(try invocation("open", "schnaq/review#42"), expected)
        XCTAssertEqual(try invocation("open", "schnaq/review/42"), expected)
        XCTAssertEqual(
            try invocation("open", "https://github.com/schnaq/review/pull/42"),
            expected
        )
        XCTAssertEqual(
            try invocation("open", "https://github.com/schnaq/review/pull/42/files"),
            expected
        )
        XCTAssertEqual(
            try invocation("open", "https://www.github.com/schnaq/review/pull/42?w=1"),
            expected
        )
    }

    func testOpenRejectsAnythingElse() {
        XCTAssertThrowsError(try invocation("open"))
        for reference in [
            "schnaq",
            "schnaq/review",
            "schnaq/review#",
            "schnaq/review#abc",
            "schnaq/review/1/2",
            "https://github.com/schnaq/review/issues/42",
            "https://example.com/schnaq/review/pull/42",
            "https://github.com/schnaq/review/pull/42; rm -rf /",
        ] {
            XCTAssertThrowsError(try invocation("open", reference), reference)
        }
    }

    func testIssueAcceptsEverySpellingAndRefusesAPullRequestURL() throws {
        let expected = ShepherdCommandLine.Invocation.open(
            .issue(repo: RepoRef(owner: "schnaq", name: "review"), number: 128)
        )
        XCTAssertEqual(try invocation("issue", "schnaq/review#128"), expected)
        XCTAssertEqual(try invocation("issue", "schnaq/review/128"), expected)
        XCTAssertEqual(
            try invocation("issue", "https://github.com/schnaq/review/issues/128"),
            expected
        )
        XCTAssertEqual(
            try invocation("issue", "https://www.github.com/schnaq/review/issues/128#issue-1"),
            expected
        )
        XCTAssertThrowsError(try invocation("issue"))
        XCTAssertThrowsError(try invocation("issue", "schnaq/review#128", "extra"))
        for reference in [
            "schnaq",
            "schnaq/review",
            "schnaq/review#",
            "schnaq/review#abc",
            "https://github.com/schnaq/review/pull/128",
            "https://example.com/schnaq/review/issues/128",
        ] {
            XCTAssertThrowsError(try invocation("issue", reference), reference)
        }
    }

    func testInboxIssuesIsTheContentKindShorthand() throws {
        XCTAssertEqual(try invocation("inbox", "issues"), .open(.inbox(filter: .issues)))
        XCTAssertEqual(
            try invocation("inbox", "--filter", "issues"),
            .open(.inbox(filter: .issues))
        )
    }

    func testUsageNamesTheIssueVerbAndTheIssuesFilter() {
        // The grammar is a public interface (ADR 0013), so the help text is part of the change
        // rather than a follow-up.
        XCTAssertTrue(ShepherdCommandLine.usage.contains("shepherd issue <issue>"))
        XCTAssertTrue(ShepherdCommandLine.usage.contains("shepherd issue schnaq/review#128"))
        XCTAssertTrue(ShepherdCommandLine.usage.contains("shepherd inbox issues"))
        XCTAssertTrue(
            ShepherdCommandLine.usage.contains("https://github.com/owner/repo/issues/123")
        )
    }

    func testInbox() throws {
        XCTAssertEqual(try invocation("inbox"), .open(.inbox(filter: nil)))
        XCTAssertEqual(try invocation("inbox", "mine"), .open(.inbox(filter: .myPullRequests)))
        XCTAssertEqual(
            try invocation("inbox", "--filter", "agent:claude-code"),
            .open(.inbox(filter: .agent(id: "claude-code")))
        )
        XCTAssertEqual(
            try invocation("inbox", "--filter=repo:schnaq/review"),
            .open(.inbox(filter: .repository(RepoRef(owner: "schnaq", name: "review"))))
        )
        XCTAssertThrowsError(try invocation("inbox", "everything"))
        XCTAssertThrowsError(try invocation("inbox", "--filter"))
        XCTAssertThrowsError(try invocation("inbox", "--fitler", "mine"))
        XCTAssertThrowsError(try invocation("inbox", "mine", "bots"))
    }

    func testFleetTakesAnOptionalAgentID() throws {
        XCTAssertEqual(try invocation("fleet"), .open(.fleet(agentID: nil)))
        XCTAssertEqual(
            try invocation("fleet", "claude-code"),
            .open(.fleet(agentID: "claude-code"))
        )
        // The CLI lower-cases through the same validator the URL parser uses, so the two
        // spellings of one id cannot disagree about which agent was asked for.
        XCTAssertEqual(
            try invocation("fleet", "Claude-Code"),
            .open(.fleet(agentID: "claude-code"))
        )
        XCTAssertThrowsError(try invocation("fleet", "claude-code", "extra"))
        // A hyphen is legal *inside* an id, so a mistyped option would otherwise resolve to an
        // agent nobody has.
        XCTAssertThrowsError(try invocation("fleet", "--all")) { error in
            XCTAssertEqual(error as? ShepherdCommandLine.Failure, .unknownOption("--all"))
        }
        XCTAssertThrowsError(try invocation("fleet", "claude code")) { error in
            XCTAssertEqual(
                error as? ShepherdCommandLine.Failure,
                .invalidAgentID("claude code")
            )
        }
        // A login is not an id, and the message has to be the one that says so.
        XCTAssertThrowsError(try invocation("fleet", "schnaq/review")) { error in
            XCTAssertEqual(
                error as? ShepherdCommandLine.Failure,
                .invalidAgentID("schnaq/review")
            )
        }
    }

    func testUsageNamesTheFleetVerb() {
        // ADR 0013 couples the grammar and the help text: `--help` is where the URL scheme is
        // discoverable without the docs, so a verb that is not in it is a verb nobody finds.
        XCTAssertTrue(ShepherdCommandLine.usage.contains("shepherd fleet [<agent-id>]"))
        XCTAssertTrue(ShepherdCommandLine.usage.contains("shepherd fleet claude-code"))
        XCTAssertTrue(ShepherdCommandLine.usage.contains("AGENT IDS"))
    }

    func testSyncAndSettings() throws {
        XCTAssertEqual(try invocation("sync"), .open(.sync))
        XCTAssertThrowsError(try invocation("sync", "now"))
        XCTAssertEqual(try invocation("settings"), .open(.settings(tab: .account)))
        XCTAssertEqual(try invocation("settings", "automation"), .open(.settings(tab: .automation)))
        XCTAssertThrowsError(try invocation("settings", "keychain"))
    }

    func testUnknownCommand() {
        XCTAssertThrowsError(try invocation("merge", "schnaq/review#1")) { error in
            XCTAssertEqual(
                error as? ShepherdCommandLine.Failure,
                .unknownCommand("merge")
            )
        }
    }

    func testEveryInvocationProducesAParsableURL() throws {
        let arguments: [[String]] = [
            ["open", "schnaq/review#1"],
            ["inbox"],
            ["inbox", "bots"],
            ["inbox", "--filter", "repo:schnaq/review"],
            ["fleet"],
            ["fleet", "claude-code"],
            ["sync"],
            ["settings", "delegation"],
        ]
        for argv in arguments {
            guard case .open(let link) = try ShepherdCommandLine.parse(argv),
                  let url = link.url
            else {
                XCTFail("\(argv) did not produce a link")
                continue
            }
            XCTAssertEqual(DeepLink.parse(url), link, "\(argv) built a URL the app rejects")
        }
    }
}

/// ``RepoRef/isSameRepository(as:)`` — the comparison every externally supplied repository
/// reference goes through.
final class RepoRefIdentityTests: XCTestCase {
    func testCaseInsensitiveIdentity() {
        let canonical = RepoRef(owner: "schnaq", name: "review")
        XCTAssertTrue(canonical.isSameRepository(as: RepoRef(owner: "Schnaq", name: "Review")))
        XCTAssertTrue(canonical.isSameRepository(as: canonical))
        XCTAssertFalse(canonical.isSameRepository(as: RepoRef(owner: "schnaq", name: "reviews")))
        XCTAssertFalse(canonical.isSameRepository(as: RepoRef(owner: "schnaq2", name: "review")))
        // Hashable stays exact: it is a persistence key.
        XCTAssertNotEqual(canonical, RepoRef(owner: "Schnaq", name: "Review"))
    }
}
