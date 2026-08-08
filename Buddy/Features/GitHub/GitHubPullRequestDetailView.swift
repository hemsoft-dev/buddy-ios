import SwiftUI

struct GitHubPullRequestDetailView: View {
    let pullRequest: GitHubPullRequest
    let account: GitHubAccount
    let store: GitHubPullRequestDetailStore

    var body: some View {
        Group {
            switch store.state(for: pullRequest, account: account) {
            case .idle, .loading:
                ProgressView("Loading pull request…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case let .loaded(details):
                detailsScrollView(details)

            case let .refreshing(details):
                detailsScrollView(details, isRefreshing: true)

            case let .failed(details, failure):
                if let details {
                    detailsScrollView(details, failure: failure)
                } else {
                    failureView(failure)
                }
            }
        }
        .background(BuddyTheme.background)
        .navigationTitle("Pull Request")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Link(destination: pullRequest.url) {
                    Label("Open on GitHub", systemImage: "arrow.up.right.square")
                }
                .accessibilityHint("Opens this pull request in your browser")
            }
        }
        .task {
            await store.load(pullRequest, account: account)
        }
        .onDisappear {
            store.cancel(pullRequest, account: account)
        }
    }

    private func detailsScrollView(
        _ details: GitHubPullRequestDetails,
        isRefreshing: Bool = false,
        failure: GitHubPullRequestFailure? = nil
    ) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: BuddyTheme.Spacing.large) {
                if isRefreshing {
                    Label("Refreshing pull request…", systemImage: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let failure {
                    failureBanner(failure)
                }
                header(details)
                diffSummary(details)
                linkedIssues(details.linkedIssues)
                reviewers(details.reviewers)
                description(details.body)
            }
            .padding(BuddyTheme.Spacing.medium)
        }
        .refreshable {
            await store.refresh(pullRequest, account: account)
        }
    }

    private func header(_ details: GitHubPullRequestDetails) -> some View {
        VStack(alignment: .leading, spacing: BuddyTheme.Spacing.small) {
            Text("\(details.repository) #\(details.number)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(details.isDraft ? "Draft" : details.state.label)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, BuddyTheme.Spacing.small)
                .padding(.vertical, BuddyTheme.Spacing.xSmall)
                .background(.secondary.opacity(0.12), in: Capsule())
                .accessibilityLabel("Pull request state: \(details.isDraft ? "Draft" : details.state.label)")

            Text(details.title)
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: BuddyTheme.Spacing.small) {
                avatar(details.author?.avatarURL, label: details.author?.login ?? "Unknown author")

                VStack(alignment: .leading, spacing: BuddyTheme.Spacing.xSmall) {
                    if let author = details.author {
                        Text(author.name.flatMap { $0.isEmpty ? nil : $0 } ?? "@\(author.login)")
                            .font(.subheadline.weight(.medium))
                        if let name = author.name, !name.isEmpty {
                            Text("@\(author.login)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Unknown author")
                            .font(.subheadline.weight(.medium))
                    }
                    Text("Updated \(details.updatedAt, style: .relative) ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func diffSummary(_ details: GitHubPullRequestDetails) -> some View {
        VStack(alignment: .leading, spacing: BuddyTheme.Spacing.small) {
            Text("Changes")
                .font(.headline)

            Text("\(details.changedFiles) files · \(details.changedLines) lines")
                .font(.title3.weight(.semibold))

            HStack(spacing: BuddyTheme.Spacing.large) {
                Label("\(details.additions) additions", systemImage: "plus")
                    .foregroundStyle(.primary)
                Label("\(details.deletions) deletions", systemImage: "minus")
                    .foregroundStyle(.primary)
            }
            .font(.subheadline.weight(.medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .buddyCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(GitHubPullRequestDetailCopy.diffAccessibilityLabel(details))
    }

    @ViewBuilder
    private func linkedIssues(_ issues: [GitHubIssueReference]) -> some View {
        section("Linked issues") {
            if issues.isEmpty {
                Text("No linked issue reported by GitHub")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(issues) { issue in
                    Link(destination: issue.url) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("#\(issue.number)")
                                .font(.subheadline.weight(.semibold))
                            Text(issue.title)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: BuddyTheme.Spacing.small)
                            Image(systemName: "arrow.up.right.square")
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 44)
                    }
                    .accessibilityLabel("Issue \(issue.number), \(issue.title)")
                    .accessibilityHint("Opens the linked issue on GitHub")
                }
            }
        }
    }

    @ViewBuilder
    private func reviewers(_ reviewers: [GitHubReviewerSummary]) -> some View {
        section("Reviewers") {
            if reviewers.isEmpty {
                Text("No reviewers")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(reviewers) { reviewer in
                    HStack(spacing: BuddyTheme.Spacing.small) {
                        avatar(reviewer.reviewer.avatarURL, label: reviewer.reviewer.login)
                        VStack(alignment: .leading, spacing: BuddyTheme.Spacing.xSmall) {
                            Text(reviewer.reviewer.name.flatMap { $0.isEmpty ? nil : $0 } ?? reviewer.reviewer.login)
                                .font(.subheadline.weight(.medium))
                            Text(reviewer.status.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: BuddyTheme.Spacing.small)
                    }
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(reviewer.reviewer.isTeam ? "Team" : "Reviewer") \(reviewer.reviewer.login), \(reviewer.status.label)")
                }
            }
        }
    }

    @ViewBuilder
    private func description(_ body: String) -> some View {
        section("Description") {
            if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No description provided")
                    .foregroundStyle(.secondary)
            } else if let markdown = try? AttributedString(markdown: body) {
                Text(markdown)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text(body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: BuddyTheme.Spacing.small) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func avatar(_ url: URL?, label: String) -> some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .foregroundStyle(.secondary)
        }
        .frame(width: 36, height: 36)
        .clipShape(Circle())
        .accessibilityLabel("\(label) avatar")
    }

    private func failureView(_ failure: GitHubPullRequestFailure) -> some View {
        ContentUnavailableView {
            Label("Couldn't load pull request", systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text(failure.message)
        } actions: {
            Button("Try Again") {
                Task { await store.retry(pullRequest, account: account) }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func failureBanner(_ failure: GitHubPullRequestFailure) -> some View {
        VStack(alignment: .leading, spacing: BuddyTheme.Spacing.small) {
            Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Button("Try Again") {
                Task { await store.retry(pullRequest, account: account) }
            }
            .buttonStyle(.bordered)
        }
    }
}
