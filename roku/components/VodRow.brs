sub onContent()
    item = m.top.itemContent
    if item = invalid then return
    m.top.findNode("title").text = item.title
    m.top.findNode("detail").text = item.shortDescriptionLine1
    m.top.findNode("progress").visible = item.showProgress = true
    m.top.findNode("fill").width = 676 * item.progressRatio
end sub

sub onFocus()
    m.top.findNode("highlight").opacity = m.top.focusPercent
end sub
