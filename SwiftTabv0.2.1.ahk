;==============================================================================
;  SwiftTab - compact Alt+Tab replacement for Windows 10/11 (AutoHotkey v2)
;
;  Alt+Tab / Alt+Shift+Tab   open / step (release Alt to switch; quick tap = no UI)
;  Alt+`                     same-app windows only (like macOS Cmd+`)
;  Ctrl+Alt+Space            open straight into search mode
;  While open:
;    Tab, Down, Up           move (wraps)         Right/Left/Home/End  move
;    Enter or release Alt    switch               Esc                  cancel
;    Delete / click the x    close that window    1-9                  jump to nth
;    Shift+Delete/Shift+x    force-kill its whole process (not UWP/explorer)
;    /                       search (type, Enter) m                    this-monitor-only
;    click a row / the preview   switch to it     Close button under preview: close it
;    hover a row             previews that window (selection is unchanged)
;
;  Design notes
;   - Window list = EnumWindows (z-order == recency). No hooks/timers while idle.
;   - GUI is built and warmed once at startup; the list is prepared in the
;     background during ShowDelay, so showing it is just one Show call.
;   - Overlay appears after ShowDelay ms; a quick tap switches with zero flicker.
;   - After a close request, a window that shows a save prompt is brought to front.
;   - Filters: visible, not cloaked (other virtual desktops / suspended UWP),
;     owner/toolwindow rules from the real Alt+Tab, plus your hide lists.
;   - Live DWM thumbnail of the selected window (never a stale/blank cache).
;==============================================================================
#Requires AutoHotkey v2.0
#SingleInstance Force

;--------------------------------- CONFIG -------------------------------------
Cfg := {
    ShowDelay: 40,               ; ms before overlay appears (0 = immediately)
    SurfaceMs: 500,              ; after closing, a window still alive this long is brought forward
    Preview: true,               ; live thumbnail of selected window
    HoverPreview: true,          ; hovering a row shows that window in the preview
    MaxRows: 12,                 ; rows before the list scrolls
    ShowOn: "active",            ; "active" | "mouse" | "primary" monitor
    OnlyCurrentMonitor: false,   ; start with this-monitor-only filter on
    Wrap: true,                  ; Tab wraps around at the ends
    Icon: 24, Font: "Segoe UI", FontSize: 10,
    Bg: "202020", Fg: "F0F0F0", EditBg: "2D2D2D", BtnBg: "3A3A3A",
    ListW: 520, PreviewW: 420, PreviewMinH: 280,
    AdminMode: false,            ; true = relaunch elevated so elevated windows work
    BypassD3DFullscreen: true,   ; exclusive-fullscreen games get native Alt+Tab
    BypassExe: [],   ; games that get the native Alt+Tab (add yours)
    HideExe: []                  ; e.g. ["TextInputHost.exe"]
}

Lookup(arr) {
    m := Map()
    m.CaseSense := false
    for v in arr
        m[v] := 1
    return m
}
BypassExe := Lookup(Cfg.BypassExe), HideExe := Lookup(Cfg.HideExe)
HideCls := Lookup(["Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd"
    , "XamlExplorerHostIslandWindow", "MultitaskingViewFrame", "Windows.UI.Core.CoreWindow"])

;--------------------------------- STARTUP ------------------------------------
if Cfg.AdminMode && !A_IsAdmin {
    try Run('*RunAs "' (A_IsCompiled ? A_ScriptFullPath : A_AhkPath '" "' A_ScriptFullPath) '"')
    ExitApp
}
ProcessSetPriority "AboveNormal"
ListLines false
KeyHistory 0
SetWinDelay -1
SetKeyDelay -1
A_MaxHotkeysPerInterval := 1000000
A_IconTip := "SwiftTab"
A_MenuMaskKey := "vk07"                ; dummy key used to mask Alt-up: an unassigned key, so games never see Ctrl

