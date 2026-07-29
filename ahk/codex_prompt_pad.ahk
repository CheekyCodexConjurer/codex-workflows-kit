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

; --- OpenCode Workflows (direct Numpad, com sub-agents) ---
Numpad1::PastePrompt("$opencode-workflows mode=PLAN.AUTO")

Numpad2::PastePrompt("$opencode-workflows mode=DELIVER.AUTO")

Numpad3::PastePrompt("$opencode-workflows mode=COMMIT")

Numpad4::PastePrompt("$opencode-workflows mode=BUG.INV")

Numpad5::PastePrompt("$opencode-workflows mode=BUG.FIX")

Numpad6::PastePrompt("$opencode-workflows mode=DEBUG")

Numpad7::PastePrompt("$opencode-workflows mode=REWORK")

Numpad8::PastePrompt("$opencode-workflows mode=R.A.F.V")

Numpad9::PastePrompt("$opencode-workflows mode=TN.SKILL")

NumpadMult::PastePrompt("$opencode-workflows mode=RESEARCH.DEEP")

; --- Deep modes (Numpad0 + Numpad, fases mais profundas) ---
Numpad0 & Numpad1::PastePrompt("$opencode-workflows mode=P.DEEP")

Numpad0 & Numpad2::PastePrompt("$opencode-workflows mode=IMPL.PHASE")

Numpad0 & Numpad3::PastePrompt("$opencode-workflows mode=COMMIT")

Numpad0 & Numpad4::PastePrompt("$opencode-workflows mode=BUG.INV")

Numpad0 & Numpad5::PastePrompt("$opencode-workflows mode=BUG.FIX")

Numpad0 & Numpad6::PastePrompt("$opencode-workflows mode=DEBUG")

Numpad0 & Numpad7::PastePrompt("$opencode-workflows mode=REWORK")

Numpad0 & Numpad8::PastePrompt("$opencode-workflows mode=R.A.F.V")

Numpad0 & Numpad9::PastePrompt("$opencode-workflows mode=TN.SKILL")

Numpad0 & NumpadMult::PastePrompt("$opencode-workflows mode=RESEARCH.DEEP")

; --- Antigravity Slash Commands (Alt + Numpad) ---
!Numpad1::PastePrompt("/goal")

!Numpad2::PastePrompt("/grill-me")

!Numpad3::PastePrompt("/browser")

!Numpad4::PastePrompt("/schedule")

!Numpad5::PastePrompt("/teamwork-preview")

!Numpad6::PastePrompt("/learn")

^Numpad7::PastePrompt("$audiobook-codex stage=MAP native-only source{PDF|EPUB} library-root{E:\Pessoal\e-books} output{book-map.json|assets-manifest.json} visual-fallback{pdf|computer} swarm{bounded}")

^Numpad8::PastePrompt("$audiobook-codex stage=TRANSCRIBE native-only input{book-map.json|assets-manifest.json} output{text/source|epub-manifest.json} fidelity=strict ledger=required epub-profile{antique-paper}")

^Numpad9::PastePrompt("$audiobook-codex stage=RENDER native-only input{text/source|epub-manifest.json} output{text/locutor|audio|epub|publish-root} tts{chatterbox-pt-br} voice-profile{feminina-v1} locutor{line-delimited-v1|max=320} language=pt-BR epub-profile{antique-paper} epub-images{original|approved-restored} restoration=review-required")

#HotIf
