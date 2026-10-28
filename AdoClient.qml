import QtQuick
import Quickshell
import Quickshell.Io

// REST wrapper around Azure DevOps Services (dev.azure.com) and Azure DevOps
// Server. Auth is HTTP Basic with an empty username and a Personal Access
// Token as the password.
//
// Callbacks follow node-style: (err, result). err is null on success.
QtObject {
    id: root

    // e.g. https://dev.azure.com/my-org  or  https://tfs.corp.local/tfs/DefaultCollection
    property string orgUrl: ""
    // Optional comma-separated project filter. Empty = whole organization.
    property string projects: ""
    property string tokenSource: "file"
    property string tokenPath: ""
    property string apiVersion: "7.1"

    // ---- Token handling (same approach as dms-jira) ----
    // Read the PAT by shelling out (`cat` or `secret-tool`) because Qt blocks
    // XHR reads of file:// URLs by default. Cached per token-source config.
    property string _token: ""
    property string _tokenCachedFor: ""
    property string _tokenCacheKeyPending: ""
    property var _pendingTokenCbs: []

    // Resolved lazily from /_apis/connectionData; needed for reviewer and
    // creator filters and to cast votes.
    property string userId: ""
    property string userName: ""

    onTokenPathChanged:   _resetAuth()
    onTokenSourceChanged: _resetAuth()
    onOrgUrlChanged:      _resetAuth()

    function _resetAuth() {
        _token = ""
        _tokenCachedFor = ""
        userId = ""
        userName = ""
    }

    property var _tokenProcess: Process {
        command: ["true"]
        stdout: StdioCollector {
            onStreamFinished: {
                root._token = (this.text || "").trim()
                root._tokenCachedFor = root._tokenCacheKeyPending
                const cbs = root._pendingTokenCbs
                root._pendingTokenCbs = []
                const fromLibsecret =
                    root._tokenCacheKeyPending.indexOf("libsecret:") === 0
                const emptyMsg = fromLibsecret
                    ? "no PAT in keyring — store one with: " +
                      "secret-tool store --label='dms-azure-devops' service dms-azure-devops account " +
                      (root._orgName() || "<org>")
                    : "token file is empty or unreadable: " + root.tokenPath
                for (let i = 0; i < cbs.length; i++) {
                    if (!root._token) cbs[i](new Error(emptyMsg))
                    else cbs[i](null, root._token)
                }
            }
        }
    }

    function _orgName() {
        const u = (orgUrl || "").trim()
        const m = /^https:\/\/[^/]+\/([^/?#]+)/.exec(u)
        if (m) return decodeURIComponent(m[1])
        const h = /^https:\/\/([^./]+)\.visualstudio\.com/.exec(u)
        return h ? h[1] : ""
    }

    function base() {
        // Require HTTPS to protect the PAT in transit. Strip trailing slashes
        // so we can safely concatenate paths.
        const s = (orgUrl || "").trim().replace(/\/+$/, "")
        if (!/^https:\/\/[^\s/]+(\/[^\s]*)?$/.test(s))
            throw new Error("Organization URL must look like https://dev.azure.com/<org> — got " + (s || "(empty)"))
        return s
    }

    function projectList() {
        return (projects || "").split(",")
            .map(function (p) { return p.trim() })
            .filter(function (p) { return p.length > 0 })
    }

    function _readToken(cb) {
        let cacheKey, cmd
        if (tokenSource === "libsecret") {
            const org = _orgName()
            if (!org) return cb(new Error("organization URL required for libsecret token source"))
            cacheKey = "libsecret:" + org
            cmd = ["secret-tool", "lookup", "service", "dms-azure-devops", "account", org]
        } else {
            if (!tokenPath) return cb(new Error("token file path not set"))
            if (tokenPath.charAt(0) !== "/")
                return cb(new Error("token path must be absolute: " + tokenPath))
            cacheKey = "file:" + tokenPath
            cmd = ["cat", tokenPath]
        }
        if (_token && _tokenCachedFor === cacheKey) return cb(null, _token)
        _pendingTokenCbs.push(cb)
        if (!_tokenProcess.running) {
            _tokenCacheKeyPending = cacheKey
            _tokenProcess.command = cmd
            _tokenProcess.running = true
        }
    }

    function _withVersion(path) {
        return path + (path.indexOf("?") >= 0 ? "&" : "?") + "api-version=" + apiVersion
    }

    // `path` is appended to the org URL. `contentType` defaults to JSON;
    // work item updates need application/json-patch+json.
    function _request(method, path, body, cb, contentType) {
        let b
        try { b = base() } catch (e) { return cb(e) }
        _readToken(function (err, token) {
            if (err) return cb(err)
            const xhr = new XMLHttpRequest()
            xhr.open(method, b + path)
            xhr.setRequestHeader("Accept", "application/json")
            if (body !== null && body !== undefined)
                xhr.setRequestHeader("Content-Type", contentType || "application/json")
            xhr.setRequestHeader("Authorization", "Basic " + Qt.btoa(":" + token))
            xhr.onreadystatechange = function () {
                if (xhr.readyState !== XMLHttpRequest.DONE) return
                if (xhr.status >= 200 && xhr.status < 300) {
                    try { cb(null, xhr.responseText ? JSON.parse(xhr.responseText) : null) }
                    catch (e) {
                        // A 203 with an HTML sign-in page means the PAT was rejected.
                        cb(new Error("unexpected non-JSON response (PAT expired or lacks scope?)"))
                    }
                } else if (xhr.status === 401 || xhr.status === 203) {
                    cb(new Error("HTTP " + xhr.status + ": PAT rejected — check it hasn't expired and has the right scopes"))
                } else {
                    let msg = xhr.responseText || ""
                    try { msg = JSON.parse(msg).message || msg } catch (e) {}
                    cb(new Error("HTTP " + xhr.status + (msg ? ": " + msg : "")))
                }
            }
            xhr.send(body !== null && body !== undefined ? JSON.stringify(body) : null)
        })
    }

    function _seg(s) { return encodeURIComponent(String(s)) }

    function _validId(n) { return /^[1-9][0-9]{0,9}$/.test(String(n)) }
    function _validGuid(g) { return /^[0-9a-fA-F-]{36}$/.test(String(g)) }

    // ---- Identity ----

    function me(cb) {
        if (userId) return cb(null, { id: userId, displayName: userName })
        _request("GET", "/_apis/connectionData", null, function (err, body) {
            if (err) return cb(err)
            const u = (body && body.authenticatedUser) || {}
            root.userId = u.id || ""
            root.userName = u.providerDisplayName || u.customDisplayName || ""
            if (!root.userId) return cb(new Error("could not resolve current user"))
            cb(null, { id: root.userId, displayName: root.userName })
        })
    }

    // ---- Pull requests ----

    // Runs `criteria` (a query string fragment) against either the whole org
    // or each configured project, and merges the results.
    function _listPullRequests(criteria, cb) {
        const projs = projectList()
        const scopes = projs.length > 0
            ? projs.map(function (p) { return "/" + root._seg(p) })
            : [""]
        let pending = scopes.length
        let all = []
        let firstErr = null
        for (let i = 0; i < scopes.length; i++) {
            _request("GET", _withVersion(scopes[i] + "/_apis/git/pullrequests?" +
                criteria + "&searchCriteria.status=active&$top=100"), null,
                function (err, body) {
                    if (err && !firstErr) firstErr = err
                    if (!err) all = all.concat((body && body.value) || [])
                    if (--pending > 0) return
                    if (all.length === 0 && firstErr) return cb(firstErr)
                    all.sort(function (a, b) {
                        return Date.parse(b.creationDate) - Date.parse(a.creationDate)
                    })
                    cb(null, all)
                })
        }
    }

    function pullRequestsToReview(cb) {
        me(function (err, user) {
            if (err) return cb(err)
            root._listPullRequests("searchCriteria.reviewerId=" + user.id, function (err2, list) {
                if (err2) return cb(err2)
                // A PR you created where you're also listed as reviewer belongs
                // in "Mine", not "Review".
                cb(null, list.filter(function (pr) {
                    return !(pr.createdBy && pr.createdBy.id === user.id)
                }))
            })
        })
    }

    function myPullRequests(cb) {
        me(function (err, user) {
            if (err) return cb(err)
            root._listPullRequests("searchCriteria.creatorId=" + user.id, cb)
        })
    }

    function _prPath(pr) {
        const repo = pr.repository || {}
        const proj = (repo.project && repo.project.id) || ""
        if (!_validGuid(repo.id) || !_validGuid(proj) || !_validId(pr.pullRequestId))
            throw new Error("malformed pull request reference")
        return "/" + proj + "/_apis/git/repositories/" + repo.id +
            "/pullRequests/" + pr.pullRequestId
    }

    // vote: 10 approve, 5 approve w/ suggestions, 0 reset, -5 wait for author, -10 reject
    function votePullRequest(pr, vote, cb) {
        if ([10, 5, 0, -5, -10].indexOf(vote) < 0) return cb(new Error("invalid vote"))
        let p
        try { p = _prPath(pr) } catch (e) { return cb(e) }
        me(function (err, user) {
            if (err) return cb(err)
            root._request("PUT", root._withVersion(p + "/reviewers/" + user.id),
                { vote: vote }, cb)
        })
    }

    // Starts a new top-level comment thread. Content is Markdown.
    function commentPullRequest(pr, text, cb) {
        let p
        try { p = _prPath(pr) } catch (e) { return cb(e) }
        _request("POST", _withVersion(p + "/threads"), {
            comments: [{ parentCommentId: 0, content: String(text), commentType: 1 }],
            status: 1
        }, cb)
    }

    // All comment threads on a PR (including system threads for votes,
    // pushes, etc. — callers filter those out).
    function pullRequestThreads(pr, cb) {
        let p
        try { p = _prPath(pr) } catch (e) { return cb(e) }
        _request("GET", _withVersion(p + "/threads"), null, function (err, body) {
            if (err) return cb(err)
            cb(null, (body && body.value) || [])
        })
    }

    // ---- Work items ----

    function _wiqlString(s) { return "'" + String(s).replace(/'/g, "''") + "'" }

    // Runs a WIQL query and hydrates the matching work items. `excludedStates`
    // is a comma-separated list, e.g. "Closed,Done,Removed".
    function assignedWorkItems(excludedStates, extraWhere, cb) {
        const states = (excludedStates || "").split(",")
            .map(function (s) { return s.trim() })
            .filter(function (s) { return s.length > 0 })
        let where = "[System.AssignedTo] = @Me"
        if (states.length > 0)
            where += " AND [System.State] NOT IN (" + states.map(_wiqlString).join(", ") + ")"
        const projs = projectList()
        if (projs.length > 0)
            where += " AND [System.TeamProject] IN (" + projs.map(_wiqlString).join(", ") + ")"
        if (extraWhere && extraWhere.trim()) where += " AND (" + extraWhere.trim() + ")"
        const wiql = "SELECT [System.Id] FROM WorkItems WHERE " + where +
            " ORDER BY [System.ChangedDate] DESC"

        _request("POST", _withVersion("/_apis/wit/wiql?$top=100"), { query: wiql },
            function (err, body) {
                if (err) return cb(err)
                const ids = ((body && body.workItems) || []).map(function (w) { return w.id })
                if (ids.length === 0) return cb(null, [])
                const fields = [
                    "System.Id", "System.Title", "System.State", "System.WorkItemType",
                    "System.TeamProject", "System.ChangedDate", "Microsoft.VSTS.Common.Priority"
                ].join(",")
                root._request("GET", root._withVersion("/_apis/wit/workitems?ids=" +
                    ids.slice(0, 200).join(",") + "&fields=" + fields + "&errorPolicy=omit"), null,
                    function (err2, body2) {
                        if (err2) return cb(err2)
                        const byId = {}
                        const items = ((body2 && body2.value) || []).filter(function (w) { return !!w })
                        for (let i = 0; i < items.length; i++) byId[items[i].id] = items[i]
                        // Keep WIQL's ordering.
                        cb(null, ids.map(function (id) { return byId[id] })
                            .filter(function (w) { return !!w }))
                    })
            })
    }

    // States available for a work item type, with their category
    // (Proposed / InProgress / Resolved / Completed / Removed).
    function workItemStates(project, type, cb) {
        _request("GET", "/" + _seg(project) + "/_apis/wit/workitemtypes/" + _seg(type) +
            "/states?api-version=" + apiVersion + "-preview.1", null, function (err, body) {
            if (err) return cb(err)
            cb(null, (body && body.value) || [])
        })
    }

    function setWorkItemState(id, state, cb) {
        if (!_validId(id)) return cb(new Error("invalid work item id"))
        _request("PATCH", _withVersion("/_apis/wit/workitems/" + id),
            [{ op: "add", path: "/fields/System.State", value: String(state) }],
            cb, "application/json-patch+json")
    }

    // Work item comments are HTML; escape the plain text and keep line breaks.
    function commentWorkItem(project, id, text, cb) {
        if (!_validId(id)) return cb(new Error("invalid work item id"))
        const html = String(text)
            .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
            .replace(/\r?\n/g, "<br>")
        _request("POST", "/" + _seg(project) + "/_apis/wit/workItems/" + id +
            "/comments?api-version=" + apiVersion + "-preview.4", { text: html }, cb)
    }

    // ---- Web links ----

    function pullRequestWebUrl(pr) {
        const repo = pr.repository || {}
        const proj = (repo.project && repo.project.name) || ""
        return base() + "/" + _seg(proj) + "/_git/" + _seg(repo.name || "") +
            "/pullrequest/" + pr.pullRequestId
    }

    function workItemWebUrl(wi) {
        const proj = (wi.fields && wi.fields["System.TeamProject"]) || ""
        return base() + "/" + _seg(proj) + "/_workitems/edit/" + wi.id
    }
}
