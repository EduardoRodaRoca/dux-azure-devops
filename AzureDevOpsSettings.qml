import QtQuick
import QtQuick.Controls
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

// All setting widgets are DIRECT children of PluginSettings: it only calls
// loadValue() on its direct content, so nested widgets would never show the
// persisted value. Plain StyledText nodes stand in for section headers.

PluginSettings {
    id: root
    pluginId: "azureDevOps"

    // ---- Connection ----

    StyledText {
        text: "Connection"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
        topPadding: Theme.spacingS
    }

    StringSetting {
        settingKey: "orgUrl"
        label: "Organization URL"
        description: "e.g. https://dev.azure.com/your-org"
        defaultValue: ""
    }

    StringSetting {
        settingKey: "projects"
        label: "Projects (optional)"
        description: "Comma-separated project names to limit results to. Empty = whole organization."
        defaultValue: ""
    }

    SelectionSetting {
        id: tokenSourceSetting
        settingKey: "tokenSource"
        label: "Token source"
        description: "Where the plugin reads your Personal Access Token from. Scopes needed: Code (Read & write), Work Items (Read & write)."
        options: [
            { label: "File", value: "file" },
            { label: "libsecret (secret-tool)", value: "libsecret" }
        ]
        defaultValue: "file"
    }

    StringSetting {
        settingKey: "tokenPath"
        label: "Token file path"
        description: "Absolute path to a 0600 file containing the PAT."
        defaultValue: ""
        visible: tokenSourceSetting.value === "file"
    }

    StyledText {
        visible: tokenSourceSetting.value === "libsecret"
        width: parent ? parent.width : 400
        wrapMode: Text.WordWrap
        text: "Store the PAT with:\nsecret-tool store --label='dms-azure-devops' service dms-azure-devops account <org-name>"
        color: Theme.surfaceVariantText
        font.pixelSize: Theme.fontSizeSmall
    }

    // ---- Query ----

    StyledText {
        text: "Query"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
        topPadding: Theme.spacingL
    }

    StringSetting {
        settingKey: "excludedStates"
        label: "Hide work items in these states"
        description: "Comma-separated. Adjust to your process template."
        defaultValue: "Closed,Done,Removed,Resolved,Completed"
    }

    StringSetting {
        settingKey: "extraWiql"
        label: "Extra WIQL filter (optional)"
        description: "ANDed into the work item query, e.g. [System.WorkItemType] <> 'Epic'"
        defaultValue: ""
    }

    ToggleSetting {
        settingKey: "hideDrafts"
        label: "Hide draft PRs from review list"
        description: "Drafts you're a reviewer on won't count toward the badge."
        defaultValue: true
    }

    SelectionSetting {
        settingKey: "pollMinutes"
        label: "Poll interval"
        description: "How often to refresh."
        options: [
            { label: "1 minute",   value: "1" },
            { label: "2 minutes",  value: "2" },
            { label: "5 minutes",  value: "5" },
            { label: "10 minutes", value: "10" },
            { label: "15 minutes", value: "15" },
            { label: "30 minutes", value: "30" }
        ]
        defaultValue: "5"
    }

    // ---- Display ----

    StyledText {
        text: "Display"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
        topPadding: Theme.spacingL
    }

    SelectionSetting {
        settingKey: "pillMode"
        label: "Bar pill shows"
        description: "What the counter on the bar represents."
        options: [
            { label: "Reviews pending + work items", value: "both" },
            { label: "Reviews pending only", value: "reviews" },
            { label: "Work items only", value: "work" }
        ]
        defaultValue: "both"
    }

    SelectionSetting {
        settingKey: "defaultTab"
        label: "Default tab"
        options: [
            { label: "To review", value: "review" },
            { label: "My PRs", value: "mine" },
            { label: "Work items", value: "work" }
        ]
        defaultValue: "review"
    }

    ToggleSetting {
        settingKey: "branchPrefixByType"
        label: "Prefix work item branch names by type"
        description: "Adds feature/ / bug/ / chore/ when copying a branch name."
        defaultValue: true
    }

    // ---- Notifications ----

    StyledText {
        text: "Notifications"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
        topPadding: Theme.spacingL
    }

    ToggleSetting {
        settingKey: "notifyReview"
        label: "Review requested"
        description: "Notify when a new PR asks for your review."
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "notifyVotes"
        label: "Votes on my PRs"
        description: "Notify when someone approves, rejects, or waits on one of your PRs."
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "notifyComments"
        label: "Comments on my PRs"
        description: "Notify when someone else comments on one of your pull requests."
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "notifyReplies"
        label: "Replies on PRs I review"
        description: "Notify on new comments in threads you've posted in on others' PRs."
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showUnreadOnBar"
        label: "Show unread comment count on bar"
        description: "Adds a comment counter to the pill when there are unread comments."
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "notifyAssigned"
        label: "Work item assigned"
        description: "Notify when a work item is newly assigned to you."
        defaultValue: false
    }

    // ---- Demo ----

    StyledText {
        text: "Demo"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
        topPadding: Theme.spacingL
    }

    ToggleSetting {
        settingKey: "demoMode"
        label: "Demo mode"
        description: "Shows fake PRs and work items and skips the API. Useful to try the UI before configuring a token."
        defaultValue: false
    }
}
