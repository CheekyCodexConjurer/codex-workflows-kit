#Requires AutoHotkey v2.0
#SingleInstance Force

SendMode "Input"
SetWorkingDir A_ScriptDir
SetScrollLockState "Off"

PromptPadNative := false

ShowStatus(text) {
    ToolTip text
    SetTimer () => ToolTip(), -900
}

BackendOverrideText() {
    backend := "m" . "cp"
    worker := "Deep" . "Seek"
    tools := "deep" . "seek_spawn/deep" . "seek_continue/deep" . "seek_consult/deep" . "seek_follow"
    visualRule := "When visual input is relevant, the parent GPT owns vision. Inspect the image yourself and pass a concise visual_context to " . worker . " containing task-relevant direct observations, visible text, interpretation, and uncertainty. Do not delegate image interpretation blindly when the parent can provide better visual evidence."
    return "subagents=" . backend . "; use " . worker . " via " . tools . "; parent GPT is the orchestrator, integrator, and validator; readers analyze/test and writers edit/worktree only when the mode authorizes; do not wait or poll unnecessarily; use follow only when no independent work remains; continue the same agent/session for fixes; independently review after a writer; no-edit modes remain no-edit; commit/push remain parent-controlled. " . visualRule
}

WorkflowPrompt(workflow) {
    global PromptPadNative
    prefix := "$workflows mode="
    mode := SubStr(workflow, StrLen(prefix) + 1)
    if (PromptPadNative) {
        return prefix . mode . " subagents=native"
    }
    return prefix . mode . " " . BackendOverrideText()
}

PastePrompt(text) {
    savedClipboard := ClipboardAll()
    A_Clipboard := WorkflowPrompt(text)

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

^ScrollLock:: {
    global PromptPadNative
    PromptPadNative := !PromptPadNative
    ShowStatus "Sub-agents: " . (PromptPadNative ? "Native" : "M" . "CP")
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

#HotIf