; state
gAll := [], gShown := [], gTmp := [], gSel := 1
gActive := false, gVisible := false, gSearching := false
gOrig := 0, gSame := "", gMonOnly := false, gMonH := 0, gQuery := ""
gTh := 0, gRowH := 0, gX := 0, gY := 0, gHost := 0, gFound := 0
PvX := 0, PvY := 0, PvH := 0, gPrep := false, gW := 0, gH := 0, gHover := 0
IconIdx := Map(), PidCache := Map(), TB := Buffer(2048), CB := Buffer(512)
EnumCb := CallbackCreate(EnumProc, "Fast", 2)
ChildCb := CallbackCreate(ChildProc, "Fast", 2)

; metrics
S := A_ScreenDPI / 96
Pad := Round(10 * S), EdH := Round(30 * S), ExeW := Round(150 * S), CloseW := Round(40 * S)
BarH := Round(32 * S)                 ; close-button bar above the preview
gCloseX := 0                         ; x (in list coords) where the close column starts
ListW := Round(Cfg.ListW * S), PvW := Round(Cfg.PreviewW * S)
PvMinH := Round(Cfg.PreviewMinH * S), IcoPx := Round(Cfg.Icon * S)

; GUI (created once, shown/hidden on demand)
G := Gui("+AlwaysOnTop -Caption +ToolWindow +Border -DPIScale", "SwiftTab")
G.BackColor := Cfg.Bg
G.SetFont("s" Cfg.FontSize " c" Cfg.Fg, Cfg.Font)
Ed := G.AddEdit("x" Pad " y" Pad " w" ListW " h" EdH " Hidden -E0x200 Background" Cfg.EditBg)
LV := G.AddListView("x" Pad " y" Pad " w" ListW " h100 -Hdr -Multi NoSort +LV0x10000 -E0x200"
    " Background" Cfg.Bg " c" Cfg.Fg, ["Window", "App", ""])
IL := DllCall("comctl32\ImageList_Create", "Int", IcoPx, "Int", IcoPx, "UInt", 0x21
    , "Int", 16, "Int", 16, "Ptr")
LV.SetImageList(IL, 1)
PvHit := G.AddText("x0 y0 w10 h10 +0x100 BackgroundTrans")            ; clickable preview area
PvBtn := G.AddText("x0 y0 w10 h10 +0x100 +0x200 Center Background" Cfg.BtnBg
    , "×  Close window   (Shift+click: kill process)")
if !Cfg.Preview
    PvHit.Visible := false, PvBtn.Visible := false
PvHit.OnEvent("Click", (*) => Commit())
PvBtn.OnEvent("Click", (*) => CloseRow(gSel, GetKeyState("Shift", "P")))
DllCall("uxtheme\SetWindowTheme", "Ptr", LV.Hwnd, "Str", "DarkMode_Explorer", "Ptr", 0)
DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", G.Hwnd, "Int", 20, "Int*", 1, "Int", 4) ; dark frame
DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", G.Hwnd, "Int", 33, "Int*", 2, "Int", 4) ; round corners (Win11)
DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", G.Hwnd, "Int", 3, "Int*", 1, "Int", 4)  ; no show/hide animation = snappier
LV.OnNotify(-2, LVClick)                                       ; NM_CLICK
LV.OnEvent("ItemSelect", (c, i, sel) => sel && i != gSel && SyncSel(i))
Ed.OnEvent("Change", OnQuery)
OnMessage(0x0006, WmActivate)
OnMessage(0x0200, WmMouseMove)                                  ; hover preview
OnMessage(0x02A3, WmMouseLeave)

HotIf(NoSearch)                      ; Alt-less digit jump: 1..9
Loop 9
    Hotkey("*" A_Index, Pick.Bind(A_Index))
HotIf()
G.Show("x-32000 y-32000 w60 h60 NA"), G.Hide()                         ; warm up window + theme once
try for w in Enumerate()                                              ; warm up icon cache
    GetIcon(w)
DllCall("psapi\EmptyWorkingSet", "Ptr", DllCall("GetCurrentProcess", "Ptr"))

