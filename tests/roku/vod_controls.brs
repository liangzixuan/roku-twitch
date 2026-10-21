sub assertThat(condition as boolean, message as string)
    if not condition
        print "FAIL: " + message
        invalid.FailTest()
    end if
    m.checks += 1
end sub

sub preparePlayer(paused = false)
    m.top = {isInFocusChain: function() as boolean
        return true
    end function}
    m.video = {state: "playing", visible: true, duration: 7200.0, position: 100.0, content: {length: 7200}, seek: invalid, control: "none", autoplayAfterSeek: true}
    if paused then m.video.state = "paused"
    m.vodHud = {visible: false}
    m.vodTime = {text: ""}
    m.playIcon = {visible: false}
    m.pauseIcon = {visible: true}
    m.vodInput = {isInFocusChain: function() as boolean
        return true
    end function, setFocus: sub(value as boolean)
    end sub}
    m.vodFill = {width: 0}
    m.seekTimer = {control: "stop"}
    m.hudTimer = {control: "stop"}
    m.seekClock = CreateObject("roTimespan")
    resetVodControls()
    m.isVod = true
    m.vodPaused = paused
end sub

sub main()
    m.checks = 0
    assertThat(seekStep(0) = 10, "tap is ten seconds")
    assertThat(seekStep(1999) = 10, "first acceleration has a delay")
    assertThat(seekStep(2000) = 30, "hold for two seconds")
    assertThat(seekStep(5000) = 60, "hold for five seconds")
    assertThat(seekStep(10000) = 300, "hold for ten seconds")
    assertThat(clampSeek(-20, 7200) = 0, "cannot rewind before start")
    assertThat(clampSeek(8000, 7200) = 7198, "leave room before end")
    assertThat(clampSeek(10, 1) = 0, "short recordings stay in range")
    assertThat(vodTimeText(7384) = "2:03:04", "time formatting: " + vodTimeText(7384))

    preparePlayer()
    assertThat(handleVodKey("right", true), "right press is handled")
    assertThat(m.seekTarget = 110, "tap previews ten seconds")
    assertThat(m.video.seek = invalid, "no network seek while held")
    handleVodKey("right", true)
    assertThat(m.seekTarget = 110, "OS repeat does not add a second step")
    advanceVodSeek(2000)
    assertThat(m.seekTarget = 140, "hold accelerates preview")
    advanceVodSeek(5000)
    assertThat(m.seekTarget = 200, "longer hold accelerates preview")
    advanceVodSeek(10000)
    assertThat(m.seekTarget = 500, "long hold skips five minutes")
    handleVodKey("right", false)
    assertThat(m.video.seek = 500, "release seeks once to preview target")
    assertThat(m.video.autoplayAfterSeek, "playing video resumes after seek")
    assertThat(m.seekKey = "" and m.seekTimer.control = "stop", "release stops repeat timer")
    handleVodKey("right", true)
    assertThat(m.seekTarget = 510, "rapid next tap starts at pending target")
    handleVodKey("back", true)
    assertThat(m.seekTarget = 500 and m.video.seek = 500, "cancel restores pending target")
    m.video.position = 500
    onVodPosition()
    assertThat(not m.seekPending, "reported position clears pending seek")

    preparePlayer(true)
    handleVodKey("left", true)
    handleVodKey("left", false)
    assertThat(m.video.seek = 90 and not m.video.autoplayAfterSeek, "seek preserves pause")
    assertThat(m.vodPaused, "paused state retained")
    handleVodKey("play", true)
    assertThat(not m.vodPaused and m.video.control = "resume", "play resumes paused video")

    preparePlayer()
    handleVodKey("left", true)
    handleVodKey("right", true)
    handleVodKey("left", false)
    assertThat(m.seekKey = "right" and m.video.seek = invalid, "stale release does not commit changed direction")
    handleVodKey("back", true)
    assertThat(m.video.seek = invalid and m.seekKey = "", "back cancels without seeking")
    assertThat(m.video.control = "resume", "cancel resumes original playback")

    preparePlayer()
    m.video.position = 2
    handleVodKey("left", true)
    advanceVodSeek(10000)
    handleVodKey("left", false)
    assertThat(m.video.seek = 0, "rewind clamps at beginning")
    preparePlayer()
    m.video.position = 7195
    handleVodKey("right", true)
    advanceVodSeek(10000)
    handleVodKey("right", false)
    assertThat(m.video.seek = 7198, "forward clamps before ending")

    preparePlayer()
    m.isVod = false
    assertThat(not handleVodKey("right", true), "live playback keeps native controls")
    preparePlayer()
    m.video.state = "buffering"
    handleVodKey("right", true)
    assertThat(m.seekKey = "", "no seek before playback is ready")
    preparePlayer()
    handleVodKey("right", true)
    resetVodControls()
    assertThat(m.seekKey = "" and not m.vodHud.visible, "stop clears preview and HUD")
    preparePlayer()
    m.top.isInFocusChain = function() as boolean
        return false
    end function
    handleVodKey("right", true)
    onSeekTick()
    assertThat(m.seekKey = "" and m.video.seek = invalid, "losing focus cancels held seek")
    preparePlayer(true)
    handleVodKey("right", true)
    handleVodKey("back", true)
    assertThat(m.vodPaused and m.video.control = "pause", "cancel preserves paused playback")
    preparePlayer()
    handleVodKey("right", true)
    resetVodControls()
    handleVodKey("right", false)
    assertThat(m.video.seek = invalid, "late release after stopping does not seek")
    preparePlayer()
    m.top.hasFocus = function() as boolean
        return false
    end function
    handleVodKey("right", true)
    onSeekTick()
    assertThat(m.seekTarget = 120 and m.seekKey = "right", "timer continues when scene itself has no focus")
    onSeekTick()
    assertThat(m.seekTarget = 130, "timer advances on repeated callbacks")
    handleVodKey("right", false)
    assertThat(m.video.seek = 130, "long hold commits timer progress")

    preparePlayer()
    handleVodKey("play", true)
    handleVodKey("play", true)
    assertThat(m.vodPaused and m.video.control = "pause", "repeated play press cannot undo pause")
    assertThat(handleVodKey("play", false), "play release is consumed")
    assertThat(m.vodPaused, "play release preserves pause")
    m.video.state = "buffering"
    onVodState()
    m.video.state = "playing"
    onVodState()
    assertThat(m.vodPaused and m.video.control = "pause", "late playing event preserves user pause")
    assertThat(m.video.seek = invalid, "pause does not seek or restart recording")
    assertThat(m.playIcon.visible and not m.pauseIcon.visible, "paused UI shows play icon")
    handleVodKey("play", true)
    handleVodKey("play", false)
    assertThat(not m.vodPaused and m.video.control = "resume", "resume uses current video")
    assertThat(m.pauseIcon.visible and not m.playIcon.visible, "playing UI shows pause icon")
    preparePlayer()
    handleVodKey("right", true)
    handleVodKey("right", false)
    assertThat(handleVodKey("back", true), "back hides HUD after committing a seek")
    assertThat(not m.vodHud.visible and m.video.visible, "hiding HUD keeps VOD open")
    assertThat(m.video.seek = 110 and m.seekPending, "back does not undo committed seek")
    assertThat(handleVodKey("back", true), "held back cannot exit after hiding HUD")
    handleVodKey("back", false)
    m.video.state = "buffering"
    onVodState()
    m.video.state = "playing"
    onVodState()
    assertThat(not m.vodHud.visible, "late buffering and playing events keep HUD hidden")
    assertThat(not handleVodKey("back", true), "next back press can exit when HUD is hidden")
    handleVodKey("up", true)
    assertThat(m.vodHud.visible and not m.hudDismissed, "up explicitly shows HUD again")

    preparePlayer(true)
    showVodHud()
    handleVodKey("back", true)
    assertThat(not m.vodHud.visible and m.vodPaused, "back hides paused HUD without resuming")
    handleVodKey("back", false)
    onVodState()
    assertThat(not m.vodHud.visible, "paused state cannot reopen dismissed HUD")

    preparePlayer()
    handleVodKey("right", true)
    handleVodKey("back", true)
    assertThat(m.video.seek = invalid and not m.vodHud.visible, "back cancels preview and hides HUD")
    handleVodKey("right", false)
    assertThat(m.video.seek = invalid, "late release cannot commit cancelled preview")

    preparePlayer()
    onVodPosition()
    assertThat(m.vodHasPosition and m.lastVodPosition = 100, "record actual playback position")
    handleVodKey("right", true)
    advanceVodSeek(10000)
    onVodPosition()
    assertThat(m.lastVodPosition = 100, "preview target is never saved as watched progress")
    handleVodKey("right", false)
    onVodPosition()
    assertThat(m.lastVodPosition = 100, "pending seek keeps last confirmed progress")
    m.video.position = m.seekTarget
    onVodPosition()
    assertThat(m.lastVodPosition = 410 and not m.seekPending, "confirmed seek updates progress")
    preparePlayer()
    m.seekTarget = 2000.0
    m.seekPending = true
    m.video.position = 0.0
    m.video.state = "buffering"
    onVodPosition()
    assertThat(not m.vodHasPosition, "startup zero cannot overwrite saved resume point")
    m.video.position = 1996.0
    m.video.state = "playing"
    onVodPosition()
    assertThat(m.vodHasPosition and m.lastVodPosition = 1996, "resumed playback records actual segment position")
    print "PASS: "; m.checks; " VOD control checks"
end sub
