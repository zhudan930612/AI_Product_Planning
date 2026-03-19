---
name: skills-governance-audit
description: 检查跨模型技能治理是否符合统一管理规范。触发词：检查技能治理、审计技能管理、skills governance audit、检查技能、审查技能、查看技能情况。
---

# Skills Governance Audit

只检查并生成报告，不做自动修复。核心目标是精简技能库，仅保留高频技能。

## Trigger Phrases
- 检查技能治理
- 审计技能管理
- skills governance audit
- 检查技能
- 审查技能
- 查看技能情况

## Command
`powershell -ExecutionPolicy Bypass -File .\scripts\skills-governance-audit.ps1 -Format markdown`

## Optional Params
- `-Strict`：将 warning 也视为失败（建议退出码=1）
- `-Format json`：输出结构化 JSON
- `-MinUsageToKeep <N>`：低于 N 次使用视为低频（默认 2）

## Output Contract
- Summary
- Client Skill Counts（各客户端技能数量与专属技能）
- Usage Log Sources（各客户端可用日志来源）
- Skill Usage Counts（每个技能使用命中次数）
- Suggested Removals（建议移除/低频候选）
- Findings
- Severity
- Suggested Fixes
- 建议退出码（0/1）
