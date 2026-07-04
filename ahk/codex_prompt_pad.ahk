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

; Mapa escolhido
Numpad0::PastePrompt("$codex-workflows mode=PLAN simple no-edits")

Numpad0 & Numpad1::PastePrompt("$codex-workflows mode=P.DEEP repo no-edits deep-plan parallel-ready")

Numpad0 & Numpad2::PastePrompt("$codex-workflows mode=IMPL.PHASE approved-roadmap goal-managed phased parallel-safe")

Numpad1::PastePrompt("$codex-workflows mode=IMPL approved smallest-safe-diff")

Numpad3::PastePrompt("$codex-workflows mode=COMMIT worktree")

Numpad4::PastePrompt("$codex-workflows mode=BUG.INV no-edits evidence-first")

Numpad5::PastePrompt("$codex-workflows mode=BUG.FIX approved regression-safe")

Numpad6::PastePrompt("$codex-workflows mode=DEBUG e2e root-cause-first")

Numpad2::PastePrompt("$codex-workflows mode=REVIEW diff no-edits strict")

Numpad7::PastePrompt("$codex-workflows mode=REWORK plan no-edits code-judo")

Numpad8::PastePrompt("$codex-workflows mode=R.A.F.V repo fix-until-P2 no-commit")

Numpad9::PastePrompt("$codex-workflows mode=TN.SKILL repo no-edits full-pass")

#HotIf
