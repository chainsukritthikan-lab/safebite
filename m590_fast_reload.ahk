; =============================================
;  M590 Fast Reload - Free Fire PC
;  วิธีใช้: กด R เพื่อ fast reload M590
; =============================================

#NoEnv
#SingleInstance Force
SetWorkingDir %A_ScriptDir%

; ---- ตั้งค่า ----
ReloadKey := "r"       ; ปุ่ม reload ใน Free Fire
FireKey   := "LButton" ; ปุ่มยิง

; =============================================
;  Fast Reload M590
;  กด R -> รอ timing -> ยิงทันที (cancel reload)
; =============================================
~r::
    Sleep, 850          ; รอ animation M590 (ประมาณ 0.85 วิ)
    Send, {%FireKey% down}
    Sleep, 50
    Send, {%FireKey% up}
return

; =============================================
;  Double Tap Reload (กด R สองครั้งเร็วๆ)
; =============================================
~r Up::
    KeyWait, r, D T0.2
    if ErrorLevel = 0
    {
        Send, r
        Sleep, 50
    }
return

; กด F10 เพื่อ toggle script on/off
F10::
    Suspend, Toggle
    if A_IsSuspended
        ToolTip, Script OFF
    else
        ToolTip, Script ON
    Sleep, 1000
    ToolTip
return
