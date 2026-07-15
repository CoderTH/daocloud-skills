---
name: token-cost-ranking
description: Query recent Token costs for users or tenants through Crane, rank the top M entries by cost, and produce an operational report with a chart. Trigger this skill for requests containing Chinese keywords such as “Token 费用排名”, “费用 Top 用户”, or “最近几天费用最高用户”. N defaults to 3 and M defaults to 5. This skill only ranks costs; it does not split results by model or perform write operations.
---

# Token Cost Ranking

Use `N=3` and `M=5` by default. Override either value when the user specifies it.

## Workflow

1. Calculate the latest N complete calendar days in `Asia/Shanghai`, then convert the window to UTC `[startTime, endTime)`. If the user provides explicit dates, use those dates instead.
2. Run the following read-only command. Set `<host>` to the DCE host provided by the user. Omit `--hostname` when the CLI has exactly one host configured:

   ```bash
   dce business-cockpit businessvalueservice get-tenant-token-usage \
     --hostname <host> \
     --start-time <UTC-start> \
     --end-time <UTC-end-exclusive> \
     -o json
   ```

3. Read the JSON `items`, discard entries whose `price` is missing, non-numeric, or negative, sort by `price` descending, and keep the top M entries. Do not use the API's default `tokenTotal` ordering or substitute `tokenTotal` for cost.
4. Compute total cost, top-M cost, top-M share of total cost, and each user's cost share. Prefer `tenantName` as the user identifier, falling back to `tenantId`. Display `price` in Chinese yuan with two decimal places.
5. Keep the ranking focused on cost; do not split it by model. If the API returns no valid data, state directly that the selected window contains no billable data. The final response must be in Chinese and include a conclusion, a horizontal Unicode bar chart, and a detail table using the following template.

## Chinese Output Template

```markdown
## 结论

最近 N 个完整自然日，费用最高的是 <用户>，费用为 ¥<金额>；Top M 用户合计占全部费用 <占比>。

## 费用排名图

1. <用户>  ¥<费用>  <占比>%  ████████████████████
2. <用户>  ¥<费用>  <占比>%  ████████████

## 排名明细

|排名|用户/租户|费用|费用占比|Token 总量|
|---:|---|---:|---:|---:|
|1|...|¥...|...%|...|

## 运营关注

- <费用集中度或其他重要发现>
```

Only run the GET query and authentication-status checks. Never run deletion, cleanup, quota-modification, or any other write operation.
