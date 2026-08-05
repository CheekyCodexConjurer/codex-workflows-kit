#Requires AutoHotkey v2.0
#SingleInstance Force

SendMode "Input"
SetWorkingDir A_ScriptDir
SetScrollLockState "Off"

ShowStatus(text) {
    ToolTip text
    SetTimer () => ToolTip(), -900
}

PastePrompt(text) {
    savedClipboard := ClipboardAll()
    A_Clipboard := text

    if !ClipWait(1) {
        A_Clipboard := savedClipboard
        ShowStatus "Clipboard indisponivel"
        return
    }

    Send "^v"
    Sleep 80
    A_Clipboard := savedClipboard
}

ScrollLock:: {
    isOn := GetKeyState("ScrollLock", "T")
    SetScrollLockState isOn ? "Off" : "On"
    ShowStatus isOn ? "Prompt pad: OFF" : "Prompt pad: ON"
}

#HotIf GetKeyState("ScrollLock", "T")

; --- Universal Workflows (direct Numpad) ---
Numpad1::PastePrompt("$workflows mode=PLAN.AUTO")

Numpad2::PastePrompt("$workflows mode=DELIVER.AUTO")

Numpad3::PastePrompt("$workflows mode=COMMIT")

Numpad4::PastePrompt("$workflows mode=BUG.INV")

Numpad5::PastePrompt("$workflows mode=BUG.FIX")

Numpad6::PastePrompt("$workflows mode=DEBUG")

Numpad7::PastePrompt("$workflows mode=REWORK")

Numpad8::PastePrompt("$workflows mode=R.A.F.V")

Numpad9::PastePrompt("$workflows mode=TN.SKILL")

NumpadMult::PastePrompt("$workflows mode=RESEARCH.DEEP")

; --- Deep modes (Numpad0 + Numpad, fases mais profundas) ---
Numpad0 & Numpad1::PastePrompt("$workflows mode=P.DEEP")

Numpad0 & Numpad2::PastePrompt("$workflows mode=IMPL.PHASE")

Numpad0 & Numpad3::PastePrompt("$workflows mode=COMMIT")

Numpad0 & Numpad4::PastePrompt("$workflows mode=BUG.INV")

Numpad0 & Numpad5::PastePrompt("$workflows mode=BUG.FIX")

Numpad0 & Numpad6::PastePrompt("$workflows mode=DEBUG")

Numpad0 & Numpad7::PastePrompt("$workflows mode=REWORK")

Numpad0 & Numpad8::PastePrompt("$workflows mode=R.A.F.V")

Numpad0 & Numpad9::PastePrompt("$workflows mode=TN.SKILL")

Numpad0 & NumpadMult::PastePrompt("$workflows mode=RESEARCH.DEEP")

; --- Antigravity Slash Commands (Alt + Numpad) ---
!Numpad1::PastePrompt("/goal")

!Numpad2::PastePrompt("/grill-me")

!Numpad3::PastePrompt("/browser")

!Numpad4::PastePrompt("/schedule")

!Numpad5::PastePrompt("/teamwork-preview")

!Numpad6::PastePrompt("/learn")

#HotIf
