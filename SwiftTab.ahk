;==============================================================================
;  SwiftTab - compact Alt+Tab replacement for Windows 10/11 (AutoHotkey v2)
;
;  Alt+Tab / Alt+Shift+Tab   open / step (release Alt to switch; quick tap = no UI)
;  Alt+`                     same-app windows only (like macOS Cmd+`)
;  Ctrl+Alt+Space            open straight into search mode
;  While open:
;    Tab, Down, Up           move (wraps)         Right/Left/Home/End  move
;    Enter or release Alt    switch               Esc                  cancel
;    Delete                  close selected       1-9                  jump to nth
;    /                       search (type, Enter) m                    this-monitor-only
;    mouse click             switch to clicked row
;
;  Design notes
;   - Window list = EnumWindows (z-order == recency). No hooks/timers while idle.
;   - GUI is built once at startup, so showing it is just populate + Show.
;   - Overlay appears after ShowDelay ms; a quick tap switches with zero flicker.
;   - Filters: visible, not cloaked (other virtual desktops / suspended UWP),
;     owner/toolwindow rules from the real Alt+Tab, plus your hide lists.
;   - Live DWM thumbnail of the selected window (never a stale/blank cache).
;==============================================================================
#Requires AutoHotkey v2.0
#SingleInstance Force

