import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import qs.DCommon.Widgets as DC

PluginComponent {
    id: root

    // ---- State ----
    // PluginGlobalVar is shared live between instances (one per screen) but
    // only lives in memory, so every write also goes to the plugin's state
    // file via _put(), and _hydrate() loads it back once after a restart.
    PluginGlobalVar { id: cachedReview; varName: "cachedReview"; defaultValue: [] }
    PluginGlobalVar { id: cachedMine;   varName: "cachedMine";   defaultValue: [] }
    PluginGlobalVar { id: cachedWork;   varName: "cachedWork";   defaultValue: [] }
    PluginGlobalVar { id: lastPollAt;   varName: "lastPollAt";   defaultValue: 0 }
    // { "<prId>": { mode, active, comments: [...] } } — latest human comments per PR.
    PluginGlobalVar { id: cachedThreads;     varName: "cachedThreads";     defaultValue: ({}) }
    // "<prId>:<threadId>:<commentId>" keys. Seen = already diffed (no
    // re-notify); unread = arrived since you last looked at that PR.
    PluginGlobalVar { id: seenCommentKeys;   varName: "seenCommentKeys";   defaultValue: [] }
    PluginGlobalVar { id: unreadCommentKeys; varName: "unreadCommentKeys"; defaultValue: [] }
    PluginGlobalVar { id: commentsSeeded;    varName: "commentsSeeded";    defaultValue: false }
    // In-memory only: which instance polls, and whether state was loaded.
    PluginGlobalVar { id: pollerId; varName: "pollerId"; defaultValue: "" }
    PluginGlobalVar { id: hydrated; varName: "hydrated"; defaultValue: false }

    readonly property var _persisted: [cachedReview, cachedMine, cachedWork, lastPollAt,
        cachedThreads, seenCommentKeys, unreadCommentKeys, commentsSeeded]
    readonly property string _instanceId: Math.random().toString(36).slice(2)

    function _put(v, value) {
        v.set(value)
        if (root.pluginId) PluginService.savePluginState(root.pluginId, v.varName, value)
    }

    function _hydrate() {
        if (hydrated.value || !root.pluginId) return
        for (let i = 0; i < _persisted.length; i++) {
            const v = _persisted[i]
            const saved = PluginService.loadPluginState(root.pluginId, v.varName, undefined)
            if (saved !== undefined && saved !== null) v.set(saved)
        }
        hydrated.set(true)
    }

    // With a bar on each screen there's one instance per screen; only one of
    // them polls so notifications don't fire twice.
    function _isPoller() {
        if (!pollerId.value) pollerId.set(root._instanceId)
        return pollerId.value === root._instanceId
    }

    // ---- Settings (from AzureDevOpsSettings.qml) ----
    readonly property string orgUrl: pluginData.orgUrl || ""
    readonly property string projects: pluginData.projects || ""
    readonly property string tokenSource: pluginData.tokenSource || "file"
    readonly property string tokenPath: pluginData.tokenPath || ""
    readonly property string excludedStates: pluginData.excludedStates ?? "Closed,Done,Removed,Resolved,Completed"
    readonly property string extraWiql: pluginData.extraWiql || ""
    readonly property bool hideDrafts: pluginData.hideDrafts ?? true
    readonly property int pollMinutes: parseInt(pluginData.pollMinutes || "5")
    readonly property string pillMode: pluginData.pillMode || "both"
    readonly property string defaultTab: pluginData.defaultTab || "review"
    readonly property bool branchPrefixByType: pluginData.branchPrefixByType ?? true
    readonly property bool notifyReview: pluginData.notifyReview ?? true
    readonly property bool notifyVotes: pluginData.notifyVotes ?? true
    readonly property bool notifyAssigned: pluginData.notifyAssigned ?? false
    readonly property bool notifyComments: pluginData.notifyComments ?? true
    readonly property bool notifyReplies: pluginData.notifyReplies ?? true
    readonly property bool showUnreadOnBar: pluginData.showUnreadOnBar ?? true
    readonly property bool demoMode: pluginData.demoMode ?? false

    readonly property bool configured: demoMode || orgUrl.length > 0

    // ---- Demo data (shapes match the real REST responses) ----
    readonly property string _demoMe: "00000000-0000-0000-0000-00000000000a"
    function _demoPr(id, repo, title, author, src, tgt, draft, hoursAgo, reviewers) {
        return {
            pullRequestId: id, title: title, isDraft: draft,
            sourceRefName: "refs/heads/" + src, targetRefName: "refs/heads/" + tgt,
            creationDate: new Date(Date.now() - hoursAgo * 3600000).toISOString(),
            createdBy: { id: author === "me" ? _demoMe : "u-" + author, displayName: author === "me" ? "You" : author },
            repository: { id: "r-" + repo, name: repo, project: { id: "p", name: "Contoso" } },
            reviewers: reviewers
        }
    }
    readonly property var demoReview: [
        _demoPr(4812, "billing-service", "Add idempotency keys to payment capture endpoint", "Lucía Fernández",
            "feature/payment-idempotency", "main", false, 3,
            [{ id: _demoMe, displayName: "You", vote: 0 }, { id: "u-2", displayName: "Marco Ruiz", vote: 10 }]),
        _demoPr(4807, "web-dashboard", "Points expiry banner on the dashboard", "Marco Ruiz",
            "feature/points-expiry-banner", "develop", false, 20,
            [{ id: _demoMe, displayName: "You", vote: -5 }]),
        _demoPr(4799, "mobile-app", "Bump React Native to 0.76", "Ana Gómez",
            "chore/rn-076", "main", false, 52,
            [{ id: _demoMe, displayName: "You", vote: 0 }, { id: "u-4", displayName: "Lucía Fernández", vote: -10 }])
    ]
    readonly property var demoMine: [
        _demoPr(4815, "orders-api", "Run tier recalculation job per tenant", "me",
            "feature/1290-tier-recalc", "main", false, 5,
            [{ id: "u-2", displayName: "Marco Ruiz", vote: 10 }, { id: "u-3", displayName: "Ana Gómez", vote: 5 }]),
        _demoPr(4790, "billing-service", "WIP: receipt templating engine", "me",
            "feature/receipt-templates", "develop", true, 70, [])
    ]
    function _demoWi(id, type, title, state, prio, hoursAgo) {
        return { id: id, fields: {
            "System.Id": id, "System.Title": title, "System.State": state,
            "System.WorkItemType": type, "System.TeamProject": "Contoso",
            "System.ChangedDate": new Date(Date.now() - hoursAgo * 3600000).toISOString(),
            "Microsoft.VSTS.Common.Priority": prio } }
    }
    readonly property var demoWork: [
        _demoWi(1290, "User Story", "Recalculate customer tiers nightly per tenant", "Active", 1, 2),
        _demoWi(1302, "Bug", "Receipt total rounds incorrectly with 3+ discounts", "New", 1, 6),
        _demoWi(1277, "Task", "Write migration for tier_history table", "Active", 2, 30),
        _demoWi(1255, "Bug", "Mobile app crashes on logout when offline", "New", 3, 96)
    ]
    readonly property var demoStates: [
        { name: "New", category: "Proposed" },
        { name: "Active", category: "InProgress" },
        { name: "Resolved", category: "Resolved" },
        { name: "Closed", category: "Completed" }
    ]

    function _demoC(prId, threadId, commentId, author, content, hoursAgo, filePath, status) {
        return {
            key: prId + ":" + threadId + ":" + commentId, threadId: threadId,
            author: author === "me" ? "You" : author, isMine: author === "me",
            content: content, date: new Date(Date.now() - hoursAgo * 3600000).toISOString(),
            filePath: filePath || "", status: status || "active"
        }
    }
    readonly property var demoThreads: ({
        "4815": { mode: "mine", active: 2, comments: [
            _demoC(4815, 71, 3, "Ana Gómez", "Should this run inside one transaction per tenant? If tenant 40 fails halfway we'd leave tiers half-updated.", 0.3, "/src/Jobs/TierRecalcJob.cs"),
            _demoC(4815, 70, 2, "Marco Ruiz", "Batch size of 500 feels arbitrary — can we read it from config?", 1.5, "/src/Jobs/TierRecalcJob.cs"),
            _demoC(4815, 69, 1, "me", "Added the tenant loop, ready for another look.", 4, "", "fixed")
        ] },
        "4807": { mode: "review", active: 1, comments: [
            _demoC(4807, 52, 2, "Marco Ruiz", "Good catch, moved the date formatting into the hook.", 0.8, "/src/components/ExpiryBanner.tsx"),
            _demoC(4807, 52, 1, "me", "This re-renders on every tick — memoize the formatted date?", 19, "/src/components/ExpiryBanner.tsx")
        ] }
    })
    property var demoUnread: ["4815:71:3", "4815:70:2", "4807:52:2"]

    // ---- Effective data ----
    readonly property string myId: demoMode ? _demoMe : client.userId
    readonly property var threadsByPr: demoMode ? demoThreads : (cachedThreads.value || {})
    readonly property var unreadKeys: demoMode ? demoUnread : (unreadCommentKeys.value || [])
    readonly property var reviewPrs: {
        const list = demoMode ? demoReview : (cachedReview.value || [])
        return hideDrafts ? list.filter(function (p) { return !p.isDraft }) : list
    }
    readonly property var myPrs: demoMode ? demoMine : (cachedMine.value || [])
    readonly property var workItems: demoMode ? demoWork : (cachedWork.value || [])

    // PRs to review where I haven't voted yet — what the badge counts.
    readonly property int pendingReviewCount: reviewPrs.filter(function (p) {
        const v = root.myVote(p)
        return v === 0
    }).length

    function unreadFor(prId) {
        const prefix = prId + ":"
        return unreadKeys.filter(function (k) { return k.indexOf(prefix) === 0 }).length
    }
    function unreadForList(prs) {
        let n = 0
        for (let i = 0; i < prs.length; i++) n += unreadFor(prs[i].pullRequestId)
        return n
    }
    // Only count PRs that are still active (keys for merged PRs linger).
    readonly property int unreadCount: unreadForList(myPrs) + unreadForList(reviewPrs)

    function markRead(prId) {
        const prefix = prId + ":"
        const keep = unreadKeys.filter(function (k) { return k.indexOf(prefix) !== 0 })
        if (keep.length === unreadKeys.length) return
        if (demoMode) demoUnread = keep
        else root._put(unreadCommentKeys, keep)
    }

    property string lastError: ""
    property bool loading: false
    property string currentTab: defaultTab
    onDefaultTabChanged: currentTab = defaultTab

    // ---- HTTP client ----
    AdoClient {
        id: client
        orgUrl: root.orgUrl
        projects: root.projects
        tokenSource: root.tokenSource
        tokenPath: root.tokenPath
    }

    // ---- Helpers ----

    function myVote(pr) {
        const rs = pr.reviewers || []
        for (let i = 0; i < rs.length; i++)
            if (rs[i].id === root.myId) return rs[i].vote || 0
        return 0
    }

    function voteLabel(v) {
        switch (v) {
            case 10: return "Approved"
            case 5: return "Approved w/ suggestions"
            case -5: return "Waiting for author"
            case -10: return "Rejected"
            default: return "No vote"
        }
    }

    function voteColor(v) {
        if (v >= 5) return "#43a047"
        if (v === -5) return Theme.warning
        if (v === -10) return Theme.error
        return Theme.surfaceVariantText
    }

    // One-chip summary of the reviewers on one of my PRs.
    function reviewSummary(pr) {
        const rs = (pr.reviewers || []).filter(function (r) { return r.id !== root.myId })
        let approved = 0, waiting = 0, rejected = 0
        for (let i = 0; i < rs.length; i++) {
            if (rs[i].vote >= 5) approved++
            else if (rs[i].vote === -5) waiting++
            else if (rs[i].vote === -10) rejected++
        }
        if (rejected) return { text: rejected + " rejected", color: Theme.error }
        if (waiting) return { text: waiting + " waiting", color: Theme.warning }
        if (approved) return { text: approved + "/" + rs.length + " approved", color: "#43a047" }
        if (rs.length === 0) return { text: "No reviewers", color: Theme.surfaceVariantText }
        return { text: "No votes yet", color: Theme.surfaceVariantText }
    }

    function shortRef(ref) { return String(ref || "").replace(/^refs\/heads\//, "") }

    function age(iso) {
        const ms = Date.now() - Date.parse(iso)
        if (!isFinite(ms) || ms < 0) return ""
        const m = Math.floor(ms / 60000)
        if (m < 60) return m + "m"
        const h = Math.floor(m / 60)
        if (h < 48) return h + "h"
        return Math.floor(h / 24) + "d"
    }

    function typeIcon(name) {
        switch ((name || "").toLowerCase()) {
            case "bug": return "bug_report"
            case "task": return "task_alt"
            case "user story":
            case "product backlog item": return "auto_stories"
            case "feature": return "star"
            case "epic": return "flag"
            case "issue":
            case "impediment": return "report"
            case "test case": return "science"
            default: return "label"
        }
    }

    function typeColor(name) {
        switch ((name || "").toLowerCase()) {
            case "bug": return "#e53935"
            case "task": return "#f2c94c"
            case "user story":
            case "product backlog item": return "#42a5f5"
            case "feature": return "#ab47bc"
            case "epic": return "#ff7043"
            default: return Theme.surfaceVariantText
        }
    }

    // Azure DevOps state categories: Proposed, InProgress, Resolved, Completed, Removed.
    function categoryColor(cat) {
        switch (cat) {
            case "InProgress": return Theme.primary
            case "Resolved":   return "#26a69a"
            case "Completed":  return "#43a047"
            case "Removed":    return Theme.error
            default:           return Theme.surfaceVariantText
        }
    }

    // List responses don't carry the state category, so guess from the name
    // for the chip color. Covers Agile, Scrum, Basic and CMMI defaults.
    function stateColor(state) {
        switch ((state || "").toLowerCase()) {
            case "active": case "in progress": case "committed": case "doing":
                return categoryColor("InProgress")
            case "resolved": return categoryColor("Resolved")
            case "done": case "closed": case "completed": return categoryColor("Completed")
            case "removed": return categoryColor("Removed")
            default: return categoryColor("Proposed")
        }
    }

    function priorityColor(p) {
        switch (p) {
            case 1: return Theme.error
            case 2: return "#ff7043"
            case 3: return Theme.warning
            default: return Theme.surfaceVariantText
        }
    }

    function workBranchName(wi) {
        const f = wi.fields || {}
        const slug = (f["System.Title"] || "")
            .toLowerCase()
            .normalize("NFD").replace(/[̀-ͯ]/g, "")
            .replace(/[^a-z0-9]+/g, "-")
            .replace(/^-+|-+$/g, "")
            .substring(0, 50)
            .replace(/-[^-]*$/, function (m) { return m.length < 8 ? m : "" })
        let name = wi.id + "-" + slug
        if (root.branchPrefixByType) {
            const t = (f["System.WorkItemType"] || "").toLowerCase()
            const prefix = t === "bug" ? "bug"
                : (t === "user story" || t === "product backlog item" || t === "feature" || t === "task") ? "feature"
                : "chore"
            name = prefix + "/" + name
        }
        return name
    }

    function copyToClipboard(text) {
        if (!text) return
        Quickshell.execDetached(["dms", "cl", "copy", "--", String(text)])
    }

    function openUrl(url) {
        if (!/^https:\/\//.test(url || "")) {
            console.warn("[dms-azure-devops] refusing to open non-https url", url)
            return
        }
        Qt.openUrlExternally(url)
    }

    function prUrl(pr) {
        if (root.demoMode) return "https://dev.azure.com/contoso/Contoso/_git/" + pr.repository.name + "/pullrequest/" + pr.pullRequestId
        try { return client.pullRequestWebUrl(pr) } catch (e) { return "" }
    }

    function workUrl(wi) {
        if (root.demoMode) return "https://dev.azure.com/contoso/Contoso/_workitems/edit/" + wi.id
        try { return client.workItemWebUrl(wi) } catch (e) { return "" }
    }

    function notify(summary, body) {
        Quickshell.execDetached(
            ["dms", "notify", "-a", "Azure DevOps", "--", String(summary), String(body || "")])
    }

    // ---- Polling ----

    function refresh() {
        if (root.demoMode) { root.lastError = ""; return }
        if (!root.orgUrl) { root.lastError = ""; return }
        if (root.loading) return
        root.loading = true

        // Snapshot previous state *before* overwriting, for notification diffs.
        const prevPollAt = lastPollAt.value || 0
        const prevReview = cachedReview.value || []
        const prevMine = cachedMine.value || []
        const prevWork = cachedWork.value || []

        let pending = 3
        const errors = []
        function done() {
            if (--pending > 0) return
            root.loading = false
            root.lastError = errors.join("\n")
            if (errors.length < 3) root._put(lastPollAt, Date.now())
        }
        function fail(label, err) {
            const msg = (err && err.message) ? err.message : String(err)
            console.warn("[dms-azure-devops]", label, "failed:", msg)
            if (errors.indexOf(msg) < 0) errors.push(msg)
        }

        client.pullRequestsToReview(function (err, list) {
            if (err) fail("review PRs", err)
            else {
                root._put(cachedReview, list)
                if (prevPollAt > 0 && root.notifyReview) root._notifyNewReviews(prevReview, list)
                root._syncComments(list, "review", prevPollAt)
            }
            done()
        })
        client.myPullRequests(function (err, list) {
            if (err) fail("my PRs", err)
            else {
                root._put(cachedMine, list)
                if (prevPollAt > 0 && root.notifyVotes) root._notifyVoteChanges(prevMine, list)
                root._syncComments(list, "mine", prevPollAt)
            }
            done()
        })
        client.assignedWorkItems(root.excludedStates, root.extraWiql, function (err, list) {
            if (err) fail("work items", err)
            else {
                root._put(cachedWork, list)
                if (prevPollAt > 0 && root.notifyAssigned) root._notifyNewWork(prevWork, list)
            }
            done()
        })
    }

    // ---- PR comments ----
    //
    // One threads request per active PR. On "mine" PRs every comment by
    // someone else counts; on "review" PRs only replies in threads you've
    // posted in. The first sync ever only seeds the seen set.

    function _syncComments(prs, mode, sinceMs) {
        if (!prs || prs.length === 0) { root._applyComments([], {}, mode, false, 0); return }
        const seeding = !(sinceMs > 0) || !commentsSeeded.value
        const summaries = {}
        let pending = prs.length
        for (let i = 0; i < prs.length; i++) {
            const pr = prs[i]
            client.pullRequestThreads(pr, function (err, threads) {
                if (err) console.warn("[dms-azure-devops] threads for !" + pr.pullRequestId + " failed:", err.message || err)
                else summaries[pr.pullRequestId] = root._summarizeThreads(pr, threads, mode)
                if (--pending > 0) return
                root._applyComments(prs, summaries, mode, seeding, sinceMs)
            })
        }
    }

    function _summarizeThreads(pr, threads, mode) {
        const all = []
        let active = 0
        for (let i = 0; i < threads.length; i++) {
            const t = threads[i]
            if (!t || t.isDeleted) continue
            // System threads (votes, pushes, policy) only carry system comments.
            const cs = (t.comments || []).filter(function (c) {
                return c && !c.isDeleted && c.commentType !== "system" && (c.content || "").trim()
            })
            if (cs.length === 0) continue
            if (t.status === "active" || t.status === "pending") active++
            const participated = cs.some(function (c) { return c.author && c.author.id === root.myId })
            const filePath = (t.threadContext && t.threadContext.filePath) || ""
            for (let j = 0; j < cs.length; j++) {
                const c = cs[j]
                const isMine = !!(c.author && c.author.id === root.myId)
                all.push({
                    key: pr.pullRequestId + ":" + t.id + ":" + c.id,
                    threadId: t.id,
                    author: isMine ? "You" : ((c.author && c.author.displayName) || "Someone"),
                    isMine: isMine,
                    content: String(c.content).substring(0, 600),
                    date: c.lastUpdatedDate || c.publishedDate || "",
                    published: c.publishedDate || "",
                    filePath: filePath,
                    status: t.status || "",
                    notifiable: !isMine && (mode === "mine" || participated)
                })
            }
        }
        all.sort(function (a, b) { return Date.parse(b.published) - Date.parse(a.published) })
        return { active: active, all: all }
    }

    function _applyComments(prs, summaries, mode, seeding, sinceMs) {
        const seen = {}
        const known = seenCommentKeys.value || []
        for (let i = 0; i < known.length; i++) seen[known[i]] = true
        const freshSeen = []
        const freshUnread = []
        const byPr = {}

        const live = {}
        for (let i = 0; i < prs.length; i++) live[prs[i].pullRequestId] = prs[i]

        // Keep the other mode's entries and any PR whose fetch failed this time.
        const prevCache = cachedThreads.value || {}
        const cache = {}
        for (const id in prevCache) {
            const e = prevCache[id]
            if (e.mode !== mode || (live[id] && !summaries[id])) cache[id] = e
        }

        for (const id in summaries) {
            const s = summaries[id]
            cache[id] = { mode: mode, active: s.active, comments: s.all.slice(0, 12).map(function (c) {
                return { key: c.key, threadId: c.threadId, author: c.author, isMine: c.isMine,
                         content: c.content, date: c.published, filePath: c.filePath, status: c.status }
            }) }
            for (let j = 0; j < s.all.length; j++) {
                const c = s.all[j]
                if (seen[c.key]) continue
                seen[c.key] = true
                freshSeen.push(c.key)
                if (seeding || !c.notifiable) continue
                // Grace window for clock skew; `seen` already prevents repeats.
                if (Date.parse(c.published) < sinceMs - 5 * 60000) continue
                freshUnread.push(c.key)
                ;(byPr[id] = byPr[id] || []).push(c)
            }
        }

        root._put(cachedThreads, cache)
        if (seeding && !commentsSeeded.value) root._put(commentsSeeded, true)
        if (freshSeen.length > 0) {
            let merged = known.concat(freshSeen)
            if (merged.length > 3000) merged = merged.slice(merged.length - 3000)
            root._put(seenCommentKeys, merged)
        }
        if (freshUnread.length > 0) {
            let merged = (unreadCommentKeys.value || []).concat(freshUnread)
            if (merged.length > 500) merged = merged.slice(merged.length - 500)
            root._put(unreadCommentKeys, merged)
        }

        const allowed = mode === "mine" ? root.notifyComments : root.notifyReplies
        if (!allowed) return
        for (const id in byPr) {
            const cs = byPr[id]
            const pr = live[id]
            const title = "!" + id + " · " + ((pr && pr.title) || "")
            if (cs.length === 1) {
                const verb = mode === "mine" ? " commented on " : " replied on "
                root.notify(cs[0].author + verb + "!" + id,
                    root.plainSnippet(cs[0].content, 140) + "\n" + title)
            } else {
                const names = []
                for (let k = 0; k < cs.length; k++)
                    if (names.indexOf(cs[k].author) < 0) names.push(cs[k].author)
                root.notify(cs.length + " new comments on !" + id, names.join(", ") + "\n" + title)
            }
        }
    }

    // Markdown-ish → single-line plain text for previews and notifications.
    function plainSnippet(md, max) {
        let s = String(md || "")
            .replace(/!\[[^\]]*\]\([^)]*\)/g, "[image]")
            .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
            .replace(/```[\s\S]*?```/g, "[code]")
            .replace(/[`*_>#]/g, "")
            .replace(/@<[0-9A-Fa-f-]{36}>/g, "@someone")
            .replace(/\s+/g, " ")
            .trim()
        if (max && s.length > max) s = s.substring(0, max - 1) + "…"
        return s
    }

    // ---- Full discussion view ----
    //
    // Fetched live when opened (the poll cache only keeps a short summary).

    property var detailPr: null
    property var detailThreads: []
    property bool detailLoading: false
    property string detailError: ""
    property var detailUnread: []
    property bool detailShowResolved: true

    function openDiscussion(pr) {
        root.detailUnread = root.unreadKeys.slice()
        root.detailPr = pr
        root.detailThreads = []
        root.markRead(pr.pullRequestId)
        root.loadDiscussion()
    }

    function closeDiscussion() {
        root.detailPr = null
        root.detailThreads = []
        root.detailError = ""
    }

    function loadDiscussion() {
        const pr = root.detailPr
        if (!pr) return
        if (root.demoMode) { root.detailThreads = root._demoDiscussion(pr.pullRequestId); return }
        root.detailLoading = true
        root.detailError = ""
        client.pullRequestThreads(pr, function (err, threads) {
            if (root.detailPr !== pr) return
            root.detailLoading = false
            if (err) { root.detailError = err.message || String(err); return }
            root.detailThreads = root._buildThreads(pr, threads)
        })
    }

    // Raw REST threads → [{ id, status, filePath, line, lastDate, comments: [...] }],
    // most recently active thread first, comments oldest-first within a thread.
    function _buildThreads(pr, threads) {
        const names = {}
        const addName = function (idn) { if (idn && idn.id && idn.displayName) names[idn.id.toLowerCase()] = idn.displayName }
        addName(pr.createdBy)
        ;(pr.reviewers || []).forEach(addName)
        threads.forEach(function (t) { (t.comments || []).forEach(function (c) { addName(c.author) }) })

        const out = []
        for (let i = 0; i < threads.length; i++) {
            const t = threads[i]
            if (!t || t.isDeleted) continue
            const cs = (t.comments || []).filter(function (c) {
                return c && !c.isDeleted && c.commentType !== "system" && (c.content || "").trim()
            })
            if (cs.length === 0) continue
            cs.sort(function (a, b) { return Date.parse(a.publishedDate) - Date.parse(b.publishedDate) })
            const ctx = t.threadContext || {}
            const pos = ctx.rightFileStart || ctx.leftFileStart
            out.push({
                id: t.id,
                status: t.status || "",
                filePath: ctx.filePath || "",
                line: pos && pos.line ? pos.line : 0,
                lastDate: cs[cs.length - 1].publishedDate || "",
                comments: cs.map(function (c) {
                    const isMine = !!(c.author && c.author.id === root.myId)
                    return {
                        key: pr.pullRequestId + ":" + t.id + ":" + c.id,
                        author: isMine ? "You" : ((c.author && c.author.displayName) || "Someone"),
                        isMine: isMine,
                        content: root.prepareMarkdown(c.content, names),
                        date: c.publishedDate || "",
                        edited: !!(c.lastContentUpdatedDate && c.lastContentUpdatedDate !== c.publishedDate
                                   && Date.parse(c.lastContentUpdatedDate) - Date.parse(c.publishedDate) > 60000)
                    }
                })
            })
        }
        out.sort(function (a, b) { return Date.parse(b.lastDate) - Date.parse(a.lastDate) })
        return out
    }

    function _demoDiscussion(prId) {
        const e = root.demoThreads[prId]
        if (!e) return []
        const byThread = {}
        const order = []
        e.comments.forEach(function (c) {
            if (!byThread[c.threadId]) {
                byThread[c.threadId] = { id: c.threadId, status: c.status, filePath: c.filePath,
                    line: c.filePath ? 42 : 0, lastDate: c.date, comments: [] }
                order.push(c.threadId)
            }
            byThread[c.threadId].comments.unshift({ key: c.key, author: c.author, isMine: c.isMine,
                content: c.content, date: c.date, edited: false })
        })
        return order.map(function (id) { return byThread[id] })
    }

    function isOpenStatus(status) { return status === "active" || status === "pending" }

    function statusLabel(status) {
        switch (status) {
            case "active": return "Active"
            case "pending": return "Pending"
            case "fixed": return "Resolved"
            case "wontFix": return "Won't fix"
            case "closed": return "Closed"
            case "byDesign": return "By design"
            default: return status || ""
        }
    }

    // Make ADO comment Markdown safe and readable for Text.MarkdownText:
    // images (which need auth anyway) become placeholders, raw <img> tags are
    // dropped, and @<guid> mentions resolve to names where we know them.
    function prepareMarkdown(md, names) {
        return String(md || "")
            .replace(/!\[([^\]]*)\]\([^)]*\)/g, function (_, alt) { return "*[image" + (alt ? ": " + alt : "") + "]*" })
            .replace(/<img[^>]*>/gi, "*[image]*")
            .replace(/@<([0-9A-Fa-f-]{36})>/g, function (_, id) {
                const n = names && names[id.toLowerCase()]
                return "**@" + (n || "someone") + "**"
            })
    }

    function threadUrl(pr, threadId) {
        const u = root.prUrl(pr)
        return u ? u + "?discussionId=" + threadId : ""
    }

    function _notifyNewReviews(prev, next) {
        const seen = {}
        for (let i = 0; i < prev.length; i++) seen[prev[i].pullRequestId] = true
        for (let i = 0; i < next.length; i++) {
            const pr = next[i]
            if (seen[pr.pullRequestId] || (root.hideDrafts && pr.isDraft)) continue
            root.notify("Review requested: !" + pr.pullRequestId,
                ((pr.createdBy && pr.createdBy.displayName) || "Someone") + " · " + (pr.title || ""))
        }
    }

    function _notifyVoteChanges(prev, next) {
        const prevVotes = {}
        for (let i = 0; i < prev.length; i++) {
            const m = {}
            const rs = prev[i].reviewers || []
            for (let j = 0; j < rs.length; j++) m[rs[j].id] = rs[j].vote || 0
            prevVotes[prev[i].pullRequestId] = m
        }
        for (let i = 0; i < next.length; i++) {
            const pr = next[i]
            const old = prevVotes[pr.pullRequestId]
            if (!old) continue
            const rs = pr.reviewers || []
            for (let j = 0; j < rs.length; j++) {
                const r = rs[j]
                const v = r.vote || 0
                if (r.id === root.myId || v === 0 || old[r.id] === v) continue
                // Skip container identities (team reviewers mirror their members' votes).
                if (r.isContainer) continue
                root.notify((r.displayName || "Someone") + ": " + root.voteLabel(v),
                    "!" + pr.pullRequestId + " · " + (pr.title || ""))
            }
        }
    }

    function _notifyNewWork(prev, next) {
        const seen = {}
        for (let i = 0; i < prev.length; i++) seen[prev[i].id] = true
        for (let i = 0; i < next.length; i++) {
            const wi = next[i]
            if (seen[wi.id]) continue
            const f = wi.fields || {}
            root.notify("Assigned: " + (f["System.WorkItemType"] || "Work item") + " #" + wi.id,
                f["System.Title"] || "")
        }
    }

    Component.onCompleted: Qt.callLater(function () {
        root._hydrate()
        if (root._isPoller()) root.refresh()
    })
    Component.onDestruction: if (pollerId.value === root._instanceId) pollerId.set("")

    Timer {
        interval: Math.max(1, root.pollMinutes) * 60 * 1000
        repeat: true
        running: true
        onTriggered: if (root._isPoller()) root.refresh()
    }

    // Take over polling if the poller instance went away (screen unplugged,
    // plugin reload).
    Timer {
        interval: 30 * 1000
        repeat: true
        running: !root.demoMode
        onTriggered: if (!pollerId.value && root._isPoller()) root.refresh()
    }

    // Debounced refresh when connection/query settings change.
    Timer {
        id: settingsDebounce
        interval: 600
        repeat: false
        onTriggered: if (root._isPoller()) root.refresh()
    }
    onOrgUrlChanged: settingsDebounce.restart()
    onProjectsChanged: settingsDebounce.restart()
    onTokenPathChanged: settingsDebounce.restart()
    onTokenSourceChanged: settingsDebounce.restart()
    onExcludedStatesChanged: settingsDebounce.restart()
    onExtraWiqlChanged: settingsDebounce.restart()

    // Right-click the pill to force a refresh.
    pillRightClickAction: () => root.refresh()

    // ---- Bar pill ----

    readonly property color reviewColor: pendingReviewCount > 0 ? Theme.primary : Theme.surfaceVariantText
    readonly property color workColor: workItems.length > 0 ? Theme.surfaceText : Theme.surfaceVariantText

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingS

            DC.DIcon {
                visible: root.lastError.length > 0 && root.reviewPrs.length === 0 && root.workItems.length === 0
                name: "cloud_off"
                size: Theme.iconSizeSmall
                color: Theme.error
                anchors.verticalCenter: parent.verticalCenter
            }

            Row {
                visible: root.pillMode !== "work"
                spacing: Theme.spacingXS
                anchors.verticalCenter: parent.verticalCenter
                DC.DIcon {
                    name: "merge"
                    size: Theme.iconSizeSmall
                    color: root.reviewColor
                    anchors.verticalCenter: parent.verticalCenter
                }
                StyledText {
                    text: root.pendingReviewCount.toString()
                    color: root.reviewColor
                    font.pixelSize: Theme.fontSizeMedium
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            Row {
                visible: root.showUnreadOnBar && root.unreadCount > 0
                spacing: Theme.spacingXS
                anchors.verticalCenter: parent.verticalCenter
                DC.DIcon {
                    name: "forum"
                    size: Theme.iconSizeSmall
                    color: Theme.primary
                    filled: true
                    anchors.verticalCenter: parent.verticalCenter
                }
                StyledText {
                    text: root.unreadCount.toString()
                    color: Theme.primary
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Bold
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            Row {
                visible: root.pillMode !== "reviews"
                spacing: Theme.spacingXS
                anchors.verticalCenter: parent.verticalCenter
                DC.DIcon {
                    name: "assignment"
                    size: Theme.iconSizeSmall
                    color: root.workColor
                    anchors.verticalCenter: parent.verticalCenter
                }
                StyledText {
                    text: root.workItems.length.toString()
                    color: root.workColor
                    font.pixelSize: Theme.fontSizeMedium
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS

            DC.DIcon {
                visible: root.pillMode !== "work"
                name: "merge"
                size: Theme.iconSizeSmall
                color: root.reviewColor
                anchors.horizontalCenter: parent.horizontalCenter
            }
            StyledText {
                visible: root.pillMode !== "work"
                text: root.pendingReviewCount.toString()
                color: root.reviewColor
                font.pixelSize: Theme.fontSizeSmall
                anchors.horizontalCenter: parent.horizontalCenter
            }
            DC.DIcon {
                visible: root.showUnreadOnBar && root.unreadCount > 0
                name: "forum"
                size: Theme.iconSizeSmall
                color: Theme.primary
                anchors.horizontalCenter: parent.horizontalCenter
            }
            StyledText {
                visible: root.showUnreadOnBar && root.unreadCount > 0
                text: root.unreadCount.toString()
                color: Theme.primary
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Bold
                anchors.horizontalCenter: parent.horizontalCenter
            }
            DC.DIcon {
                visible: root.pillMode !== "reviews"
                name: "assignment"
                size: Theme.iconSizeSmall
                color: root.workColor
                anchors.horizontalCenter: parent.horizontalCenter
            }
            StyledText {
                visible: root.pillMode !== "reviews"
                text: root.workItems.length.toString()
                color: root.workColor
                font.pixelSize: Theme.fontSizeSmall
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    // ---- Shared bits ----

    component StatusChip: Rectangle {
        id: sc
        property string text: ""
        property color accent: Theme.surfaceVariantText
        implicitWidth: scText.implicitWidth + Theme.spacingM * 2
        implicitHeight: scText.implicitHeight + Theme.spacingXS * 2
        radius: height / 2
        color: Qt.rgba(accent.r, accent.g, accent.b, 0.15)
        border.color: Qt.rgba(accent.r, accent.g, accent.b, 0.45)
        border.width: 1
        StyledText {
            id: scText
            anchors.centerIn: parent
            text: sc.text
            color: sc.accent
            font.pixelSize: Theme.fontSizeSmall
            font.weight: Font.Medium
        }
    }

    component ActionChip: Rectangle {
        id: chip
        property string icon: ""
        property string label: ""
        property bool highlighted: false
        property color accent: Theme.primary
        property bool tinted: false
        signal triggered()

        implicitWidth: chipRow.implicitWidth + Theme.spacingM * 2
        implicitHeight: chipRow.implicitHeight + Theme.spacingXS * 2
        radius: height / 2
        color: chip.highlighted
            ? chip.accent
            : chip.tinted
                ? Qt.rgba(chip.accent.r, chip.accent.g, chip.accent.b, chipMouse.containsMouse ? 0.25 : 0.12)
                : (chipMouse.containsMouse ? Qt.rgba(0, 0, 0, 0.06) : Theme.surface)
        border.color: chip.highlighted || chip.tinted
            ? Qt.rgba(chip.accent.r, chip.accent.g, chip.accent.b, 0.6)
            : Qt.rgba(0, 0, 0, 0.15)
        border.width: 1

        Row {
            id: chipRow
            anchors.centerIn: parent
            spacing: Theme.spacingXS

            DC.DIcon {
                visible: chip.icon.length > 0
                name: chip.icon
                size: Theme.iconSizeSmall
                color: chip.highlighted ? Theme.onPrimary : chip.tinted ? chip.accent : Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }
            StyledText {
                text: chip.label
                color: chip.highlighted ? Theme.onPrimary : chip.tinted ? chip.accent : Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        MouseArea {
            id: chipMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: chip.triggered()
        }
    }

    // Comment composer used by both PR and work item rows.
    component Composer: Column {
        id: comp
        property bool sending: false
        property string error: ""
        property string placeholder: "Add a comment…"
        signal submit(string text)
        signal cancel()
        function clear() { area.text = "" }

        spacing: Theme.spacingXS

        Rectangle {
            width: parent.width
            height: Math.max(60, area.implicitHeight + Theme.spacingS * 2)
            radius: Theme.cornerRadius
            color: Theme.surface
            border.color: area.activeFocus ? Theme.primary : Qt.rgba(0, 0, 0, 0.12)
            border.width: 1

            TextArea {
                id: area
                anchors.fill: parent
                anchors.margins: Theme.spacingS
                placeholderText: comp.placeholder
                color: Theme.surfaceText
                placeholderTextColor: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
                wrapMode: Text.WordWrap
                background: null
                enabled: !comp.sending
            }
        }

        StyledText {
            visible: comp.error.length > 0
            text: comp.error
            color: Theme.error
            font.pixelSize: Theme.fontSizeSmall
            wrapMode: Text.WordWrap
            width: parent.width
        }

        Row {
            spacing: Theme.spacingS
            anchors.right: parent.right
            ActionChip {
                icon: "close"
                label: "Cancel"
                onTriggered: { area.text = ""; comp.cancel() }
            }
            ActionChip {
                icon: comp.sending ? "hourglass_top" : "send"
                label: comp.sending ? "Sending…" : "Send"
                highlighted: true
                onTriggered: if (area.text.trim() && !comp.sending) comp.submit(area.text)
            }
        }
    }

    // Base for expandable rows: hover tint, left-click opens, right-click expands.
    component RowFrame: Rectangle {
        id: frame
        property bool expanded: false
        property real rowWidth: 0
        property string url: ""
        default property alias content: inner.data
        signal collapsed()
        signal opened()

        width: rowWidth
        height: inner.implicitHeight + Theme.spacingM * 2
        radius: Theme.cornerRadius
        color: frame.expanded
            ? Theme.surfaceContainerHigh
            : (frameMouse.containsMouse ? Qt.rgba(0, 0, 0, 0.04) : "transparent")
        Behavior on height { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

        Column {
            id: inner
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingXS
        }

        MouseArea {
            id: frameMouse
            anchors.fill: parent
            z: -1
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: Qt.PointingHandCursor
            onClicked: (mouse) => {
                if (mouse.button === Qt.RightButton) {
                    frame.expanded = !frame.expanded
                    if (!frame.expanded) frame.collapsed()
                } else if (!frame.expanded) {
                    root.openUrl(frame.url)
                    frame.opened()
                }
            }
        }
    }

    // One thread in the discussion view: header (file / status) + every comment.
    component ThreadCard: Rectangle {
        id: tc
        property var thread
        readonly property bool open: root.isOpenStatus(thread ? thread.status : "")

        height: tcCol.implicitHeight + Theme.spacingM * 2
        radius: Theme.cornerRadius
        color: Qt.rgba(0, 0, 0, tc.open ? 0.05 : 0.025)
        border.width: 1
        border.color: tc.open ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.35) : Qt.rgba(0, 0, 0, 0.08)

        Column {
            id: tcCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingS

            Item {
                width: parent.width
                height: Math.max(tcHead.implicitHeight, tcChip.implicitHeight)

                Row {
                    id: tcHead
                    anchors.left: parent.left
                    anchors.right: tcChip.left
                    anchors.rightMargin: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spacingXS
                    DC.DIcon {
                        name: tc.thread && tc.thread.filePath ? "description" : "forum"
                        size: Theme.iconSizeSmall - 2
                        color: Theme.surfaceVariantText
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    StyledText {
                        width: parent.width - Theme.iconSizeSmall
                        textFormat: Text.PlainText
                        elide: Text.ElideMiddle
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        anchors.verticalCenter: parent.verticalCenter
                        text: !tc.thread ? "" : tc.thread.filePath
                            ? tc.thread.filePath.replace(/^\//, "") + (tc.thread.line ? ":" + tc.thread.line : "")
                            : "General comment"
                    }
                }

                StatusChip {
                    id: tcChip
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.statusLabel(tc.thread ? tc.thread.status : "")
                    accent: tc.open ? Theme.primary : "#43a047"
                }
            }

            Repeater {
                model: tc.thread ? tc.thread.comments : []
                delegate: Item {
                    id: cm
                    required property var modelData
                    required property int index
                    readonly property bool isNew: root.detailUnread.indexOf(modelData.key) >= 0
                    width: tcCol.width
                    height: cmCol.implicitHeight

                    Rectangle {
                        visible: cm.isNew
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: -Theme.spacingS
                        width: 3
                        radius: 1.5
                        color: Theme.primary
                    }

                    Column {
                        id: cmCol
                        width: parent.width
                        // Replies are indented under the thread's first comment.
                        leftPadding: cm.index > 0 ? Theme.spacingM : 0
                        spacing: 2

                        Row {
                            spacing: Theme.spacingXS
                            StyledText {
                                text: cm.modelData.author
                                textFormat: Text.PlainText
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Bold
                                color: cm.modelData.isMine ? Theme.primary : Theme.surfaceText
                            }
                            StyledText {
                                text: "· " + root.age(cm.modelData.date) + " ago"
                                    + (cm.modelData.edited ? " · edited" : "")
                                    + (cm.isNew ? " · new" : "")
                                textFormat: Text.PlainText
                                font.pixelSize: Theme.fontSizeSmall
                                color: cm.isNew ? Theme.primary : Theme.surfaceVariantText
                            }
                        }

                        Text {
                            width: cmCol.width - cmCol.leftPadding
                            text: cm.modelData.content
                            textFormat: Text.MarkdownText
                            wrapMode: Text.Wrap
                            color: Theme.surfaceText
                            linkColor: Theme.primary
                            font.pixelSize: Theme.fontSizeSmall
                            font.family: Theme.fontFamily
                            onLinkActivated: (link) => root.openUrl(link)
                            HoverHandler {
                                enabled: parent.hoveredLink.length > 0
                                cursorShape: Qt.PointingHandCursor
                            }
                        }
                    }
                }
            }

            ActionChip {
                icon: "open_in_new"
                label: "Open thread"
                onTriggered: root.openUrl(root.threadUrl(root.detailPr, tc.thread.id))
            }
        }
    }

    component DiscussionView: Column {
        id: dv
        spacing: Theme.spacingS

        readonly property var pr: root.detailPr
        readonly property var visibleThreads: root.detailShowResolved
            ? root.detailThreads
            : root.detailThreads.filter(function (t) { return root.isOpenStatus(t.status) })
        readonly property int openCount: root.detailThreads.filter(function (t) { return root.isOpenStatus(t.status) }).length
        readonly property int commentCount: {
            let n = 0
            for (let i = 0; i < root.detailThreads.length; i++) n += root.detailThreads[i].comments.length
            return n
        }

        Item {
            width: parent.width
            height: dvTop.implicitHeight

            Row {
                id: dvTop
                spacing: Theme.spacingS
                ActionChip {
                    icon: "arrow_back"; label: "Back"
                    onTriggered: root.closeDiscussion()
                }
                ActionChip {
                    icon: root.detailShowResolved ? "visibility" : "visibility_off"
                    label: root.detailShowResolved ? "All threads" : "Open only"
                    onTriggered: root.detailShowResolved = !root.detailShowResolved
                }
            }
            Row {
                anchors.right: parent.right
                spacing: Theme.spacingS
                ActionChip {
                    icon: "open_in_new"; label: "Open PR"
                    onTriggered: root.openUrl(root.prUrl(dv.pr))
                }
                ActionChip {
                    icon: root.detailLoading ? "hourglass_top" : "refresh"; label: ""
                    onTriggered: root.loadDiscussion()
                }
            }
        }

        StyledText {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Bold
            color: Theme.surfaceText
            text: dv.pr ? "!" + dv.pr.pullRequestId + " · " + (dv.pr.title || "") : ""
        }

        StyledText {
            width: parent.width
            font.pixelSize: Theme.fontSizeSmall
            color: root.detailError ? Theme.error : Theme.surfaceVariantText
            wrapMode: Text.WordWrap
            text: root.detailError ? "⚠ " + root.detailError
                : root.detailLoading && root.detailThreads.length === 0 ? "Loading comments…"
                : dv.commentCount + " comments in " + root.detailThreads.length + " threads · "
                  + dv.openCount + " open"
        }

        Flickable {
            width: parent.width
            height: Math.min(500, dvList.implicitHeight)
            contentHeight: dvList.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            Column {
                id: dvList
                width: parent.width - Theme.spacingS
                spacing: Theme.spacingS

                Repeater {
                    model: dv.visibleThreads
                    delegate: ThreadCard {
                        required property var modelData
                        thread: modelData
                        width: dvList.width
                    }
                }

                StyledText {
                    visible: !root.detailLoading && !root.detailError && dv.visibleThreads.length === 0
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    topPadding: Theme.spacingL
                    bottomPadding: Theme.spacingL
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                    text: root.detailThreads.length === 0 ? "No comments on this PR yet." : "No open threads."
                }
            }
        }
    }

    // ---- Pull request row ----

    component PrRow: RowFrame {
        id: prow
        required property var pr
        property bool reviewMode: true

        readonly property int vote: root.myVote(pr)
        readonly property var summary: root.reviewSummary(pr)
        readonly property var threads: root.threadsByPr[pr.pullRequestId] || null
        readonly property var comments: (threads && threads.comments) || []
        readonly property int activeThreads: (threads && threads.active) || 0
        readonly property int unread: root.unreadFor(pr.pullRequestId)
        readonly property var latestUnread: {
            const keys = root.unreadKeys
            for (let i = 0; i < comments.length; i++)
                if (keys.indexOf(comments[i].key) >= 0) return comments[i]
            return null
        }
        property bool votesOpen: false
        property bool composerOpen: false
        property bool busy: false
        property string actionError: ""

        url: root.prUrl(pr)
        onCollapsed: { votesOpen = false; composerOpen = false; actionError = "" }
        onOpened: root.markRead(pr.pullRequestId)

        function castVote(v) {
            if (root.demoMode) { prow.votesOpen = false; prow.expanded = false; return }
            prow.busy = true
            prow.actionError = ""
            client.votePullRequest(prow.pr, v, function (err) {
                prow.busy = false
                if (err) { prow.actionError = err.message || String(err); return }
                prow.votesOpen = false
                prow.expanded = false
                root.refresh()
            })
        }

        function sendComment(text) {
            if (root.demoMode) { composer.clear(); prow.composerOpen = false; prow.expanded = false; return }
            composer.sending = true
            composer.error = ""
            client.commentPullRequest(prow.pr, text, function (err) {
                composer.sending = false
                if (err) { composer.error = err.message || String(err); return }
                composer.clear()
                prow.composerOpen = false
                prow.expanded = false
                root.refresh()
            })
        }

        // Header: id + repo, status chip on the right.
        Item {
            width: parent.width
            height: Math.max(prHead.implicitHeight, prChip.implicitHeight)

            Row {
                id: prHead
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingS
                DC.DIcon {
                    name: prow.pr.isDraft ? "edit_note" : "merge"
                    size: Theme.iconSizeSmall
                    color: Theme.surfaceVariantText
                    anchors.verticalCenter: parent.verticalCenter
                }
                StyledText {
                    text: "!" + prow.pr.pullRequestId
                    color: Theme.surfaceText
                    font.weight: Font.Bold
                    font.pixelSize: Theme.fontSizeMedium
                    anchors.verticalCenter: parent.verticalCenter
                }
                StyledText {
                    text: (prow.pr.repository && prow.pr.repository.name) || ""
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                    anchors.verticalCenter: parent.verticalCenter
                }
                Row {
                    visible: prow.activeThreads > 0 || prow.unread > 0
                    spacing: 2
                    anchors.verticalCenter: parent.verticalCenter
                    DC.DIcon {
                        name: "forum"
                        size: Theme.iconSizeSmall - 2
                        filled: prow.unread > 0
                        color: prow.unread > 0 ? Theme.primary : Theme.surfaceVariantText
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    StyledText {
                        text: prow.unread > 0 ? prow.unread + " new" : prow.activeThreads.toString()
                        color: prow.unread > 0 ? Theme.primary : Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: prow.unread > 0 ? Font.Bold : Font.Normal
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }

            StatusChip {
                id: prChip
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: prow.pr.isDraft ? "Draft"
                    : prow.reviewMode ? root.voteLabel(prow.vote) : prow.summary.text
                accent: prow.pr.isDraft ? Theme.surfaceVariantText
                    : prow.reviewMode ? root.voteColor(prow.vote) : prow.summary.color
            }
        }

        StyledText {
            text: prow.pr.title || ""
            textFormat: Text.PlainText
            color: Theme.surfaceText
            font.pixelSize: Theme.fontSizeSmall
            width: parent.width
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
        }

        StyledText {
            width: parent.width
            elide: Text.ElideRight
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
            text: (prow.reviewMode ? ((prow.pr.createdBy && prow.pr.createdBy.displayName) || "") + " · " : "")
                + root.shortRef(prow.pr.sourceRefName) + " → " + root.shortRef(prow.pr.targetRefName)
                + " · " + root.age(prow.pr.creationDate)
        }

        // Newest unread comment, visible without expanding.
        Rectangle {
            visible: !!prow.latestUnread
            width: parent.width
            height: previewText.implicitHeight + Theme.spacingXS * 2
            radius: Theme.cornerRadius / 2
            color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.08)
            StyledText {
                id: previewText
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingS
                anchors.rightMargin: Theme.spacingS
                textFormat: Text.PlainText
                elide: Text.ElideRight
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
                text: prow.latestUnread
                    ? prow.latestUnread.author + ": " + root.plainSnippet(prow.latestUnread.content, 160)
                    : ""
            }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openDiscussion(prow.pr)
            }
        }

        // Expanded actions.
        Column {
            visible: prow.expanded
            width: parent.width
            spacing: Theme.spacingS
            topPadding: Theme.spacingXS

            Rectangle { width: parent.width; height: 1; color: Qt.rgba(0, 0, 0, 0.08) }

            Flow {
                width: parent.width
                spacing: Theme.spacingS
                ActionChip {
                    icon: "open_in_new"; label: "Open"
                    onTriggered: {
                        root.openUrl(prow.url); root.markRead(prow.pr.pullRequestId)
                        prow.expanded = false; prow.collapsed()
                    }
                }
                ActionChip {
                    icon: "link"; label: "Copy link"
                    onTriggered: { root.copyToClipboard(prow.url); prow.expanded = false; prow.collapsed() }
                }
                ActionChip {
                    icon: "alt_route"; label: "Copy branch"
                    onTriggered: {
                        root.copyToClipboard(root.shortRef(prow.pr.sourceRefName))
                        prow.expanded = false; prow.collapsed()
                    }
                }
                ActionChip {
                    icon: "forum"
                    label: "Discussion" + (prow.comments.length > 0 ? " (" + prow.activeThreads + " open)" : "")
                    onTriggered: { prow.expanded = false; prow.collapsed(); root.openDiscussion(prow.pr) }
                }
                ActionChip {
                    visible: prow.reviewMode
                    icon: "how_to_vote"; label: "Vote"
                    highlighted: prow.votesOpen
                    onTriggered: { prow.votesOpen = !prow.votesOpen; prow.composerOpen = false }
                }
                ActionChip {
                    icon: "comment"; label: "Comment"
                    highlighted: prow.composerOpen
                    onTriggered: { prow.composerOpen = !prow.composerOpen; prow.votesOpen = false }
                }
            }

            Flow {
                visible: prow.votesOpen
                width: parent.width
                spacing: Theme.spacingS
                Repeater {
                    model: [10, 5, -5, -10, 0]
                    delegate: ActionChip {
                        required property var modelData
                        tinted: true
                        accent: root.voteColor(modelData)
                        icon: modelData >= 5 ? "check_circle" : modelData === -5 ? "schedule"
                            : modelData === -10 ? "cancel" : "restart_alt"
                        label: modelData === 0 ? "Reset vote" : root.voteLabel(modelData)
                        highlighted: prow.vote === modelData && modelData !== 0
                        onTriggered: if (!prow.busy) prow.castVote(modelData)
                    }
                }
            }

            StyledText {
                visible: prow.actionError.length > 0 || prow.busy
                text: prow.busy ? "Working…" : prow.actionError
                color: prow.busy ? Theme.surfaceVariantText : Theme.error
                font.pixelSize: Theme.fontSizeSmall
                wrapMode: Text.WordWrap
                width: parent.width
            }

            Composer {
                id: composer
                visible: prow.composerOpen
                width: parent.width
                placeholder: "Comment on !" + prow.pr.pullRequestId + " (Markdown)…"
                onSubmit: (text) => prow.sendComment(text)
                onCancel: prow.composerOpen = false
            }
        }
    }

    // ---- Work item row ----

    component WorkRow: RowFrame {
        id: wrow
        required property var wi
        readonly property var f: wi.fields || ({})
        readonly property string type: f["System.WorkItemType"] || ""
        readonly property string state: f["System.State"] || ""
        readonly property string project: f["System.TeamProject"] || ""

        property bool statesOpen: false
        property bool composerOpen: false
        property var states: []
        property bool statesLoading: false
        property string actionError: ""

        url: root.workUrl(wi)
        onCollapsed: { statesOpen = false; composerOpen = false; actionError = "" }

        function loadStates() {
            if (states.length > 0 || statesLoading) return
            if (root.demoMode) { states = root.demoStates; return }
            statesLoading = true
            actionError = ""
            client.workItemStates(project, type, function (err, list) {
                wrow.statesLoading = false
                if (err) { wrow.actionError = err.message || String(err); return }
                wrow.states = list.filter(function (s) { return s.category !== "Removed" })
            })
        }

        function setState(name) {
            if (root.demoMode) { statesOpen = false; expanded = false; return }
            statesLoading = true
            actionError = ""
            client.setWorkItemState(wi.id, name, function (err) {
                wrow.statesLoading = false
                if (err) { wrow.actionError = err.message || String(err); return }
                wrow.statesOpen = false
                wrow.expanded = false
                root.refresh()
            })
        }

        function sendComment(text) {
            if (root.demoMode) { wcomposer.clear(); composerOpen = false; expanded = false; return }
            wcomposer.sending = true
            wcomposer.error = ""
            client.commentWorkItem(project, wi.id, text, function (err) {
                wcomposer.sending = false
                if (err) { wcomposer.error = err.message || String(err); return }
                wcomposer.clear()
                wrow.composerOpen = false
                wrow.expanded = false
            })
        }

        Item {
            width: parent.width
            height: Math.max(wHead.implicitHeight, wChip.implicitHeight)

            Row {
                id: wHead
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingS
                Rectangle {
                    width: 8; height: 8; radius: 4
                    color: root.priorityColor(wrow.f["Microsoft.VSTS.Common.Priority"])
                    anchors.verticalCenter: parent.verticalCenter
                }
                DC.DIcon {
                    name: root.typeIcon(wrow.type)
                    size: Theme.iconSizeSmall
                    color: root.typeColor(wrow.type)
                    anchors.verticalCenter: parent.verticalCenter
                }
                StyledText {
                    text: "#" + wrow.wi.id
                    color: Theme.surfaceText
                    font.weight: Font.Bold
                    font.pixelSize: Theme.fontSizeMedium
                    anchors.verticalCenter: parent.verticalCenter
                }
                StyledText {
                    text: wrow.project + " · " + root.age(wrow.f["System.ChangedDate"])
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            StatusChip {
                id: wChip
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: wrow.state
                accent: root.stateColor(wrow.state)
            }
        }

        StyledText {
            text: wrow.f["System.Title"] || ""
            color: Theme.surfaceText
            font.pixelSize: Theme.fontSizeSmall
            width: parent.width
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
        }

        Column {
            visible: wrow.expanded
            width: parent.width
            spacing: Theme.spacingS
            topPadding: Theme.spacingXS

            Rectangle { width: parent.width; height: 1; color: Qt.rgba(0, 0, 0, 0.08) }

            Flow {
                width: parent.width
                spacing: Theme.spacingS
                ActionChip {
                    icon: "open_in_new"; label: "Open"
                    onTriggered: { root.openUrl(wrow.url); wrow.expanded = false; wrow.collapsed() }
                }
                ActionChip {
                    icon: "tag"; label: "Copy ID"
                    onTriggered: { root.copyToClipboard("#" + wrow.wi.id); wrow.expanded = false; wrow.collapsed() }
                }
                ActionChip {
                    icon: "alt_route"; label: "Copy branch"
                    onTriggered: { root.copyToClipboard(root.workBranchName(wrow.wi)); wrow.expanded = false; wrow.collapsed() }
                }
                ActionChip {
                    icon: "sync_alt"; label: "State"
                    highlighted: wrow.statesOpen
                    onTriggered: {
                        wrow.statesOpen = !wrow.statesOpen
                        wrow.composerOpen = false
                        if (wrow.statesOpen) wrow.loadStates()
                    }
                }
                ActionChip {
                    icon: "comment"; label: "Comment"
                    highlighted: wrow.composerOpen
                    onTriggered: { wrow.composerOpen = !wrow.composerOpen; wrow.statesOpen = false }
                }
            }

            StyledText {
                visible: wrow.statesLoading || wrow.actionError.length > 0
                text: wrow.statesLoading ? "Working…" : wrow.actionError
                color: wrow.statesLoading ? Theme.surfaceVariantText : Theme.error
                font.pixelSize: Theme.fontSizeSmall
                wrapMode: Text.WordWrap
                width: parent.width
            }

            Flow {
                visible: wrow.statesOpen && !wrow.statesLoading && wrow.states.length > 0
                width: parent.width
                spacing: Theme.spacingS
                Repeater {
                    model: wrow.states
                    delegate: ActionChip {
                        required property var modelData
                        tinted: true
                        accent: root.categoryColor(modelData.category)
                        label: modelData.name
                        highlighted: modelData.name === wrow.state
                        onTriggered: if (modelData.name !== wrow.state) wrow.setState(modelData.name)
                    }
                }
            }

            Composer {
                id: wcomposer
                visible: wrow.composerOpen
                width: parent.width
                placeholder: "Comment on #" + wrow.wi.id + "…"
                onSubmit: (text) => wrow.sendComment(text)
                onCancel: wrow.composerOpen = false
            }
        }
    }

    // ---- Popout ----

    popoutContent: Component {
        FocusScope {
            id: contentFocusScope
            width: parent ? parent.width : 0
            implicitHeight: mainContent.implicitHeight
            focus: true

            // PluginPopout assigns these on the loaded root.
            property var closePopout: null
            property var parentPopout: null

            PopoutComponent {
                id: mainContent
                width: parent.width
                closePopout: contentFocusScope.closePopout
                headerText: "Azure DevOps"
                detailsText: {
                    if (!root.configured) return "Not configured"
                    if (root.loading) return "Refreshing…"
                    const t = lastPollAt.value
                    if (root.demoMode) return "Demo mode"
                    return t ? "Updated " + root.age(new Date(t).toISOString()) + " ago" : ""
                }
                showCloseButton: true

                DiscussionView {
                    visible: !!root.detailPr
                    width: parent.width
                }

                // Tabs + refresh.
                Item {
                    visible: !root.detailPr
                    width: parent.width
                    height: tabRow.implicitHeight + Theme.spacingS

                    Row {
                        id: tabRow
                        spacing: Theme.spacingS
                        anchors.left: parent.left
                        ActionChip {
                            icon: "rate_review"
                            label: "To review (" + root.reviewPrs.length + ")"
                                + (root.unreadForList(root.reviewPrs) > 0 ? " •" : "")
                            highlighted: root.currentTab === "review"
                            onTriggered: root.currentTab = "review"
                        }
                        ActionChip {
                            icon: "merge"
                            label: "My PRs (" + root.myPrs.length + ")"
                                + (root.unreadForList(root.myPrs) > 0 ? " •" : "")
                            highlighted: root.currentTab === "mine"
                            onTriggered: root.currentTab = "mine"
                        }
                        ActionChip {
                            icon: "assignment"
                            label: "Work (" + root.workItems.length + ")"
                            highlighted: root.currentTab === "work"
                            onTriggered: root.currentTab = "work"
                        }
                    }

                    ActionChip {
                        anchors.right: parent.right
                        icon: root.loading ? "hourglass_top" : "refresh"
                        label: ""
                        onTriggered: root.refresh()
                    }
                }

                StyledText {
                    visible: root.lastError.length > 0 && !root.detailPr
                    width: parent.width
                    text: "⚠ " + root.lastError
                    color: Theme.error
                    font.pixelSize: Theme.fontSizeSmall
                    wrapMode: Text.WordWrap
                }

                Flickable {
                    visible: !root.detailPr
                    width: parent.width
                    height: Math.min(520, listCol.implicitHeight)
                    contentHeight: listCol.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    Column {
                        id: listCol
                        width: parent.width
                        spacing: Theme.spacingXS

                        Repeater {
                            model: root.currentTab === "review" ? root.reviewPrs : []
                            delegate: PrRow {
                                required property var modelData
                                pr: modelData
                                reviewMode: true
                                rowWidth: listCol.width
                            }
                        }

                        Repeater {
                            model: root.currentTab === "mine" ? root.myPrs : []
                            delegate: PrRow {
                                required property var modelData
                                pr: modelData
                                reviewMode: false
                                rowWidth: listCol.width
                            }
                        }

                        Repeater {
                            model: root.currentTab === "work" ? root.workItems : []
                            delegate: WorkRow {
                                required property var modelData
                                wi: modelData
                                rowWidth: listCol.width
                            }
                        }

                        StyledText {
                            readonly property int count: root.currentTab === "review" ? root.reviewPrs.length
                                : root.currentTab === "mine" ? root.myPrs.length : root.workItems.length
                            visible: count === 0
                            width: parent.width
                            topPadding: Theme.spacingL
                            bottomPadding: Theme.spacingL
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.WordWrap
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeSmall
                            text: !root.configured
                                ? "Open Settings → Plugins → Azure DevOps to configure."
                                : root.currentTab === "review" ? "Nothing waiting on your review 🎉"
                                : root.currentTab === "mine" ? "You have no active pull requests."
                                : "No open work items assigned to you."
                        }

                        StyledText {
                            width: parent.width
                            visible: root.configured
                            horizontalAlignment: Text.AlignHCenter
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeSmall
                            opacity: 0.7
                            topPadding: Theme.spacingXS
                            text: "Click to open · right-click for actions"
                        }
                    }
                }
            }
        }
    }
    popoutWidth: 520
    popoutHeight: 640
}
