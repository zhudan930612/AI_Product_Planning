---
name: global-skill-sync
description: 执行跨客户端的全局技能同步并做一致性校验。触发词：同步技能、全局技能同步、global skill sync。用于在修改 ~/.agents/skills、skills-manifest.json 或 .skill-lock.json 后，将变更同步到 Claude、Cursor、Gemini、Codex。
---

# Global Skill Sync

将共享技能源 `~/.agents/skills` 的变更同步到所有客户端，并输出标准化结果：各目录数量、专属技能、审计摘要和最终结论。

## Trigger Phrases
- 同步技能
- 全局技能同步
- global skill sync

## Bundled Scripts
- `scripts/global-skill-sync.ps1`（默认入口）
- `scripts/skills-sync.ps1`
- `scripts/skills-audit.ps1`

## Workflow
1. 在技能目录执行默认命令：
`powershell -ExecutionPolicy Bypass -File .\scripts\global-skill-sync.ps1`

2. 若需要严格模式：
`powershell -ExecutionPolicy Bypass -File .\scripts\global-skill-sync.ps1 -Strict`

## Output Contract
- Sync Status（已同步客户端 / 未找到目录并跳过的客户端）
- Folder Counts（shared/claude/cursor/gemini/codex）
- Dedicated Skills（各客户端相对 shared 的专属技能）
- Audit Summary（blocking/warning/info/建议退出码）
- Conclusion（同步成功 / 存在问题）

## Behavior Rules
- 默认执行“同步 + 审计 + 结果汇总”，不进行其他业务改动。
- `-DryRun` 仅做模拟同步并照常输出检查结果。
