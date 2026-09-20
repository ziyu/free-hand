import io
import json
import re

import pytest

from free_hand_engine.budget import BudgetError, checked_prefix, compact_state
from free_hand_engine.protocol import (
    MAX_LINE_BYTES,
    emit,
    ordered_questions,
    serve,
    valid_result,
    validate_request,
)


class Tokenizer:
    mask_token = "[MASK]"

    def __call__(self, text, add_special_tokens=False):
        return {"input_ids": list(range(len(re.findall(r"\w+|[^\w\s]", text))))}


class Agent:
    tok = Tokenizer()
    cfg = {"max_len": 512, "head_max_len": 192}

    def predict(self, state, questions):
        answers = {}
        for name, question in questions.items():
            if question["type"] == "noul":
                answers[name] = {"noul": 0.1}
            else:
                labels = list(question["criteria"])
                answers[name] = {"choice": labels[0], "probabilities": {
                    label: 1.0 if index == 0 else 0.0 for index, label in enumerate(labels)}}
        return {"answers": answers}


def question():
    return {"type": "choice", "instructions": "Which control?", "criteria": {"1": "Settings", "none": "none"}}


def request(request_id="test"):
    return {"version": 1, "id": request_id, "method": "predict", "params": {
        "state": {"task": "Click Settings", "app": "Fixture", "elements": []},
        "questions": {"target": question()}}}


def run_protocol(*requests):
    data = b"".join(json.dumps(value).encode() + b"\n" for value in requests)
    output = io.BytesIO()
    serve(Agent(), io.BytesIO(data), output)
    return [json.loads(line) for line in output.getvalue().splitlines()]


def test_predict_is_framed_and_returns_measured_budget():
    ready, response = run_protocol(request())
    assert ready["event"] == "ready" and ready["offline"] is True
    assert response["id"] == "test"
    assert response["result"]["answers"]["target"]["choice"] == "1"
    assert response["result"]["metrics"]["state_tokens"] <= response["result"]["metrics"]["state_budget"]


def test_native_json_sorting_never_removes_or_promotes_fallbacks():
    criteria = {"BLOCKED": "cannot proceed", "CLICK": "click", "DONE": "done", "TYPE_TEXT": "type", "WAIT": "wait"}
    original = {"operation": {"type": "choice", "instructions": "Next?", "criteria": criteria,
                              "option_order": ["CLICK", "TYPE_TEXT", "WAIT", "DONE", "BLOCKED"]}}
    ordered = ordered_questions(original)
    assert list(ordered["operation"]["criteria"]) == ["CLICK", "TYPE_TEXT", "WAIT", "DONE", "BLOCKED"]
    assert ordered["operation"]["criteria"] == criteria
    assert list(original["operation"]["criteria"])[0] == "BLOCKED"


@pytest.mark.parametrize("order", [["1"], ["1", "1"], ["1", "unknown"], "1,none"])
def test_invalid_order_cannot_drop_or_invent_a_choice(order):
    value = request()
    value["params"]["questions"]["target"]["option_order"] = order
    with pytest.raises(ValueError):
        validate_request(value)


@pytest.mark.parametrize("value", [None, [], {}, {"version": 2}, {"version": 1, "id": "", "method": "ping"},
                                  {"version": 1, "id": "a", "method": "shell"}])
def test_malformed_envelopes_are_rejected(value):
    with pytest.raises(ValueError):
        validate_request(value)


@pytest.mark.parametrize("change", ["type", "criteria", "instructions", "elements", "questions"])
def test_invalid_inference_shape_is_rejected(change):
    value = request()
    if change == "type":
        value["params"]["questions"]["target"]["type"] = "generate"
    elif change == "criteria":
        value["params"]["questions"]["target"]["criteria"] = {str(i): "x" for i in range(13)}
    elif change == "instructions":
        value["params"]["questions"]["target"]["instructions"] = "x" * 601
    elif change == "elements":
        value["params"]["state"]["elements"] = [{}] * 161
    else:
        value["params"]["questions"] = {}
    with pytest.raises(ValueError):
        validate_request(value)


def test_duplicate_ids_do_not_run_again():
    responses = run_protocol(request(), request())
    assert "result" in responses[1]
    assert responses[2]["error"]["code"] == "E_REQUEST"


