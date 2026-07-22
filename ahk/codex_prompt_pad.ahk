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

Numpad1::PastePrompt("$codex-workflows mode=PLAN.AUTO")

Numpad2::PastePrompt("$codex-workflows mode=DELIVER.AUTO")

Numpad0 & Numpad3::PastePrompt("$codex-workflows mode=RESEARCH.DEEP")

Numpad3::PastePrompt("$codex-workflows mode=COMMIT")

Numpad4::PastePrompt("$codex-workflows mode=BUG.INV")

Numpad5::PastePrompt("$codex-workflows mode=BUG.FIX")

Numpad6::PastePrompt("$codex-workflows mode=DEBUG")

Numpad7::PastePrompt("$codex-workflows mode=REWORK")

Numpad8::PastePrompt("$codex-workflows mode=R.A.F.V")

Numpad9::PastePrompt("$codex-workflows mode=TN.SKILL")

Numpad0 & Numpad7::PastePrompt("$audiobook-codex stage=MAP native-only source{PDF|EPUB} library-root{E:\Pessoal\e-books} output{book-map.json|assets-manifest.json} visual-fallback{pdf|computer} swarm{bounded}")

Numpad0 & Numpad8::PastePrompt("$audiobook-codex stage=TRANSCRIBE native-only input{book-map.json|assets-manifest.json} output{text/source|epub-manifest.json} fidelity=strict ledger=required epub-profile{antique-paper}")

Numpad0 & Numpad9::PastePrompt("$audiobook-codex stage=RENDER native-only input{text/source|epub-manifest.json} output{text/locutor|audio|epub|publish-root} tts{chatterbox-pt-br} voice-profile{feminina-v1} locutor{line-delimited-v1|max=320} language=pt-BR epub-profile{antique-paper} epub-images{original|approved-restored} restoration=review-required")

#HotIf
