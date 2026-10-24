"""FallbackModelGateway tests (R-d.2 Opus->Sonnet fallback)."""
import sys, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from model_gateway import (FallbackModelGateway, FakeModelGateway, StructuredRequest,
                           ProviderError, StructuredOutputError)

REQ = StructuredRequest(task="t", schema={"type": "object"}, prompt_version="v", system="s", user_content="u")

def test_primary_success_no_fallback():
    gw = FallbackModelGateway(FakeModelGateway(response={"ok": 1}), FakeModelGateway(response={"ok": 2}))
    out = gw.generate_structured(REQ)
    assert out.data == {"ok": 1} and gw.last_fallback is False

def test_falls_back_on_provider_error():
    gw = FallbackModelGateway(FakeModelGateway(error=ProviderError("throttled")),
                              FakeModelGateway(response={"ok": "sonnet"}))
    out = gw.generate_structured(REQ)
    assert out.data == {"ok": "sonnet"} and gw.last_fallback is True and "throttled" in gw.last_error

def test_does_not_fall_back_on_structured_output_error():
    gw = FallbackModelGateway(FakeModelGateway(error=StructuredOutputError("bad")),
                              FakeModelGateway(response={"ok": "sonnet"}))
    try:
        gw.generate_structured(REQ); assert False, "should have raised"
    except StructuredOutputError:
        assert gw.last_fallback is False  # a bad OUTPUT is not a reason to switch models

def test_both_fail_propagates_fallback_error():
    gw = FallbackModelGateway(FakeModelGateway(error=ProviderError("p1")),
                              FakeModelGateway(error=ProviderError("p2")))
    try:
        gw.generate_structured(REQ); assert False
    except ProviderError as e:
        assert "p2" in str(e)
