discard """
  file: "tasyncconnect.nim"
  exitcode: 1
  outputsub: "Error: unhandled exception: Connection refused [Exception]"
"""

import
    asyncdispatch,
    posix


const
    testHost = "127.0.0.1"
    testPort = Port(17357)


when defined(windows) or defined(nimdoc):
    discard
else:
    proc testAsyncConnect() {.async.} =
        var s = newAsyncRawSocket()

        await s.connect(testHost, testPort)

        var peerAddr: SockAddr
        var addrSize = Socklen(sizeof(peerAddr))
        var ret = SocketHandle(s).getpeername(addr(peerAddr), addr(addrSize))

        if ret < 0:
            echo("`connect(...)` failed but no exception was raised.")
            quit(2)

    waitFor(testAsyncConnect())
