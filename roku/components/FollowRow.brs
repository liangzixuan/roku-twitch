sub init()
    m.avatar = m.top.findNode("avatar")
    m.avatar.observeField("loadStatus", "onAvatarLoad")
    agent = CreateObject("roHttpAgent")
    agent.setCertificatesFile("common:/certs/ca-bundle.crt")
    m.avatar.setHttpAgent(agent)
end sub

sub onContent()
    item = m.top.itemContent
    if item = invalid then return
    m.top.findNode("name").text = item.title
    m.top.findNode("state").text = item.shortDescriptionLine1
    m.top.findNode("state").color = "0xBEB6CAFF"
    if item.live then m.top.findNode("state").color = "0xC7A4FFFF"
    m.top.findNode("initial").text = UCase(Left(item.title, 1))
    m.avatar.visible = false
    m.avatar.uri = item.hdPosterUrl
    onAvatarLoad()
end sub

sub onAvatarLoad()
    m.avatar.visible = m.avatar.loadStatus = "ready" and m.avatar.uri <> ""
end sub

sub onFocus()
    m.top.findNode("highlight").opacity = m.top.focusPercent
end sub
