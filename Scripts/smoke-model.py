#!/usr/bin/env python3
"""Real MLX/Metal evaluation on synthetic desktop observations; never sends input.

Run: uv run --project engine python Scripts/smoke-model.py
Results are emitted even if model predictions are wrong; the exit code then fails.
"""

import contextlib
import json
import os
import time

os.environ.update(HF_HUB_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1", HF_HUB_DISABLE_IMPLICIT_TOKEN="1")

from free_hand_engine.budget import checked_prefix
from free_hand_engine.model import (
    MODEL_ID,
    MODEL_REVISION,
    model_dir,
    verify,
)
from free_hand_engine.protocol import dispatch


def main():
    import laya_mlx
    from laya_mlx.common import build_prefix

    verify(model_dir())
    start = time.perf_counter()
    agent = laya_mlx.load(str(model_dir()), dtype="float16", batch_size=3)
    load_ms = round((time.perf_counter() - start) * 1000, 1)
    operations = {"WAIT": "wait for loading", "DONE": "task visibly complete", "BLOCKED": "cannot proceed", "CLICK": "click or focus a control"}
    cases = [
        ("english-action", "Click Settings", "operation", operations, "CLICK", [
            {"id": "1", "role": "button", "label": "Settings"}, {"id": "2", "role": "button", "label": "Help"}]),
        ("chinese-target", "点击设置", "target", {"1": "设置", "2": "帮助", "__none__": "none of these controls"}, "1", [
            {"id": "1", "role": "button", "label": "设置"}, {"id": "2", "role": "button", "label": "帮助"}]),
        ("text-action", 'Type "Hello Free Hand"', "operation", {**operations, "TYPE_TEXT": "type text or a search query into an input field"}, "TYPE_TEXT", [
            {"id": "1", "role": "textField", "label": "Message", "value": "", "focused": True}]),
        ("search-target", 'Search for "Adele"', "target", {"1": "Search contacts", "2": "Name", "__none__": "none of these controls"}, "1", [
            {"id": "1", "role": "textField", "label": "Search contacts", "value": ""}, {"id": "2", "role": "textField", "label": "Name", "value": ""}]),
    ]
    results = []
    for name, goal, kind, criteria, expected, elements in cases:
        operation = "CLICK" if name == "chinese-target" else "TYPE_TEXT"
        if kind == "target":
            roles = {row["id"]: row["role"] for row in elements}
            criteria = {key: f"{value} [{roles[key]}]" if key in roles else value for key, value in criteria.items()}
        question = {"type": "choice", "instructions": f'For the user task "{goal}", which immediate desktop action should be taken next? Do not repeat completed steps.'
                    if kind == "operation" else f'For the task "{goal}", which UI control should {operation} target? Prefer search fields for search tasks.', "criteria": criteria}
        question["option_order"] = sorted(criteria, key=lambda key: (key != "__none__", key))
        elements = [{**element, "enabled": True} for element in elements]
        # Validate our independent no-truncation accounting against the real upstream tokenizer.
        prefix, _ = build_prefix(agent.tok, agent._to_internal(question), agent.cfg["head_max_len"])
        assert checked_prefix(agent, question) == len(prefix)
        # Match the sorted-key JSON encoding used by the production Swift client.
        request = {"method": "predict", "params": {"state": {
            "task": goal, "app": "Free Hand Playground", "elements": elements,
            **({"selectedIntent": operation} if kind == "target" else {})}, "questions": {kind: question}}}
        result = dispatch(agent, json.loads(json.dumps(request, sort_keys=True)))
        answer = result["answers"][kind]
        results.append({"case": name, "expected": expected, "actual": answer["choice"],
                        "passed": answer["choice"] == expected, "probability": answer["probabilities"][answer["choice"]],
                        "latency_ms": result["metrics"]["latency_ms"]})
    report = {"model": MODEL_ID, "revision": MODEL_REVISION, "load_ms": load_ms, "backend": "MLX Metal float16",
              "scope": "synthetic observations; real inference, NOT desktop input", "cases": results}
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if all(case["passed"] for case in results) else 1


if __name__ == "__main__":
    with contextlib.nullcontext():
        raise SystemExit(main())
