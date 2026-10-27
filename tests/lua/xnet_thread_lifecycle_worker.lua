return {
    __init = function()
        assert(xnet.init())
        assert(xnet.init()) -- Idempotent within this thread.
        assert(xthread.post(1, 'ready'))
    end,
    __thread_handle = function() end,
    __uninit = function()
        xnet.uninit()
        xnet.uninit()
    end,
}
