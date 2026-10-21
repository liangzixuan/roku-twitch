sub Main()
    screen = CreateObject("roSGScreen")
    port = CreateObject("roMessagePort")
    screen.setMessagePort(port)
    screen.CreateScene("MainScene")
    screen.show()
    while true
        message = wait(0, port)
        if type(message) = "roSGScreenEvent"
            if message.isScreenClosed() then return
        end if
    end while
end sub
