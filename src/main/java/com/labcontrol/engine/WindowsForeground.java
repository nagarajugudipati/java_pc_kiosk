package com.labcontrol.engine;

import com.sun.jna.Native;
import com.sun.jna.Pointer;
import com.sun.jna.ptr.IntByReference;
import com.sun.jna.win32.StdCallLibrary;

final class WindowsForeground {
    private WindowsForeground() {}

    private interface User32 extends StdCallLibrary {
        Pointer GetForegroundWindow();
        int GetWindowThreadProcessId(Pointer window, IntByReference processId);
    }

    private static final class Windows {
        static final User32 API = Native.load("user32", User32.class);
    }

    static long processId() {
        Pointer window = Windows.API.GetForegroundWindow();
        if (window == null) return 0;
        IntByReference pid = new IntByReference();
        Windows.API.GetWindowThreadProcessId(window, pid);
        return Integer.toUnsignedLong(pid.getValue());
    }
}