def test_bad_input_does_not_echo_private_text():
    output = io.BytesIO()
    serve(Agent(), io.BytesIO(b'{"private":"PRIVATE_TEST_CONTENT"\n'), output)
    assert b"PRIVATE_TEST_CONTENT" not in output.getvalue()
    assert b"E_REQUEST" in output.getvalue()


def test_oversized_frame_closes_instead_of_unbounded_drain():
    output = io.BytesIO()
    source = io.BytesIO(b"x" * (MAX_LINE_BYTES + 1) + b"\n" + json.dumps(request()).encode() + b"\n")
    serve(Agent(), source, output)
    assert b"E_SIZE" in output.getvalue()
    assert source.tell() == MAX_LINE_BYTES + 1


def test_shutdown_and_ping_without_inference():
    class NoInference:
        def predict(self, *args):
            raise AssertionError("No inference expected")

    output = io.BytesIO()
    source = io.BytesIO(b'{"version":1,"id":"a","method":"ping"}\n'
                        b'{"version":1,"id":"b","method":"shutdown"}\nignored')
    serve(NoInference(), source, output)
    assert len(output.getvalue().splitlines()) == 3
    assert source.read() == b"ignored"


def test_outsize_response_is_bounded():
    output = io.BytesIO()
    emit(output, {"version": 1, "id": "a", "result": "x" * 100_000})
    assert len(output.getvalue()) < 1000
    assert json.loads(output.getvalue())["id"] == "a"


@pytest.mark.parametrize("value", [float("nan"), float("inf"), -0.1, 1.1, True, "0.9"])
def test_invalid_boolean_probability_is_never_accepted(value):
    with pytest.raises(ValueError):
        valid_result({"answers": {"done": {"noul": value}}}, {"done": {"type": "noul"}})


@pytest.mark.parametrize("answer", [
    {"choice": "unoffered", "probabilities": {"1": 1, "none": 0}},
    {"choice": "1", "probabilities": {"1": 1}},
    {"choice": "1", "probabilities": {"1": 0.8, "none": 0.8}},
    {"choice": "1", "probabilities": {"1": float("nan"), "none": 0}},
])
def test_bad_choice_distributions_are_rejected(answer):
    with pytest.raises(ValueError):
        valid_result({"answers": {"target": answer}}, {"target": question()})


def test_full_goal_retained_and_unfit_goal_rejected():
    state, metrics = compact_state(Agent(), {"task": "Click the exact Settings control"}, {"target": question()})
    assert "Click the exact Settings control" in state
    assert metrics["omitted_rows"] == 0
    with pytest.raises(BudgetError):
        compact_state(Agent(), {"task": "long task " * 250}, {"target": question()})


def test_rows_omitted_are_explicit_not_silent_truncation():
    state, metrics = compact_state(Agent(), {"task": "Click Settings", "elements": [
        {"id": str(i), "label": "details " * 50} for i in range(16)]}, {"target": question()})
    assert "User task: Click Settings" in state
    assert metrics["state_tokens"] <= metrics["state_budget"]
    assert metrics["omitted_rows"] > 0
    assert len(metrics["included_ids"]) + metrics["omitted_rows"] == 16


def test_option_and_question_truncation_are_rejected():
    long_option = question()
    long_option["criteria"]["1"] = "word " * 49
    with pytest.raises(BudgetError):
        checked_prefix(Agent(), long_option)
    long_question = question()
    long_question["instructions"] = "word " * 193
    with pytest.raises(BudgetError):
        checked_prefix(Agent(), long_question)


def test_custom_boolean_criteria_are_not_miscounted():
    with pytest.raises(BudgetError):
        checked_prefix(Agent(), {"type": "noul", "instructions": "Done?", "criteria": {"true": "custom"}})


def test_stderr_or_exception_never_becomes_an_action():
    class Broken(Agent):
        def predict(self, *args):
            raise RuntimeError("PRIVATE_SCREEN_CONTENT")

    output = io.BytesIO()
    serve(Broken(), io.BytesIO(json.dumps(request()).encode() + b"\n"), output)
    assert b"PRIVATE_SCREEN_CONTENT" not in output.getvalue()
    assert b'"result"' not in output.getvalue()
