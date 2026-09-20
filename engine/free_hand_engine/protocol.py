"""Bounded JSONL protocol over parent-owned stdin/stdout. No TCP/HTTP listener."""

import json
import math
import time
from collections import deque

from .budget import BudgetError, compact_state

MAX_LINE_BYTES = 128 * 1024
MAX_RESPONSE_BYTES = 64 * 1024
VERSION = 1


def validate_request(request: object) -> dict:
    if not isinstance(request, dict) or request.get("version") != VERSION:
        raise ValueError("Unsupported protocol version.")
    if not isinstance(request.get("id"), str) or not 1 <= len(request["id"]) <= 64:
        raise ValueError("Invalid request ID.")
    if request.get("method") not in ("predict", "ping", "shutdown"):
        raise ValueError("Unsupported method.")
    if request["method"] != "predict":
        return request
    params = request.get("params")
    if not isinstance(params, dict) or not isinstance(params.get("state"), dict):
        raise ValueError("Invalid request parameters.")
    questions = params.get("questions")
    if not isinstance(questions, dict) or not 1 <= len(questions) <= 3:
        raise ValueError("Expected between one and three typed questions.")
    for qid, question in questions.items():
        if not isinstance(qid, str) or len(qid) > 64 or not isinstance(question, dict):
            raise ValueError("Invalid question.")
        if question.get("type") not in ("choice", "noul"):
            raise ValueError("Only choice and noul are supported.")
        instruction = question.get("instructions")
        if not isinstance(instruction, str) or len(instruction) > 600:
            raise ValueError("Invalid question instructions.")
        criteria = question.get("criteria")
        if question["type"] == "choice":
            if not isinstance(criteria, dict) or not 2 <= len(criteria) <= 12:
                raise ValueError("Expected between two and twelve choices.")
            if any(not isinstance(k, str) or not isinstance(v, str) or len(k) > 64 or len(v) > 300
                   for k, v in criteria.items()):
                raise ValueError("Invalid choice labels.")
            order = question.get("option_order")
            if order is not None and (not isinstance(order, list) or not all(isinstance(k, str) for k in order)
                                      or len(order) != len(criteria) or set(order) != set(criteria)):
                raise ValueError("Invalid explicit option order.")
    elements = params["state"].get("elements", [])
    attempts = params["state"].get("action_attempts", [])
    if not isinstance(elements, list) or len(elements) > 160 or not isinstance(attempts, list):
        raise ValueError("Invalid observation.")
    return request


def valid_result(result: dict, questions: dict) -> None:
    answers = result.get("answers")
    if not isinstance(answers, dict) or set(answers) != set(questions):
        raise ValueError("Missing model answers.")
    for qid, question in questions.items():
        answer = answers[qid]
        if question["type"] == "choice":
            if answer.get("choice") not in question["criteria"]:
                raise ValueError("The model selected an unoffered choice.")
            probabilities = answer.get("probabilities", {})
            if set(probabilities) != set(question["criteria"]):
                raise ValueError("Invalid model distribution.")
            values = list(probabilities.values())
            if any(not isinstance(p, (int, float)) or isinstance(p, bool) or not math.isfinite(p)
                   or not 0 <= p <= 1 for p in values) or abs(sum(values) - 1) > 0.01:
                raise ValueError("Nonfinite or unnormalized model distribution.")
        else:
            p = answer.get("noul")
            if not isinstance(p, (int, float)) or isinstance(p, bool) or not math.isfinite(p) or not 0 <= p <= 1:
                raise ValueError("Invalid model probability.")


def dispatch(agent, request: dict) -> dict:
    if request["method"] in ("ping", "shutdown"):
        return {"status": "ready"}
    params = request["params"]
    questions = ordered_questions(params["questions"])
    start = time.perf_counter()
    state, budget = compact_state(agent, params["state"], questions)
    result = agent.predict(state, questions)
    valid_result(result, questions)
    result["metrics"] = {**budget, "latency_ms": round((time.perf_counter() - start) * 1000, 2)}
    return result


def ordered_questions(questions: dict) -> dict:
    """Respect an explicit array, independent of Swift/Python JSON dictionary sorting.

    No option is removed and no permutation search or retry is performed.
    """
    result = {}
    for name, question in questions.items():
        value = dict(question)
        if value["type"] == "choice" and "option_order" in value:
            value["criteria"] = {key: value["criteria"][key] for key in value["option_order"]}
        result[name] = value
    return result


def emit(output, value: dict) -> None:
    data = json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode("utf-8")
    if len(data) > MAX_RESPONSE_BYTES:
        data = json.dumps({"version": VERSION, "id": value.get("id"),
                           "error": {"code": "E_SIZE", "message": "Response exceeded the size limit."}}).encode()
    output.write(data + b"\n")
    output.flush()


def serve(agent, source, output) -> None:
    seen = deque(maxlen=256)
    emit(output, {"version": VERSION, "event": "ready", "engine": "laya-mlx", "offline": True})
    while True:
        raw = source.readline(MAX_LINE_BYTES + 1)
        if not raw:
            return
        if len(raw) > MAX_LINE_BYTES:
            # Close instead of draining an adversarial unbounded stream.
            emit(output, {"version": VERSION, "id": None,
                          "error": {"code": "E_SIZE", "message": "Request too large."}})
            return
        request_id = None
        try:
            request = json.loads(raw)
            request = validate_request(request)
            request_id = request["id"]
            if request_id in seen:
                raise ValueError("Duplicate request ID.")
            seen.append(request_id)
            result = dispatch(agent, request)
            emit(output, {"version": VERSION, "id": request_id, "result": result})
            if request["method"] == "shutdown":
                return
        except BudgetError as error:
            emit(output, {"version": VERSION, "id": request_id,
                          "error": {"code": "E_BUDGET", "message": str(error)}})
        except Exception:
            # Never echo malformed JSON, private state, paths, or third-party exceptions.
            emit(output, {"version": VERSION, "id": request_id,
                          "error": {"code": "E_REQUEST", "message": "Invalid request or model result. No action was authorized."}})
