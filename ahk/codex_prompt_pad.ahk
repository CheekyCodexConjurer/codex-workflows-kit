#Requires AutoHotkey v2.0
#SingleInstance Force

; Codex Workflows PromptPad
; Contract: Transports canonical mode, policy, and backend commands directly.
; Strict boundaries: No hardcoded agent counts, no resetting of swarm/continuation flags, and no hidden hooks.

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
Numpad0::PastePrompt("$workflows mode=PLAN.AUTO")

Numpad1::PastePrompt("$workflows mode=DELIVER.AUTO")

Numpad2::PastePrompt("$workflows mode=REVIEW")

Numpad3::PastePrompt("$workflows mode=COMMIT")

Numpad4::PastePrompt("$workflows mode=BUG.INV")

Numpad5::PastePrompt("$workflows mode=BUG.FIX")

Numpad6::PastePrompt("$workflows mode=DEBUG")

Numpad7::PastePrompt("$workflows mode=R.A.F.V")

Numpad8::PastePrompt("$workflows mode=REWORK")

Numpad9::PastePrompt("$workflows mode=RESEARCH.DEEP")

; --- Control Commands (Ctrl + Numpad) ---
^Numpad1::PastePrompt(".\scripts\switch-subagent-backend.ps1 -Backend native")

^Numpad2::PastePrompt(".\scripts\switch-subagent-backend.ps1 -Backend deepseek")

^Numpad4::PastePrompt(".\scripts\switch-subagent-policy.ps1 -Policy balanced")

^Numpad5::PastePrompt(".\scripts\switch-subagent-policy.ps1 -Policy aggressive")

^Numpad6::PastePrompt(".\scripts\switch-subagent-policy.ps1 -Policy swarm")

^Numpad0::PastePrompt(".\scripts\switch-subagent-backend.ps1 -Status")

#HotIf
