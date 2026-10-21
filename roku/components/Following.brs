sub initFollowing()
    m.followList = m.top.findNode("followList")
    m.followList.observeField("itemSelected", "onFollowSelected")
    m.followList.observeField("itemFocused", "onFollowFocused")
    m.followRefresh = m.top.findNode("followRefresh")
    m.followRefresh.observeField("fire", "onFollowRefresh")
    m.followRefresh.control = "start"
    m.followBusy = false
    m.followRevision = 0
    m.followFocusKey = "history"
    m.onlyLive = false
    m.rebuildingFollows = false
    m.top.findNode("detailAvatar").observeField("loadStatus", "onDetailAvatarLoad")
    agent = CreateObject("roHttpAgent")
    agent.setCertificatesFile("common:/certs/ca-bundle.crt")
    m.top.findNode("detailAvatar").setHttpAgent(agent)
    m.followActions = []
    m.followed = []
    m.followSeen = {}
    m.followCursors = {}
    m.account = {signed_in: false, follows_ready: false}
    m.homeReady = false
    m.selectedChannel = ""
    m.vodReturnView = "home"
end sub

function followingRows() as object
    rows = []
    if not m.account.signed_in
        rows.push({kind: "login", title: "Sign in to Twitch", subtitle: "Connect your account"})
    else if not m.account.follows_ready
        rows.push({kind: "login", title: "Enable Following", subtitle: "Allow access to followed channels"})
    else
        rows.push({kind: "history", title: "Continue watching", subtitle: "Resume a recording"})
        filterText = "All followed"
        if m.onlyLive then filterText = "Live only"
        rows.push({kind: "filter", title: "Show: " + filterText, subtitle: "Press OK to switch"})
        rows.push({kind: "search", title: "Search channels", subtitle: "Find a streamer"})
        for each channel in m.followed
            if not m.onlyLive or channel.live
                subtitle = "OFFLINE"
                if channel.live then subtitle = "LIVE  |  " + channel.viewers.toStr() + " viewers"
                if channel.pinned = true then subtitle = "PINNED  |  " + subtitle
                rows.push({kind: "channel", channel: channel.login, title: channel.name, subtitle: subtitle, profile: channel})
            end if
        end for
        rows.push({kind: "refresh", title: "Refresh", subtitle: "Updates automatically every minute"})
    end if
    rows.push({kind: "settings", title: "Settings", subtitle: "Account and playback"})
    return rows
end function

function followRowKey(row as object) as string
    if row.kind = "channel" then return "channel:" + row.channel
    return row.kind
end function

function followFocusIndex(rows as object, key as string, fallback as integer) as integer
    for i = 0 to rows.count() - 1
        if followRowKey(rows[i]) = key then return i
    end for
    if fallback < 0 then return 0
    if fallback >= rows.count() then return rows.count() - 1
    return fallback
end function

sub showFollowing()
    m.view = "home"
    oldIndex = m.followList.itemFocused
    rows = followingRows()
    selected = followFocusIndex(rows, m.followFocusKey, oldIndex)
    m.rebuildingFollows = true
    content = CreateObject("roSGNode", "ContentNode")
    for each row in rows
        item = content.createChild("ContentNode")
        item.title = row.title
        item.shortDescriptionLine1 = row.subtitle
        item.live = false
        if row.kind = "channel"
            item.live = row.profile.live
            if row.profile.avatar <> invalid then item.hdPosterUrl = row.profile.avatar
        end if
    end for
    m.followActions = rows
    m.followList.content = content
    m.followList.jumpToItem = selected
    m.followFocusKey = followRowKey(rows[selected])
    m.rebuildingFollows = false
    restoreFocus()
    showFollowDetails(rows[selected])
    if not m.account.signed_in
        m.homeStatus = "Sign in to see the channels you follow."
    else if not m.account.follows_ready
        m.homeStatus = "Enable Following to allow access. Your playback login will be kept."
    else
        online = 0
        for each channel in m.followed
            if channel.live then online++
        end for
        m.homeStatus = online.toStr() + " live  /  " + m.followed.count().toStr() + " followed"
        if m.followed.count() = 0 then m.homeStatus = "You are not following any channels yet."
        if m.onlyLive and online = 0 then m.homeStatus = "No followed channels are live. Switch to All followed to see VODs."
    end if
    m.status.text = m.homeStatus
end sub

function canRefreshFollowing() as boolean
    if m.view <> "home" or m.video.visible or m.busy or m.timerAction <> "" then return false
    if m.top.dialog <> invalid
        if m.top.dialog.isInFocusChain() then return false
    end if
    return m.account.signed_in and m.account.follows_ready
end function

sub onFollowRefresh()
    if canRefreshFollowing() then loadFollowing(true)
end sub

sub loadFollowing(quiet = false as boolean)
    if m.busy or m.followBusy then return
    if not m.account.signed_in or not m.account.follows_ready
        showFollowing()
        return
    end if
    m.followLoading = []
    m.followSeen = {}
    m.followCursors = {}
    m.followAccount = m.account.login
    m.followLoadRevision = m.followRevision
    m.followQuiet = quiet
    m.followBusy = true
    if not quiet then m.status.text = "Loading followed channels..."
    requestFollowPage("/api/follows")
end sub

sub onFollowResult()
    result = m.followTask.result
    m.followTask.unobserveField("result")
    if not canRefreshFollowing() or m.followAccount <> m.account.login or m.followLoadRevision <> m.followRevision
        m.followBusy = false
        return
    end if
    if not result.ok
        m.followBusy = false
        m.status.text = "Could not refresh. Previous list kept. Select Refresh to retry."
        if not m.homeReady then m.status.text = result.message
        return
    end if
    receiveFollows(result.data)
