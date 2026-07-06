# Input Contracts

## Crane Cost Config

Use the Crane/DCE cost config endpoint first. The internal target endpoint is
`/apis/hydra.io/v1alpha1/analysis-center/cost-mock-config`; discover its
generated command with `dce search` and `dce commands --include-hidden --json`
before execution.

This endpoint name is internal evidence only. Do not show the concrete API path
in final user-facing analysis; refer to it as "成本配置数据" or "成本配置接口".

The returned JSON should be treated as the source of truth for:

- `currency`: currency for all cost values, for example `CNY`.
- GPU unit prices: GPU model/type, price, billing unit, and optional effective
  period.
- Model unit costs: model name or ID, provider/deploy type, input/output/cache
  unit cost, and optional effective period.
- Provider or MaaS metadata used to distinguish self-hosted DCE models from
  upstream/proxy MaaS models.

Example shape only; use the real returned field names:

```json
{
  "currency": "CNY",
  "gpuPrices": [
    {
      "gpuType": "A800",
      "price": 12.5,
      "unit": "GPU_HOUR",
      "effectiveFrom": "2026-06-01T00:00:00+08:00"
    }
  ],
  "modelCosts": [
    {
      "model": "deepseek-r1",
      "deployType": "SELF_HOSTED",
      "inputCostPer1k": 0.004,
      "outputCostPer1k": 0.016,
      "cachedInputCostPer1k": 0.0004
    }
  ]
}
```

For self-hosted DCE models, compute cost from GPU unit price:

```text
model_cost = gpu_unit_price * gpu_count_or_replicas * runtime
```

Treat GPU unit price as fixed within the analysis window unless the config
returns effective periods. If effective periods exist, split the window and sum
each segment.

## MaaS Model Cost

For upstream/proxy MaaS models, use the cost fields returned by MaaS model APIs,
such as `dce llm-studio maasservice list-maas-models -o json` or model detail
commands discovered with `dce commands show`.

Use the returned provider/model cost as-is. Do not replace it with local GPU
cost. If MaaS returns multiple cost fields, preserve the distinction between
input, output, cached input, and provider/model-level total cost when computing
margin attribution.

## Model Cost File

Use only when the user explicitly provides a real finance/provider source and
Crane/DCE cost config or MaaS model cost cannot provide the needed values. Do
not create or infer this file.

```json
{
  "currency": "CNY",
  "models": {
    "deepseek-r1": {
      "input_cost_per_1k": 0.004,
      "output_cost_per_1k": 0.016,
      "cached_input_cost_per_1k": 0.0004
    },
    "qwen-max": {
      "input_cost_per_1k": 0.02,
      "output_cost_per_1k": 0.06,
      "cached_input_cost_per_1k": 0.002
    }
  }
}
```

If `cached_input_cost_per_1k` is absent, mark cache-cost attribution incomplete
unless the cost config or MaaS response provides a real cached-input price.
