#!/usr/bin/env python3
"""Query Crane model revenue and cost with fixed batched concurrency."""

import argparse
import json
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed


BATCH_SIZE = 8
MAX_WORKERS = BATCH_SIZE * 2


def run_json(command):
    try:
        result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=120,
        )
    except Exception as exc:
        return None, type(exc).__name__
    if result.returncode != 0:
        return None, "dce_exit_%s" % result.returncode
    try:
        return json.loads(result.stdout), None
    except json.JSONDecodeError:
        return None, "invalid_json"


def command(args, operation, model=None):
    value = [
        "dce",
        "business-cockpit",
        "businessoperationservice",
        operation,
    ]
    if args.hostname:
        value += ["--hostname", args.hostname]
    value += [
        "--start-time",
        args.start_time,
        "--end-time",
        args.end_time,
    ]
    if operation == "list-business-models":
        value += ["--limit", "1000"]
    else:
        value += ["--model", model]
    return value + ["-o", "json"]


def query_request(args, model, kind):
    operation = {
        "revenue": "get-monthly-revenue",
        "cost": "get-department-monthly-allocated-cost",
    }[kind]
    payload, error = run_json(command(args, operation, model))
    return model, kind, payload, error


def run_batch(args, batch):
    # Workers return values only. The main thread is the sole writer of records.
    records = {
        model: {"model": model, "revenue": None, "cost": None, "errors": {}}
        for model in batch
    }
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        futures = {
            executor.submit(query_request, args, model, kind): (model, kind)
            for model in batch
            for kind in ("revenue", "cost")
        }
        for future in as_completed(futures):
            model, kind = futures[future]
            try:
                _, _, payload, error = future.result()
            except Exception as exc:
                payload, error = None, type(exc).__name__
            record = records[model]
            record[kind] = payload
            if error:
                record["errors"][kind] = error
    return [records[model] for model in batch]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--hostname")
    parser.add_argument("--start-time", required=True)
    parser.add_argument("--end-time", required=True)
    args = parser.parse_args()

    models_payload, error = run_json(command(args, "list-business-models"))
    if error:
        print(
            json.dumps(
                {
                    "startTime": args.start_time,
                    "endTime": args.end_time,
                    "models": [],
                    "errors": {"modelList": "model_list_" + error},
                    "batchSize": BATCH_SIZE,
                    "maxWorkers": MAX_WORKERS,
                },
                ensure_ascii=False,
            )
        )
        return 0

    models = []
    model_values = models_payload.get("models", []) if isinstance(models_payload, dict) else []
    for model in model_values or []:
        if isinstance(model, str) and model and model not in models:
            models.append(model)

    rows = []
    for offset in range(0, len(models), BATCH_SIZE):
        batch = models[offset : offset + BATCH_SIZE]
        rows.extend(run_batch(args, batch))

    print(
        json.dumps(
            {
                "startTime": args.start_time,
                "endTime": args.end_time,
                "models": rows,
                "errors": {},
                "batchSize": BATCH_SIZE,
                "maxWorkers": MAX_WORKERS,
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