;--------------------------------- CONFIG -------------------------------------
Cfg := {
    ShowDelay: 90,               ; ms before overlay appears (0 = immediately)
    Preview: true,               ; live thumbnail of selected window
    MaxRows: 12,                 ; rows before the list scrolls
    ShowOn: "active",            ; "active" | "mouse" | "primary" monitor
    OnlyCurrentMonitor: false,   ; start with this-monitor-only filter on
    Wrap: true,                  ; Tab wraps around at the ends
    Icon: 24, Font: "Segoe UI", FontSize: 10,
    Bg: "202020", Fg: "F0F0F0", EditBg: "2D2D2D",
    ListW: 520, PreviewW: 420, PreviewMinH: 280,
    AdminMode: false,            ; true = relaunch elevated so elevated windows work
    BypassD3DFullscreen: true,   ; exclusive-fullscreen games get native Alt+Tab
    BypassExe: [],               ; e.g. ["game.exe"] for borderless-fullscreen games
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

; state
gAll := [], gShown := [], gTmp := [], gSel := 1
gActive := false, gVisible := false, gSearching := false
gOrig := 0, gSame := "", gMonOnly := false, gMonH := 0, gQuery := ""
gTh := 0, gRowH := 0, gX := 0, gY := 0, gHost := 0, gFound := 0
PvX := 0, PvY := 0, PvH := 0
IconIdx := Map(), PidCache := Map(), TB := Buffer(2048), CB := Buffer(512)
EnumCb := CallbackCreate(EnumProc, "Fast", 2)
ChildCb := CallbackCreate(ChildProc, "Fast", 2)

; metrics
S := A_ScreenDPI / 96
Pad := Round(10 * S), EdH := Round(30 * S), ExeW := Round(150 * S)
ListW := Round(Cfg.ListW * S), PvW := Round(Cfg.PreviewW * S)
PvMinH := Round(Cfg.PreviewMinH * S), IcoPx := Round(Cfg.Icon * S)

; GUI (created once, shown/hidden on demand)
G := Gui("+AlwaysOnTop -Caption +ToolWindow +Border -DPIScale", "SwiftTab")
G.BackColor := Cfg.Bg
G.SetFont("s" Cfg.FontSize " c" Cfg.Fg, Cfg.Font)
Ed := G.AddEdit("x" Pad " y" Pad " w" ListW " h" EdH " Hidden -E0x200 Background" Cfg.EditBg)
LV := G.AddListView("x" Pad " y" Pad " w" ListW " h100 -Hdr -Multi NoSort +LV0x10000 -E0x200"
    " Background" Cfg.Bg " c" Cfg.Fg, ["Window", "App"])
IL := DllCall("comctl32\ImageList_Create", "Int", IcoPx, "Int", IcoPx, "UInt", 0x21
    , "Int", 16, "Int", 16, "Ptr")
LV.SetImageList(IL, 1)
DllCall("uxtheme\SetWindowTheme", "Ptr", LV.Hwnd, "Str", "DarkMode_Explorer", "Ptr", 0)
DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", G.Hwnd, "Int", 20, "Int*", 1, "Int", 4) ; dark frame
DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", G.Hwnd, "Int", 33, "Int*", 2, "Int", 4) ; round corners (Win11)
LV.OnEvent("Click", (c, row) => row && Commit(row))
LV.OnEvent("ItemSelect", (c, i, sel) => sel && i != gSel && SyncSel(i))
Ed.OnEvent("Change", OnQuery)
OnMessage(0x0006, WmActivate)

HotIf(NoSearch)                      ; Alt-less digit jump: 1..9
Loop 9
    Hotkey("*" A_Index, Pick.Bind(A_Index))
HotIf()
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
*Delete::CloseSel()
*/::EnterSearch()
*m::ToggleMon()
#HotIf

;--------------------------------- SESSION ------------------------------------
NoSearch(*) => gActive && !gSearching

Open(dir, same := false, search := false) {
    global gAll, gActive, gVisible, gOrig, gSame, gMonOnly, gMonH, gQuery, gSel
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
    gActive := true, gVisible := false
    if search
        EnterSearch()
    else {
        SetTimer(AltPoll, 12)                              ; robust "Alt released" detection
        SetTimer(ShowUI, -Cfg.ShowDelay)
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
    global gActive := false, gVisible := false, gSearching := false, gQuery := ""
    SetTimer(AltPoll, 0), SetTimer(ShowUI, 0)
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

Bypass() {
    if Cfg.BypassD3DFullscreen {
        DllCall("shell32\SHQueryUserNotificationState", "Int*", &s := 0)
        if s = 3                                           ; QUNS_RUNNING_D3D_FULL_SCREEN
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
    global gSel
    if !gActive || !gShown.Length
        return
    if !gVisible
        ShowUI()
    gSel := i
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

CloseSel() {
    if !gActive || !gShown.Length
        return
    if !gVisible
        ShowUI()
    h := gShown[gSel].hwnd, keep := gSel
    PostMessage(0x10, 0, 0, , "ahk_id " h)                 ; WM_CLOSE
    for i, w in gAll
        if w.hwnd = h {
            gAll.RemoveAt(i)
            break
        }
    Refilter()
    if !gShown.Length
        return Cancel()
    global gSel := Min(keep, gShown.Length)
    Redraw()
}

ToggleMon() {
    global gMonOnly := !gMonOnly
    Refilter(gShown.Length ? gShown[gSel].hwnd : 0)
    Redraw()
}

EnterSearch() {
    global gSearching := true
    SetTimer(AltPoll, 0)
    Ed.Visible := true
    if gVisible
        Layout()
    else
        ShowUI()
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
            path := ProcPath(gFound)
            SplitPath(path, &exe)
        }
        uwp := true
    }
    if HideExe.Has(exe)
        return 1
    gTmp.Push({hwnd: hwnd, title: StrGet(TB, n, "UTF-16"), path: path, exe: exe
        , top: !!(ex & 8), uwp: uwp})
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
ShowUI() {
    global gVisible
    if !gActive || gVisible
        return
    gVisible := true
    Populate()
    Layout(true)
    Thumb()
}

Redraw() {
    if !gVisible
        return ShowUI()
    Populate()
    Layout()
    Thumb()
}

Populate() {
    LV.Opt("-Redraw")
    LV.Delete()
    for w in gShown {
        ic := GetIcon(w)
        LV.Add(ic ? "Icon" ic : "", w.title, w.exe)
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

Layout(first := false) {
    global gX, gY, PvX, PvY, PvH
    n := gShown.Length
    listH := Min(Max(n, 1), Cfg.MaxRows) * RowH() + 4
    top := Pad + (gSearching ? EdH + Pad : 0)
    sb := n > Cfg.MaxRows ? DllCall("GetSystemMetrics", "Int", 2) : 0
    LV.Move(Pad, top, ListW, listH)
    LV.ModifyCol(1, ListW - ExeW - sb - 6)
    LV.ModifyCol(2, ExeW)
    Ed.Move(Pad, Pad, ListW, EdH)
    PvX := Pad * 2 + ListW, PvY := top
    PvH := Cfg.Preview ? Max(listH, PvMinH) : 0
    w := Pad * 2 + ListW + (Cfg.Preview ? Pad + PvW : 0)
    h := top + Max(listH, PvH) + Pad
    if first {
        wa := WorkArea(TargetMon())
        gX := wa.l + (wa.r - wa.l - w) // 2
        gY := wa.t + (wa.b - wa.t - h) // 2
        G.Show("x" gX " y" gY " w" w " h" h)
    } else
        G.Show("NA w" w " h" h)                            ; keep position, just resize
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
    if DllCall("dwmapi\DwmRegisterThumbnail", "Ptr", G.Hwnd, "Ptr", gShown[gSel].hwnd, "Ptr*", &t := 0, "UInt")
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
