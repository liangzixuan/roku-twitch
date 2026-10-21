sub assertThat(condition as boolean, message as string)
    if not condition
        print "FAIL: " + message
        invalid.FailTest()
    end if
    m.checks += 1
end sub

sub callApi(action as string, path as string, method as string, body as object)
    m.request = {action: action, path: path, method: method, body: body}
end sub

sub requestFollowPage(path as string)
    m.request = {action: "follows", path: path}
end sub

sub loadVods(page as integer)
    m.request = {action: "videos", channel: m.channel, page: page}
end sub

sub main()
    m.checks = 0
    m.followRevision = 0
    m.followQuiet = false
    m.status = {text: ""}
    m.followLoading = []
    m.followSeen = {}
    m.followCursors = {}
    m.followed = [{id: "old"}]
    receiveFollows({channels: [
        {id: "1", name: "Zulu", login: "zulu", live: false, viewers: 0},
        {id: "2", name: "Low", login: "low", live: true, viewers: 10},
        {id: "3", name: "Zero", login: "zero", live: true, viewers: 0}
    ], cursor: "next+page/=="})
    assertThat(m.followLoading[0].id = "2", "live viewers sort descending")
    assertThat(m.followLoading[1].id = "3", "zero viewers is still online")
    assertThat(m.followLoading[2].id = "1", "offline channels come last")
    assertThat(m.request.action = "follows", "fetch next follows page")
    assertThat(m.request.path = "/api/follows?cursor=next%2Bpage%2F%3D%3D", "encode Twitch pagination cursor")
    receiveFollows({channels: [
        {id: "4", name: "High", login: "high", live: true, viewers: 999},
        {id: "5", name: "alpha", login: "alpha", live: false, viewers: 0},
        {id: "2", name: "Low", login: "low", live: true, viewers: 10},
        {id: "6", name: "Equal", login: "equal", live: true, viewers: 10}
    ], cursor: "third"})
    assertThat(m.followLoading.count() = 6, "deduplicate channels across pages")
    assertThat(m.followLoading[0].id = "4", "later page can rank first")
    assertThat(m.followLoading[1].id = "6", "equal viewers sort by name")
    assertThat(m.followLoading[4].id = "5", "offline names sort alphabetically")
    assertThat(m.followed[0].id = "old", "keep last complete list until loading finishes")
    m.request = invalid
    receiveFollows({channels: [], cursor: "third"})
    assertThat(m.request = invalid, "repeated cursor cannot loop forever")
    assertThat(m.status.text = "Twitch repeated a page. Select Refresh to try again.", "pagination failure is visible")

    openChannel({channel: "livechannel", live: true})
    assertThat(m.request.action = "play" and m.request.path = "/api/play", "online channel starts live playback")
    assertThat(m.request.body.channel = "livechannel", "play selected channel")
    m.vodCursors = ["stale"]
    openChannel({channel: "offlinechannel", live: false})
    assertThat(m.request.action = "videos" and m.request.channel = "offlinechannel", "offline channel opens recordings")
    assertThat(m.request.page = 0 and m.vodCursors[0] = "", "new channel starts at first VOD page")

    m.busy = false
    m.timerAction = ""
    m.followActions = [{kind: "channel", channel: "changedchannel"}]
    m.followList = {itemSelected: 0}
    onFollowSelected()
    assertThat(m.request.action = "channel" and m.request.path = "/api/channel/changedchannel", "selection rechecks current online status")
    assertThat(m.selectedChannel = "changedchannel" and m.vodReturnView = "home", "return to selected channel after playback")
    m.busy = true
    m.request = invalid
    onFollowSelected()
    assertThat(m.request = invalid, "ignore double selection while loading")
    m.account = {signed_in: true, follows_ready: true, login: "viewer"}
    m.followed = [
        {login: "high", name: "High", live: true, viewers: 999},
        {login: "zero", name: "Zero", live: true, viewers: 0},
        {login: "off", name: "Offline", live: false, viewers: 0}
    ]
    m.onlyLive = false
    rows = followingRows()
    assertThat(rows.count() = 8, "all followed includes offline channels and utility rows")
    assertThat(rows[2].kind = "search", "home includes channel search")
    assertThat(rows[1].kind = "filter", "filter is near top of home")
    assertThat(followFocusIndex(rows, "channel:zero", 0) = 4, "find focused channel by identity")
    assertThat(followFocusIndex(rows, "filter", 0) = 1, "preserve focus on filter row")
    m.followed.unshift({login: "new", name: "New", live: true, viewers: 2000})
    rows = followingRows()
    assertThat(followFocusIndex(rows, "channel:zero", 3) = 5, "ranking changes preserve focused channel")
    m.onlyLive = true
    rows = followingRows()
    assertThat(rows.count() = 8 and rows[5].channel = "zero", "live filter keeps zero-viewer live channels")
    assertThat(followFocusIndex(rows, "channel:off", 99) = rows.count() - 1, "removed channel falls back to valid row")
    m.followed = []
    rows = followingRows()
    assertThat(rows.count() = 5 and rows[1].kind = "filter", "empty live filter still allows switching back")

    m.view = "home"
    m.video = {visible: false}
    m.busy = false
    m.timerAction = ""
    m.top = {dialog: invalid}
    assertThat(canRefreshFollowing(), "home can refresh")
    m.video.visible = true
    assertThat(not canRefreshFollowing(), "do not refresh during playback")
    m.video.visible = false
    m.view = "vods"
    assertThat(not canRefreshFollowing(), "do not refresh while browsing recordings")
    m.view = "home"
    m.top.dialog = {isInFocusChain: function() as boolean
        return true
    end function}
    assertThat(not canRefreshFollowing(), "menu keeps its focus during refresh interval")
    m.top.dialog.isInFocusChain = function() as boolean
        return false
    end function
    assertThat(canRefreshFollowing(), "closed menu allows refresh again")
    m.followBusy = false
    m.config = {}
    m.busy = false
    m.status.text = "Current list"
    onFollowRefresh()
    assertThat(m.followBusy and not m.busy, "background refresh does not block playback selection")
    assertThat(m.followQuiet and m.status.text = "Current list", "automatic refresh leaves status alone while loading")
    m.request = invalid
    onFollowRefresh()
    assertThat(m.request = invalid, "only one refresh can run at once")
    m.followTask = {result: {ok: false}, unobserveField: sub(field as string)
    end sub}
    m.followed = [{login: "kept"}]
    m.homeReady = true
    onFollowResult()
    assertThat(not m.followBusy and m.followed[0].login = "kept", "failed refresh keeps previous list")
    m.followBusy = true
    m.view = "history"
    m.followTask.result = {ok: true, data: {channels: [], cursor: ""}}
    onFollowResult()
    assertThat(not m.followBusy and m.followed[0].login = "kept", "late response cannot reopen home after navigation")
    m.view = "home"
    m.followBusy = true
    m.followAccount = "previous"
    onFollowResult()
    assertThat(not m.followBusy and m.followed[0].login = "kept", "account change discards old refresh response")
    m.followAccount = m.account.login
    m.followLoadRevision = m.followRevision
    m.followRevision++
    m.followBusy = true
    onFollowResult()
    assertThat(not m.followBusy and m.followed[0].login = "kept", "late background response cannot undo favorite change")

    m.view = "menu"
    m.onlyLive = false
    m.followFocusKey = "channel:off"
    m.followed = [
        {id: "1", login: "high", name: "High", live: true, viewers: 999},
        {id: "2", login: "low", name: "Low", live: true, viewers: 10},
        {id: "3", login: "off", name: "Offline", live: false, viewers: 0}
    ]
    applyFavorite({channel_id: "3", pinned: true})
    assertThat(m.followed[0].id = "3", "offline favorite ranks above nonfavorite live channels")
    rows = followingRows()
    assertThat(rows[3].subtitle = "PINNED  |  OFFLINE", "favorite badge is visible")
    assertThat(followFocusIndex(rows, m.followFocusKey, 4) = 3, "focus follows pinned channel to top")
    m.onlyLive = true
    rows = followingRows()
    assertThat(rows.count() = 7 and rows[3].channel = "high", "live filter also hides offline favorites")
    applyFavorite({channel_id: "2", pinned: true})
    assertThat(m.followed[0].id = "2" and m.followed[1].id = "3", "live favorites rank before offline favorites")
    applyFavorite({channel_id: "1", pinned: true})
    assertThat(m.followed[0].id = "1" and m.followed[1].id = "2", "live favorites sort by viewers")
    applyFavorite({channel_id: "1", pinned: false})
    assertThat(m.followed[2].id = "1", "unpin restores normal group order")
    m.followLoading = []
    m.followSeen = {}
    m.followCursors = {}
    receiveFollows({channels: [{id: "10", name: "Live", live: true, viewers: 100}], cursor: "one"})
    receiveFollows({channels: [{id: "11", name: "Pinned", live: false, viewers: 0, pinned: true}], cursor: "two"})
    assertThat(m.followLoading[0].id = "11", "favorite on later page sorts to top")
    print "PASS: "; m.checks; " Following checks"
end sub
