# Skill Saver

当用户创建技能或安装外部技能时，统一规范技能保存位置。

## 核心目标

当用户**未明确指定保存路径**时，不论是“自行创建技能”还是“安装外部技能”，默认保存到：
`~/.agents/skills/`

## 触发条件

- 用户要求创建/编写新技能
- 用户要求保存技能
- 用户要求安装外部技能（GitHub、本地目录或其他来源）
- 用户说“帮我写一个技能”

## 行为规则

1. 路径优先级
- 若用户明确指定保存路径：按用户路径执行。
- 若用户未指定保存路径：默认保存到 `~/.agents/skills/{skill-name}/`。

2. 自行创建技能
- 目标目录：`~/.agents/skills/{skill-name}/`
- 入口文件：`SKILL.md`

3. 安装外部技能
- 目标目录默认归一到：`~/.agents/skills/{skill-name}/`
- 若安装工具不支持直接指定目标目录：先安装，再迁移到默认目录。

4. 命名规范
- 技能目录使用 kebab-case，例如：`sql-file-generator`、`global-skill-sync`

5. 冲突处理
- 若目标目录已存在同名技能，默认不覆盖；需用户明确同意后才覆盖。

6. 完成提示（固定输出）
- 保存或安装完成后，必须按以下顺序输出两行：
`绝对路径：{ABSOLUTE_PATH_TO_SKILL_MD}`
`注意：技能已保存完成。请输入“同步技能”来调用执行“全局技能同步技能”以同步到所有客户端并完成一致性校验。`

其中 `{ABSOLUTE_PATH_TO_SKILL_MD}` 示例（Windows）：
`C:\Users\{用户名}\.agents\skills\{skill-name}\SKILL.md`

## 目录示例

```text
~/.agents/skills/
├── my-skill-name/
│   └── SKILL.md
└── another-skill/
    └── SKILL.md
```

## 同步说明

- Skill Saver 不自动触发同步技能。
- 仅在完成后输出固定提示，引导用户手动执行“全局技能同步技能”。