end sub

sub onFollowFocused()
    if m.rebuildingFollows or m.view <> "home" then return
    index = m.followList.itemFocused
    if index < 0 or index >= m.followActions.count() then return
    row = m.followActions[index]
    m.followFocusKey = followRowKey(row)
    if row.kind = "channel" then m.selectedChannel = row.channel
    showFollowDetails(row)
end sub

sub onDetailAvatarLoad()
    poster = m.top.findNode("detailAvatar")
    poster.visible = poster.loadStatus = "ready" and poster.uri <> ""
end sub

sub showFollowDetails(row as object)
    m.top.findNode("detailAvatar").visible = false
    m.top.findNode("detailAvatar").uri = ""
    m.top.findNode("detailInitial").text = UCase(Left(row.title, 1))
    m.top.findNode("detailName").text = row.title
    m.top.findNode("detailState").text = row.subtitle
    m.top.findNode("detailGame").text = ""
    m.top.findNode("detailTitle").text = ""
    m.top.findNode("detailHint").text = "Press OK to open"
    if row.kind = "channel"
        channel = row.profile
        if channel.pinned = true
            m.top.findNode("detailState").text = "PINNED  |  OFFLINE"
            if channel.live then m.top.findNode("detailState").text = "PINNED  |  LIVE"
        end if
        if channel.avatar <> invalid then m.top.findNode("detailAvatar").uri = channel.avatar
        if channel.live
            m.top.findNode("detailTitle").text = channel.title
            m.top.findNode("detailGame").text = channel.game
            m.top.findNode("detailHint").text = "OK: Watch live" + Chr(10) + "*: Channel menu / Pin"
        else
            m.top.findNode("detailTitle").text = "This channel is offline."
            m.top.findNode("detailHint").text = "OK: Past broadcasts" + Chr(10) + "*: Channel menu / Pin"
        end if
    else if row.kind = "filter"
        m.top.findNode("detailTitle").text = "Show all followed channels or only channels that are live."
    else if row.kind = "history"
        m.top.findNode("detailTitle").text = "Pick up where you left off."
    end if
    onDetailAvatarLoad()
end sub

function followsBefore(a as object, b as object) as boolean
    aPinned = a.pinned = true
    bPinned = b.pinned = true
    if aPinned <> bPinned then return aPinned
    if a.live <> b.live then return a.live
    if a.live and a.viewers <> b.viewers then return a.viewers > b.viewers
    return LCase(a.name) < LCase(b.name)
end function

sub applyFavorite(d as object)
    ordered = []
    for each channel in m.followed
        if channel.id = d.channel_id then channel.pinned = d.pinned
        i = ordered.count()
        ordered.push(channel)
        while i > 0
            if not followsBefore(channel, ordered[i - 1]) then exit while
            ordered[i] = ordered[i - 1]
            i--
        end while
        ordered[i] = channel
    end for
    m.followed = ordered
    if m.view = "home" then showFollowing()
end sub

sub receiveFollows(d as object)
    for each channel in d.channels
        if not m.followSeen.doesExist(channel.id)
            m.followSeen[channel.id] = true
            ' Insert each page into the same order, including offline channels.
            i = m.followLoading.count()
            m.followLoading.push(channel)
            while i > 0
                if not followsBefore(channel, m.followLoading[i - 1]) then exit while
                m.followLoading[i] = m.followLoading[i - 1]
                i--
            end while
            m.followLoading[i] = channel
        end if
    end for
    if d.cursor <> ""
        if m.followCursors.doesExist(d.cursor)
            m.followBusy = false
            m.status.text = "Twitch repeated a page. Select Refresh to try again."
            return
        end if
        m.followCursors[d.cursor] = true
        if not m.followQuiet then m.status.text = "Loading followed channels... " + m.followLoading.count().toStr()
        requestFollowPage("/api/follows?cursor=" + d.cursor.EncodeUriComponent())
    else
        m.followBusy = false
        m.followed = m.followLoading
        m.homeReady = true
        showFollowing()
    end if
end sub

sub showSettings()
    m.view = "menu"
    restoreFocus()
    m.status.text = "Account and playback settings"
end sub

sub onFollowSelected()
    if m.busy or m.timerAction <> "" then return
    action = m.followActions[m.followList.itemSelected]
    if action.kind = "channel"
        m.channel = action.channel
        m.selectedChannel = action.channel
        m.vodReturnView = "home"
        m.status.text = "Opening " + m.channel + "..."
        ' Check again because the channel may have gone offline since the list loaded.
        callApi("channel", "/api/channel/" + m.channel, "GET", {})
    else if action.kind = "search"
        openSearch()
    else if action.kind = "filter"
        m.onlyLive = not m.onlyLive
        m.followFocusKey = "filter"
        showFollowing()
    else if action.kind = "history"
        loadHistory()
    else if action.kind = "refresh"
        loadFollowing()
    else if action.kind = "login"
        showSettings()
        m.status.text = "Requesting a login code..."
        callApi("login", "/api/login", "POST", {})
    else
        showSettings()
    end if
end sub

sub openChannel(d as object)
    if d.live
        callApi("play", "/api/play", "POST", {channel: d.channel})
    else
        m.channel = d.channel
        m.vodCursors = [""]
        loadVods(0)
    end if
end sub

sub returnFromVods()
    if m.vodReturnView = "home"
        showFollowing()
    else if m.vodReturnView = "search"
        m.view = "search"
        restoreFocus()
        m.searchList.jumpToItem = m.searchFocus
        m.status.text = "Results for: " + m.searchQuery
    else
        showSettings()
    end if
end sub
