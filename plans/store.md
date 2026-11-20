# The GitHub store

Hermes keeps one copy of everything it knows about GitHub, in `GitHubStore`
(the `StateKit` target). The sidebar, the lists, and every screen read from it,
so two views of the same fact can't disagree. A count is a field on a record,
and every view reads that field.

When a view shows something wrong, fix the store's copy. Don't give the view
a second source, and don't copy a value from one place into another.

## Shape

`AppStore` owns one `GitHubStore` for the app. Records live in tables keyed by
identity. An account's lists hold keys into those tables, so a pull request
that two lists show is one record.

```mermaid
graph TD
    AS[AppStore] --> GS[GitHubStore]
    GS --> PR["pullRequests [ItemKey: PullRequest]"]
    GS --> IS["issues [ItemKey: Issue]"]
    GS --> RE["repositories [RepositoryRef: Stamped&lt;Repository&gt;]"]
    GS --> AC["accounts [login: AccountLists]"]
    GS --> IL["issueLists [RepositoryRef: IssueList]"]
    AC -. keys .-> PR
    AC -. refs .-> RE
    IL -. keys .-> IS
```

| Table or list | Holds | Written by |
|---|---|---|
| `pullRequests` | Every pull request Hermes has loaded, open or not. | List refreshes, loads by number, webhook payloads. |
| `issues` | Every issue Hermes has loaded. | Issue pages, loads by number. |
| `repositories` | Each repository's URL, visibility, and open issue count. | The account's repository load and every issue page. |
| `accounts[login]` | The account's open pull requests and repositories, as keys, plus its review signals and load state. | The account's refresh. |
| `issueLists[repo]` | The loaded part of a repository's open issues, as keys, and its cursor. | Issue pages. |
| `details[key]` | A pull request's description, conversation, reviews, commits, and review threads. The conversation tab and the diff's review threads read it. | The pull request's poll, webhook changes, and a submitted review. |
| `readiness[key]` | Whether a pull request can merge, and how. | The pull request's poll, when its head, update time, or checks change, and after a merge or an auto-merge change. |
| `revisions[key]` | A pull request's head commit, update time, and viewed files. | The pull request's poll, the diff's own load, and viewed marks. |
| `checks[commit]` | A commit's checks, keyed by repository and commit SHA, so a pull request's checks are its head commit's. The checks tab and the conversation's summary read the same list. | The commit's poll, webhook changes, retries, and reruns. |
| `viewer` | The signed-in user's login. | Sign-in. |

Records stay until the app quits. A screen that shows one again makes the
store load it again, so a kept record doesn't stay stale on screen.

## Which answer wins

Two fetches can return the same fact in either order. The one that started
later saw GitHub later, so its answer wins even when it arrives first.
`Stamped` holds a value with its fetch's start time and refuses a write from a
fetch that started earlier.

For example, the repository list loads every 10 minutes, and each issue page
also reports the open issue count. Both write the repository record. If the
repository load started first but answered last, its older count is dropped.
A viewed mark writes the pull request's revision with the time of the click,
so a poll that asked GitHub before the click can't undo the mark. Until GitHub
confirms the mark, every revision the store takes keeps it.

A pull request's detail uses a counter instead: a webhook change applied while
a load runs makes the load ask again, and a load that a later one overtakes
drops its answer.

Webhook payloads use `AppliedPayloads`. A payload older than the last one a
pull request took is dropped, and a load that ran while a payload arrived
loads that pull request once more. [webhooks.md](webhooks.md) has the details.

## Polling

Screens say what they show with the `.showing(_:in:)` view modifier from
`HermesUI`. It registers an `Interest` while the view is on screen and
releases it when the view goes away, through `.task` cancellation. The store
runs one poll loop per interest while any screen shows it, so two windows on
one account cost one refresh.

```swift
// Each window keeps its account's lists fresh while it is open.
RootView()
    .showing(.account(model.login), in: model.github)
```

| Interest | Refreshes | How often |
|---|---|---|
| `.account(login)` | The account's open pull requests, its repositories (every 10 minutes), and its opened issue lists. | Every 15 seconds while Hermes is the active app. In the background, every `refreshInterval` from Settings (60 seconds by default). |
| `.checks(commit)` | The commit's checks: once when a screen starts showing them, then while one is queued or running, or for 2 minutes while the list is empty. A failed refresh tries again after 10 seconds, or once a used-up rate limit resets. A failed first load waits for Retry. | Every 10 seconds. |
| `.pullRequest(key)` | The pull request's revision. When the head or update time moved, its record and detail. When the head, update time, or checks moved, its merge readiness. | Every 10 seconds. The pull request pane shows it, so every tab gets it. |

A loop polls as soon as a screen shows its interest, then once per interval.
An account's loop asks `shouldRefresh` whether a tick loads, so in the
background it waits for `refreshInterval`. Activation and ⌘R refresh at once.

A poll runs in its own task. When the last screen goes away the loop stops,
and a poll already running finishes.