;--------------------------------- HOTKEYS ------------------------------------
#HotIf !gActive && !Bypass()
$!Tab::Open(1)
$!+Tab::Open(-1)
$!sc029::Open(1, true)               ; Alt+` (scancode of the key above Tab)
$!+sc029::Open(-1, true)
^!Space::Open(1, false, true)

#HotIf gActive
*Tab::Step(GetKeyState("Shift", "P") ? -1 : 1)
*sc029::Step(GetKeyState("Shift", "P") ? -1 : 1)
*Down::Step(1)
*Up::Step(-1)
*Esc::Cancel()
*Enter::Commit()
*NumpadEnter::Commit()

#HotIf gActive && !gSearching
*Right::Step(1)
*Left::Step(-1)
*Home::Go(1)
*End::Go(gShown.Length)
*Delete::CloseRow(gSel, GetKeyState("Shift", "P"))
*/::EnterSearch()
*m::ToggleMon()
#HotIf

;--------------------------------- SESSION ------------------------------------
NoSearch(*) => gActive && !gSearching

Open(dir, same := false, search := false) {
    global gAll, gActive, gVisible, gOrig, gSame, gMonOnly, gMonH, gQuery, gSel, gPrep
    gAll := Enumerate()
    gOrig := fg := DllCall("GetForegroundWindow", "Ptr")
    gSame := same ? WinPath(fg) : ""
    gMonOnly := Cfg.OnlyCurrentMonitor
    gMonH := DllCall("MonitorFromWindow", "Ptr", fg, "UInt", 2, "Ptr")
    gQuery := ""
    Refilter()
    n := gShown.Length
    if !n
        return
    root := DllCall("GetAncestor", "Ptr", fg, "UInt", 3, "Ptr")
    i := (dir < 0) ? n : (gShown[1].hwnd = root ? 2 : 1)   ; skip the window we're already on
    gSel := Min(i, n)
    gActive := true, gVisible := false, gPrep := false
    if search
        EnterSearch()
    else {
        SetTimer(AltPoll, 12)                              ; robust "Alt released" detection
        SetTimer(Prep, -1)                                 ; build the list while we wait
        SetTimer(ShowUI, -Max(Cfg.ShowDelay, 1))   ; (0 would delete the timer)
    }
}

AltPoll() {
    if !gSearching && !GetKeyState("LAlt", "P") && !GetKeyState("RAlt", "P")
        Commit()
}

Commit(i := 0) {
    global gActive
    if !gActive
        return
    if !i
        i := gVisible ? (LV.GetNext() || gSel) : gSel
    w := gShown.Has(i) ? gShown[i] : 0
    gActive := false                                       ; so WM_ACTIVATE handler ignores us
    if w
        Activate(w.hwnd)
    End()
}

Cancel(restore := true) {
    if !gActive
        return
    o := gOrig, was := gVisible
    End()
    if restore && was && DllCall("IsWindow", "Ptr", o)
        try WinActivate("ahk_id " o)
}

End() {
    global gActive := false, gVisible := false, gSearching := false, gQuery := "", gPrep := false, gHover := 0
    SetTimer(AltPoll, 0), SetTimer(ShowUI, 0), SetTimer(Prep, 0), SetTimer(Thumb, 0)
    Unthumb()
    G.Hide()
    Ed.Value := ""
    Ed.Visible := false
}

Activate(h) {
    p := DllCall("GetLastActivePopup", "Ptr", h, "Ptr")    ; same as native: focus the dialog if any
    if p != h && DllCall("IsWindowVisible", "Ptr", p) && DllCall("IsWindowEnabled", "Ptr", p)
        h := p
    try WinActivate("ahk_id " h)                           ; restores if minimized, handles foreground lock
}

WmActivate(wp, lp, msg, hwnd) {                            ; click-away dismisses search mode
    if hwnd = G.Hwnd && gSearching && gActive && !(wp & 0xFFFF)
        SetTimer(() => Cancel(false), -1)
}

WmMouseMove(wp, lp, msg, hwnd) {                           ; which list row is under the mouse?
    global gHover
    if !Cfg.HoverPreview || !gVisible || hwnd != LV.Hwnd
        return
    ht := Buffer(24, 0)                                    ; LVHITTESTINFO
    NumPut("Int", lp << 48 >> 48, "Int", lp << 32 >> 48, ht)   ; signed x, y from lParam
    SendMessage(0x1012, 0, ht, LV.Hwnd)                    ; LVM_HITTEST
    row := NumGet(ht, 12, "Int") + 1
    if !gShown.Has(row)
        row := 0
    if row = gHover
        return
    if row && !gHover {                                    ; ask Windows to tell us when the mouse leaves
        tme := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
        NumPut("UInt", tme.Size, "UInt", 2, "Ptr", LV.Hwnd, tme)   ; TME_LEAVE
        DllCall("TrackMouseEvent", "Ptr", tme)
    }
    gHover := row
    Thumb()
}

WmMouseLeave(wp, lp, msg, hwnd) {                          ; mouse left the list: back to the selected window
    global gHover
    if hwnd = LV.Hwnd && gHover {
        gHover := 0
        Thumb()
    }
}

Bypass() {
    static t := 0, v := false
    if Cfg.BypassD3DFullscreen {
        if A_TickCount - t > 1000 {                        ; shell call is slow-ish: cache for 1s
            DllCall("shell32\SHQueryUserNotificationState", "Int*", &s := 0)
            v := (s = 3), t := A_TickCount                 ; QUNS_RUNNING_D3D_FULL_SCREEN
        }
        if v
            return true
    }
    if BypassExe.Count {
        PidCache.Clear()
        SplitPath(WinPath(DllCall("GetForegroundWindow", "Ptr")), &exe)
        return BypassExe.Has(exe)
    }
    return false
}

;--------------------------------- NAVIGATION ---------------------------------
Step(d) {
    n := gShown.Length
    if !gActive || !n
        return
    i := gSel + d
    Go(Cfg.Wrap ? Mod(i - 1 + n, n) + 1 : Min(Max(i, 1), n))
}

Go(i) {
    global gSel, gHover
    if !gActive || !gShown.Length
        return
    if !gVisible
        ShowUI()
    gSel := i, gHover := 0                                 ; keyboard wins over a resting mouse
    LV.Modify(i, "Select Focus Vis")
    Thumb()
}

SyncSel(i) {
    global gSel := i
    Thumb()
}

Pick(n, *) {
    if gShown.Has(n)
        Commit(n)
}

LVClick(ctrl, lp) {                                        ; NM_CLICK on the list
    h := 3 * A_PtrSize                                     ; NMITEMACTIVATE: iItem right after NMHDR
    row := NumGet(lp, h, "Int") + 1
    x := NumGet(lp, h + 20, "Int")                         ; ptAction.x (list client coords)
    if !gShown.Has(row)
        return
    if x >= gCloseX
        CloseRow(row, GetKeyState("Shift", "P"))           ; x column: close; Shift = kill process
    else
        Commit(row)
}

CloseRow(i, force := false) {
    global gSel
    if !gActive || !gShown.Has(i)
        return
    if !gVisible
        ShowUI()
    w := gShown[i]
    if force {                                             ; kill the whole process
        if w.uwp || w.exe = "explorer.exe" || w.pid = ProcessExist() {
            ToolTip("Can't force-close this one - use plain click to close the window")
            SetTimer(() => ToolTip(), -1800)
            return
        }
        try ProcessClose(w.pid)
        n := gAll.Length
        while n > 0 {                                      ; drop every window of that process
            if gAll[n].pid = w.pid
                gAll.RemoveAt(n)
            n--
        }
    } else {                                               ; polite close, like the X button
        PostMessage(0x10, 0, 0, , "ahk_id " w.hwnd)        ; WM_CLOSE
        SetTimer(WatchClose.Bind(w.hwnd, 0), -40)          ; surface "save changes?" prompts
        for j, x in gAll
            if x.hwnd = w.hwnd {
                gAll.RemoveAt(j)
                break
            }
    }
    Refilter()
    if !gShown.Length
        return Cancel()
    gSel := Min(i, gShown.Length)
    Redraw()
}

WatchClose(h, n) {
    if !DllCall("IsWindow", "Ptr", h) || !DllCall("IsWindowVisible", "Ptr", h)
        return                                             ; closed (or hid itself): nothing to do
    p := DllCall("GetLastActivePopup", "Ptr", h, "Ptr")
    dialog := (p != h && DllCall("IsWindowVisible", "Ptr", p)) || !DllCall("IsWindowEnabled", "Ptr", h)
    if dialog || n * 40 >= Cfg.SurfaceMs                   ; prompt appeared, or window refuses to go away
        return Surface(h)
    SetTimer(WatchClose.Bind(h, n + 1), -40)
}

Surface(h) {                                               ; bring a window/prompt forward, dismiss overlay
    global gActive
    Activate(h)                                            ; activate first, while we still hold foreground
    if gActive {
        gActive := false
        End()
    }
}

ToggleMon() {
    global gMonOnly := !gMonOnly
    Refilter(gShown.Length ? gShown[gSel].hwnd : 0)
    Redraw()
}

EnterSearch() {
    global gSearching := true, gPrep
    SetTimer(AltPoll, 0)
    Ed.Visible := true
    if gVisible
        Resize()
    else {
        gPrep := false
        ShowUI()
    }
    try WinActivate("ahk_id " G.Hwnd)
    Ed.Focus()
}

OnQuery(*) {
    global gQuery := Ed.Value
    Refilter()
    Redraw()
}

Refilter(keep := 0) {
    global gShown, gSel
    words := StrSplit(Trim(gQuery), " ")
    out := []
    for w in gAll {
        if gSame != "" && w.path != gSame
            continue
        if gMonOnly && DllCall("MonitorFromWindow", "Ptr", w.hwnd, "UInt", 2, "Ptr") != gMonH
            continue
        hay := w.title " " w.exe, ok := true
        for t in words
            if t != "" && !InStr(hay, t) {
                ok := false
                break
            }
        if ok
            out.Push(w)
    }
    gShown := out, gSel := 1
    if keep
        for i, w in out
            if w.hwnd = keep {
                gSel := i
                break
            }
}

;--------------------------------- WINDOW LIST --------------------------------
Enumerate() {
    global gTmp := []
    PidCache.Clear()
    DllCall("EnumWindows", "Ptr", EnumCb, "Ptr", 0)        ; top-to-bottom z-order = recency
    fg := DllCall("GetAncestor", "Ptr", DllCall("GetForegroundWindow", "Ptr"), "UInt", 3, "Ptr")
    front := [], back := []
    for w in gTmp {
        if w.top && w.hwnd != fg                           ; always-on-top windows don't hog the front
            back.Push(w)
        else
            front.Push(w)
    }
    for w in back
        front.Push(w)
    return front
}

EnumProc(hwnd, lp) {
    global gTmp, gHost, gFound
    if !DllCall("IsWindowVisible", "Ptr", hwnd) || hwnd = G.Hwnd
        return 1
    ex := DllCall("GetWindowLongW", "Ptr", hwnd, "Int", -20, "UInt")
    if !(ex & 0x40000) && ((ex & 0x80) || (ex & 0x08000000) || DllCall("GetWindow", "Ptr", hwnd, "UInt", 4, "Ptr"))
        return 1                                           ; toolwindow / noactivate / owned (unless APPWINDOW)
    DllCall("dwmapi\DwmGetWindowAttribute", "Ptr", hwnd, "UInt", 14, "UInt*", &cloaked := 0, "UInt", 4)
    if cloaked
        return 1                                           ; other virtual desktop or suspended UWP ghost
    n := DllCall("GetWindowTextW", "Ptr", hwnd, "Ptr", TB, "Int", 1024)   ; never blocks on hung apps
    if !n
        return 1
    DllCall("GetClassNameW", "Ptr", hwnd, "Ptr", CB, "Int", 256)
    if HideCls.Has(StrGet(CB, "UTF-16"))
        return 1
    pid := WinPid(hwnd), path := ProcPath(pid), uwp := false
    SplitPath(path, &exe)
    if exe = "ApplicationFrameHost.exe" {                  ; UWP: find the real app behind the frame
        gHost := pid, gFound := 0
        DllCall("EnumChildWindows", "Ptr", hwnd, "Ptr", ChildCb, "Ptr", 0)
        if gFound {
            pid := gFound
            path := ProcPath(pid)
            SplitPath(path, &exe)
        }
        uwp := true
    }
    if HideExe.Has(exe)
        return 1
    gTmp.Push({hwnd: hwnd, title: StrGet(TB, n, "UTF-16"), path: path, exe: exe
        , pid: pid, top: !!(ex & 8), uwp: uwp})
    return 1
}

ChildProc(hwnd, lp) {
    global gFound
    pid := WinPid(hwnd)
    if pid && pid != gHost {
        gFound := pid
        return 0
    }
    return 1
}

WinPid(hwnd) {
    DllCall("GetWindowThreadProcessId", "Ptr", hwnd, "UInt*", &pid := 0)
    return pid
}

WinPath(hwnd) => ProcPath(WinPid(hwnd))

ProcPath(pid) {
    static buf := Buffer(1040)
    if PidCache.Has(pid)
        return PidCache[pid]
    path := ""
    if pid && (h := DllCall("OpenProcess", "UInt", 0x1000, "Int", 0, "UInt", pid, "Ptr")) {
        sz := 520                                          ; limited-rights open works for elevated procs too
        if DllCall("QueryFullProcessImageNameW", "Ptr", h, "UInt", 0, "Ptr", buf, "UInt*", &sz)
            path := StrGet(buf, sz, "UTF-16")
        DllCall("CloseHandle", "Ptr", h)
    }
    return PidCache[pid] := path
}

GetIcon(w) {                                               ; cached per exe (per window for UWP)
    key := (w.uwp || w.path = "") ? w.hwnd : StrLower(w.path)
    if IconIdx.Has(key)
        return IconIdx[key]
    h := 0, own := false
    for t in [1, 2]                                        ; ICON_BIG, ICON_SMALL2
        if !h
            DllCall("SendMessageTimeoutW", "Ptr", w.hwnd, "UInt", 0x7F, "Ptr", t, "Ptr", 0
                , "UInt", 2, "UInt", 40, "Ptr*", &h)
    if !h
        h := DllCall("GetClassLongPtrW", "Ptr", w.hwnd, "Int", -14, "Ptr")
    if !h && w.path != "" {
        DllCall("shell32\ExtractIconExW", "Str", w.path, "Int", 0, "Ptr*", &h, "Ptr", 0, "UInt", 1)
        own := true
    }
    idx := h ? DllCall("comctl32\ImageList_ReplaceIcon", "Ptr", IL, "Int", -1, "Ptr", h, "Int") + 1 : 0
    if own && h
        DllCall("DestroyIcon", "Ptr", h)
    return IconIdx[key] := idx
}

;--------------------------------- RENDERING ----------------------------------
Prep() {                                                   ; runs right after Alt+Tab, during ShowDelay
    global gPrep
    if !gActive || gVisible || gPrep
        return
    Populate()
    Arrange()
    gPrep := true                                          ; only once it is complete
}

ShowUI() {
    global gVisible, gPrep, gX, gY
    if !gActive || gVisible
        return
    gVisible := true
    if !gPrep {
        Populate()
        Arrange()
        gPrep := true
    }
    wa := WorkArea(TargetMon())
    gX := wa.l + (wa.r - wa.l - gW) // 2
    gY := wa.t + (wa.b - wa.t - gH) // 2
    G.Show("x" gX " y" gY " w" gW " h" gH)
    SetTimer(Thumb, -1)                                    ; list first, thumbnail a moment later
}

Resize() {
    Arrange()
    G.Show("NA w" gW " h" gH)                              ; keep position, just resize
}

Redraw() {
    global gPrep
    if !gVisible {
        gPrep := false
        return ShowUI()
    }
    Populate()
    Resize()
    Thumb()
}

Populate() {
    global gHover := 0
    LV.Opt("-Redraw")
    LV.Delete()
    for w in gShown {
        ic := GetIcon(w)
        LV.Add(ic ? "Icon" ic : "", w.title, w.exe, "×")
    }
    LV.Opt("+Redraw")
    if gShown.Length
        LV.Modify(gSel, "Select Focus Vis")
}

RowH() {
    global gRowH
    if gRowH
        return gRowH
    if !LV.GetCount()
        return IcoPx + Round(8 * S)
    rc := Buffer(16, 0)                                    ; rc.left = 0 -> LVIR_BOUNDS
    SendMessage(0x100E, 0, rc, LV.Hwnd)                    ; LVM_GETITEMRECT
    gRowH := NumGet(rc, 12, "Int") - NumGet(rc, 4, "Int")
    if gRowH < 8
        gRowH := IcoPx + Round(8 * S)
    return gRowH
}

Arrange() {                                                ; position controls, compute window size
    global gW, gH, PvX, PvY, PvH, gCloseX
    n := gShown.Length
    listH := Min(Max(n, 1), Cfg.MaxRows) * RowH() + 4
    top := Pad + (gSearching ? EdH + Pad : 0)
    sb := n > Cfg.MaxRows ? DllCall("GetSystemMetrics", "Int", 2) : 0
    LV.Move(Pad, top, ListW, listH)
    c1 := ListW - ExeW - CloseW - sb - 6
    LV.ModifyCol(1, c1)
    LV.ModifyCol(2, ExeW)
    LV.ModifyCol(3, CloseW " Center")
    gCloseX := c1 + ExeW
    Ed.Move(Pad, Pad, ListW, EdH)
    blk := Max(listH, PvMinH)                              ; height of the right-hand preview block
    px := Pad * 2 + ListW
    PvX := px, PvY := top + BarH + Pad // 2, PvH := blk - BarH - Pad // 2
    if Cfg.Preview {
        PvBtn.Move(px, top, PvW, BarH)
        PvHit.Move(PvX, PvY, PvW, PvH)
    }
    gW := Pad * 2 + ListW + (Cfg.Preview ? Pad + PvW : 0)
    gH := top + (Cfg.Preview ? blk : listH) + Pad
}

TargetMon() {
    if Cfg.ShowOn = "mouse" {
        DllCall("GetCursorPos", "Int64*", &pt := 0)
        return DllCall("MonitorFromPoint", "Int64", pt, "UInt", 2, "Ptr")
    }
    if Cfg.ShowOn = "primary"
        return DllCall("MonitorFromPoint", "Int64", 0, "UInt", 1, "Ptr")
    return gMonH
}

WorkArea(hMon) {
    mi := Buffer(40, 0)
    NumPut("UInt", 40, mi)
    DllCall("GetMonitorInfoW", "Ptr", hMon, "Ptr", mi)
    return {l: NumGet(mi, 20, "Int"), t: NumGet(mi, 24, "Int"), r: NumGet(mi, 28, "Int"), b: NumGet(mi, 32, "Int")}
}

Unthumb() {
    global gTh
    if gTh {
        DllCall("dwmapi\DwmUnregisterThumbnail", "Ptr", gTh)
        gTh := 0
    }
}

Thumb() {                                                  ; live DWM thumbnail of the selected window
    global gTh
    Unthumb()
    if !(Cfg.Preview && gVisible && gShown.Length)
        return
    idx := gShown.Has(gHover) ? gHover : gSel               ; hovered row, else the selected one
    if DllCall("dwmapi\DwmRegisterThumbnail", "Ptr", G.Hwnd, "Ptr", gShown[idx].hwnd, "Ptr*", &t := 0, "UInt")
        return                                             ; failed (e.g. elevated source): just show no preview
    gTh := t
    sz := Buffer(8, 0)
    DllCall("dwmapi\DwmQueryThumbnailSourceSize", "Ptr", t, "Ptr", sz)
    sw := NumGet(sz, 0, "Int"), sh := NumGet(sz, 4, "Int")
    if sw < 1 || sh < 1
        return
    k := Min(PvW / sw, PvH / sh, 1.0)
    w := Round(sw * k), h := Round(sh * k)
    x := PvX + (PvW - w) // 2, y := PvY + (PvH - h) // 2
    p := Buffer(48, 0)                                     ; DWM_THUMBNAIL_PROPERTIES
    NumPut("UInt", 0x9, p, 0)                              ; RECTDESTINATION | VISIBLE
    NumPut("Int", x, "Int", y, "Int", x + w, "Int", y + h, p, 4)
    NumPut("Int", 1, p, 40)                                ; fVisible
    DllCall("dwmapi\DwmUpdateThumbnailProperties", "Ptr", t, "Ptr", p)
}
