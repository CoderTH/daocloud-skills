---
name: model-finance-chart
description: >
  Query Crane for model cost and revenue over the most recent N complete calendar
  days and produce a chart-first operations summary. Use for model cost, model
  revenue, model gross profit, and recent-N-day model finance requests. Default N
  is 3. Chinese trigger keywords: 模型成本、模型收入、模型毛利、最近N天模型经营数据.
  Use only Crane-backed business-cockpit queries; never call other DCE modules.
---

# Crane Model Finance Chart

Default `N=3`. Use the most recent N complete calendar days in `Asia/Shanghai`,
converted to the UTC half-open interval `[startTime, endTime)`. If the user
provides explicit dates, use those dates.

The `business-cockpit` prefix in `dce` is only the generated service label for
Crane. The actual HTTP paths are `/apis/crane.io/v1alpha1/...`. If the user
provides one model explicitly, skip model discovery and query that model.

## Workflow

1. Run the bundled runner directly. It first calls the Crane model-list API,
   then queries model revenue and cost. Do not split the workflow manually or
   call another DCE module:

   ```bash
   python3 scripts/query_model_finance.py \
     --hostname <host> \
     --start-time <UTC-start> \
     --end-time <UTC-end-exclusive>
   ```

   Omit `--hostname` when one DCE host is already configured. The runner uses
   only Python's standard library and the `dce` CLI, and calls Crane GET APIs
   only.

2. The runner uses a fixed concurrency policy:

   - Preserve the model-list order and split models into batches of at most 8.
   - Use a fixed thread pool of 16 workers per batch. Each worker runs exactly
     one model revenue or cost request, so a full batch has at most 16 Crane GET
     subprocesses.
   - Wait for every request in the current batch before starting the next batch.
   - Each request has its own `dce` subprocess and output buffer. Workers only
     return values; the main thread merges results by `(model, revenue/cost)` and
     emits rows in the original model order. Do not share files or stdout.
   - A failed request is recorded in the relevant model `errors` object. A model
     list failure is recorded as top-level `errors.modelList`. The runner still
     exits successfully and the skill must continue with a partial-data report.

3. Read `revenueYuan` from the revenue response and the numeric value in
   `kpi.value` from the cost response. For valid pairs calculate:

   ```text
   gross profit = revenue - cost
   gross margin = gross profit / revenue
   ```

   Do not calculate gross margin when revenue is zero. Sort by revenue
   descending, display amounts in CNY yuan with two decimals, and never treat a
   missing cost as zero.

## Output

Respond in Chinese. Put the conclusion first, prefer charts to prose, and keep
the detail table compact:

```markdown
## 结论
最近 N 个完整自然日：收入 ¥总收入，成本 ¥总成本，毛利 ¥总毛利，毛利率 总毛利率。

## 模型经营图
模型                         收入                 成本                 毛利
model-a  ¥收入 ██████████   ¥成本 ██████         ¥毛利 ████
model-b  ¥收入 ██████       ¥成本 █████          ¥毛利 █

## 模型明细
|模型|收入|成本|毛利|毛利率|
|---|---:|---:|---:|---:|
|...|¥...|¥...|¥...|...%|

## 运营关注
- <收入/成本集中度、亏损模型或成本缺失>
```

Normalize each bar against the largest absolute value in its column and show
at least one block for a non-empty value. If there is no valid Crane data, say
so directly. Do not expose command traces, retry logs, raw JSON, or internal
error details in the final report.

Run only the Crane GET queries described above; never perform writes.
