# 问题跟踪器：GitHub

本仓库的需求和问题存放在 `CandySunPlus/ai_voice` 的 GitHub Issues，使用 `gh` CLI 操作。标题、正文和评论使用中文，命令、标识符和标签保留原文。

## 操作约定

- 创建：`gh issue create --title "..." --body "..."`。多行正文使用 heredoc。
- 读取：`gh issue view <number> --json number,title,body,labels,comments`。
- 列表：`gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'`；按需使用 `--label`、`--state`。
- 子问题：`gh issue create --parent <parent> ...` 或 `gh issue edit <parent> --add-sub-issue <child>`（gh 2.94+）。旧版使用 `gh api --method POST repos/<owner>/<repo>/issues/<parent>/sub_issues -F sub_issue_id=<child-db-id>`。不支持子问题时，在子问题正文顶部写 `Part of #<parent>`。
- 阻塞关系：优先使用 GitHub 原生依赖。运行 `gh issue create --blocked-by <n>,<n> ...` 或 `gh issue edit <child> --add-blocked-by <blocker>`（gh 2.94+）。旧版使用 `gh api --method POST repos/<owner>/<repo>/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`。数据库 ID 通过 `gh api repos/<owner>/<repo>/issues/<n> --jq .id` 获取，不是问题编号或 node_id。不支持原生依赖时，在正文顶部写 `Blocked by: #<n>, #<n>`。所有阻塞项关闭后才可开始。
- 未关闭阻塞项数量：`gh api repos/<owner>/<repo>/issues/<n> --jq .issue_dependencies_summary.blocked_by`；0 表示可开始。使用 `gh issue view <n> --json blockedBy` 时，需过滤已关闭项：`--jq '[.blockedBy.nodes[] | select(.state == "OPEN")] | length'`。
- 评论：`gh issue comment <number> --body "..."`。
- 添加／移除标签：`gh issue edit <number> --add-label "..."`／`--remove-label "..."`。
- 关闭：先 `gh issue comment <number> --body "..."` 说明原因，再 `gh issue close <number>`。已关闭问题使用 `gh issue close --comment` 会丢失评论且仍返回成功。

在本目录内从 Git remote 推导仓库。每个会话第一次创建问题前，用 `gh repo view --json nameWithOwner` 核对目标必须为 `CandySunPlus/ai_voice`；不符时先与用户确认。Fork 中 gh 可能默认指向上游。仅向用户自己的仓库提交，不向技能来源仓库 `mattpocock/skills` 提交。

## Pull requests as a triage surface

**PRs as a request surface: no.**

若用户以后将其改为 `yes`，外部 PR 使用与 issue 相同的分流标签和状态：

- 读取：`gh pr view <number>`、`gh pr view <number> --comments` 和 `gh pr diff <number>`；非 TTY 下 `--comments` 只显示评论，不包含正文。
- 列表：`gh api --paginate 'repos/{owner}/{repo}/pulls?state=open' --jq '.[] | select(.author_association | IN("OWNER","MEMBER","COLLABORATOR") | not) | {number, title, author: .user.login, author_association, labels: [.labels[].name]}'`。
- 评论／标签／关闭：`gh pr comment`、`gh pr edit --add-label`／`--remove-label`、`gh pr close`。

GitHub 的 issue 与 PR 共用编号空间；只有 `#42` 时先用 `gh pr view 42` 判断，若不是 PR 再用 `gh issue view 42`。

## 技能要求发布或获取任务时

- “发布到问题跟踪器”：创建 GitHub issue。
- “获取相关任务”：按上面的读取约定获取 issue。

## Wayfinder 操作

供 `/wayfinder` 使用；一张地图对应一个 issue，任务对应子 issue。

- 地图：使用 `wayfinder:map` 标签，正文保存 Notes / Decisions-so-far / Fog；创建命令为 `gh issue create --label wayfinder:map`。
- 子任务：通过 GitHub 子问题关联地图；不可用时，在地图正文的任务列表中加入子任务，并在子任务顶部写 `Part of #<map>`。类型标签为 `wayfinder:<type>`，type 为 `research`／`prototype`／`grilling`／`task`；认领后分配给执行者。
- 阻塞：遵循上面的阻塞关系约定。
- 可执行队列：列出地图中未关闭的子任务，排除有未关闭阻塞项或已有负责人者，按地图顺序取第一个。
- 认领：`gh issue edit <n> --add-assignee @me`，作为该会话首次写操作。
- 解决：先 `gh issue comment <n> --body "<answer>"`，再 `gh issue close <n>`，最后将结论摘要与链接追加到地图的 Decisions-so-far。
