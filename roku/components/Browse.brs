sub initBrowse()
    m.searchList = m.top.findNode("searchList")
    m.searchList.observeField("itemSelected", "onSearchSelected")
    m.searchQuery = ""
    m.searchPage = 0
    m.searchCursors = [""]
    m.searchActions = []
    m.searchFocus = 0
    m.vodFocusId = ""
    m.detailsBackHeld = false
    m.vodList.observeField("itemFocused", "onVodFocused")
    m.vodDetailsTitle = m.top.findNode("vodDetailsTitle")
    m.vodThumbnail = m.top.findNode("vodThumbnail")
    m.vodThumbnail.observeField("loadStatus", "onVodThumbnailLoad")
    agent = CreateObject("roHttpAgent")
    agent.setCertificatesFile("common:/certs/ca-bundle.crt")
    m.vodThumbnail.setHttpAgent(agent)
end sub

sub openSearch()
    dialog = CreateObject("roSGNode", "KeyboardDialog")
    dialog.title = "Search Twitch channels"
    dialog.text = m.searchQuery
    dialog.buttons = ["Search", "Cancel"]
    dialog.observeField("buttonSelected", "onSearchQuery")
    m.top.dialog = dialog
end sub

sub onSearchQuery()
    dialog = m.top.dialog
    query = dialog.text.Trim()
    accepted = dialog.buttonSelected = 0
    dialog.close = true
    restoreFocus()
    if not accepted then return
    if query = "" or Len(query) > 100
        m.status.text = "Enter a channel name, up to 100 characters."
        return
    end if
    m.searchQuery = query
    m.searchCursors = [""]
    m.searchFocus = 0
    loadSearch(0)
end sub

sub loadSearch(page as integer)
    if m.busy then return
    m.requestedSearchPage = page
    path = "/api/search?q=" + m.searchQuery.EncodeUriComponent() + "&cursor=" + m.searchCursors[page].EncodeUriComponent()
    m.status.text = "Searching channels..."
    callApi("search", path, "GET", {})
end sub

sub showSearch(d as object)
    m.searchPage = m.requestedSearchPage
    m.searchActions = []
    content = CreateObject("roSGNode", "ContentNode")
    for each channel in d.channels
        state = "OFFLINE"
        if channel.live then state = "LIVE"
        item = content.createChild("ContentNode")
        item.title = channel.name + "  |  " + state + "  |  " + channel.login
        m.searchActions.push({kind: "channel", channel: channel.login})
    end for
    if d.cursor <> ""
        m.searchCursors[m.searchPage + 1] = d.cursor
        item = content.createChild("ContentNode")
        item.title = "Next page"
        m.searchActions.push({kind: "page", page: m.searchPage + 1})
    end if
    if m.searchPage > 0
        item = content.createChild("ContentNode")
        item.title = "Previous page"
        m.searchActions.push({kind: "page", page: m.searchPage - 1})
    end if
    item = content.createChild("ContentNode")
    item.title = "New search"
    m.searchActions.push({kind: "query"})
    item = content.createChild("ContentNode")
    item.title = "Back to Following"
    m.searchActions.push({kind: "back"})
    m.searchList.content = content
    m.searchList.jumpToItem = 0
    m.searchFocus = 0
    m.view = "search"
    restoreFocus()
    m.status.text = "Results for: " + m.searchQuery
    if d.channels.count() = 0 then m.status.text = "No channels found. Try another name."
end sub

sub onSearchSelected()
    if m.busy or m.timerAction <> "" then return
    m.searchFocus = m.searchList.itemSelected
    action = m.searchActions[m.searchFocus]
    if action.kind = "channel"
        m.channel = action.channel
        m.vodReturnView = "search"
        m.vodFocusId = ""
        m.status.text = "Opening " + m.channel + "..."
        callApi("channel", "/api/channel/" + m.channel, "GET", {})
    else if action.kind = "page"
        loadSearch(action.page)
    else if action.kind = "query"
        openSearch()
    else
        showFollowing()
    end if
end sub

function vodListInfo(video as object) as object
    position = 0
    if video.position <> invalid then position = video.position
    duration = video.duration_seconds
    if position < 0 then position = 0
    if position > duration then position = duration
    ratio = 0.0
    if duration > 0 then ratio = position / duration
    subtitle = Left(video.created_at, 10) + "  |  " + video.duration
    if position > 0 then subtitle += "  |  Watched " + vodTimeText(position)
    return {subtitle: subtitle, progressRatio: ratio, showProgress: position > 0}
end function

sub onVodFocused()
    if m.view <> "vods" and m.view <> "history" then return
    index = m.vodList.itemFocused
    if index < 0 or index >= m.vodActions.count() then return
    showVodDetails(m.vodActions[index])
end sub

sub showVodDetails(action as object)
    m.vodDetailsTitle.text = ""
    m.top.findNode("vodDetailsMeta").text = ""
    m.vodThumbnail.visible = false
    m.vodThumbnail.uri = ""
    m.top.findNode("vodCoverFallback").text = ""
    if action.kind <> "video" then return
    video = action.metadata
    if video = invalid then return
    m.vodDetailsTitle.text = video.title
    meta = ""
    if video.created_at <> invalid and video.created_at <> "" then meta = Left(video.created_at, 10) + "  |  "
    m.top.findNode("vodDetailsMeta").text = meta + vodTimeText(video.duration_seconds)
    m.top.findNode("vodCoverFallback").text = "No preview"
    if video.thumbnail <> invalid then m.vodThumbnail.uri = video.thumbnail
    onVodThumbnailLoad()
end sub

sub onVodThumbnailLoad()
    m.vodThumbnail.visible = m.vodThumbnail.uri <> "" and m.vodThumbnail.loadStatus = "ready"
end sub

function handleVodDetailsKey(key as string, press as boolean) as boolean
    if m.video.visible or m.recovering or (m.view <> "vods" and m.view <> "history") then return false
    if key = "back" and m.detailsBackHeld = true
        if not press then m.detailsBackHeld = false
        return true
    end if
    if m.vodDetailsTitle.isInFocusChain()
        if key = "left" or key = "back"
            if press
                if key = "back" then m.detailsBackHeld = true
                m.vodList.setFocus(true)
            end if
            return true
        end if
    else if key = "right" and press
        m.vodDetailsTitle.setFocus(true)
        return true
    end if
    return false
end function
