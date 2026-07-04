# Codex Workflows Prompt Pad

Projeto local para versionar o fluxo de atalhos NUM do Codex:

- skill global `codex-workflows`;
- agents customizados `scout`, `reviewer`, `worker`;
- `AGENTS.md` global reduzido;
- AutoHotkey prompt pad.

## Layout

```text
skills/codex-workflows/   Codex skill instalavel em ~/.agents/skills
agents/                   Perfis de subagents para ~/.codex/agents
codex/AGENTS.md           Instrucoes globais compactas
ahk/codex_prompt_pad.ahk  Prompt pad AutoHotkey
scripts/install.ps1       Reinstala os arquivos nos destinos reais
scripts/validate.ps1      Valida estrutura e AHK
```

## Instalar

```powershell
.\scripts\install.ps1
```

## Validar

```powershell
.\scripts\validate.ps1
```

## Atalhos

```text
NUM0   $codex-workflows mode=PLAN simple no-edits
NUM0+1 $codex-workflows mode=P.DEEP repo no-edits deep-plan parallel-ready
NUM0+2 $codex-workflows mode=IMPL.PHASE approved-roadmap goal-managed phased parallel-safe
NUM1   $codex-workflows mode=IMPL approved smallest-safe-diff
NUM2   $codex-workflows mode=REVIEW diff no-edits strict
NUM3   $codex-workflows mode=COMMIT worktree
NUM4   $codex-workflows mode=BUG.INV no-edits evidence-first
NUM5   $codex-workflows mode=BUG.FIX approved regression-safe
NUM6   $codex-workflows mode=DEBUG e2e root-cause-first
NUM7   $codex-workflows mode=REWORK plan no-edits code-judo
NUM8   $codex-workflows mode=R.A.F.V repo fix-until-P2 no-commit
NUM9   $codex-workflows mode=TN.SKILL repo no-edits full-pass
```
