"""StoryCoverage/2 — the Guide-relative Coverage pipeline (Milestone E2-b, FROZEN).

Two internal engines + a deterministic evidence builder, composed into the public
StoryCoverageContractV2 (the two-call split is hidden from clients):

  CALL 1 RealStoryCoverageMapper (prompt story_coverage/mapper-v1, Opus 4.6):
    StoryGuide + completed MomentUnderstanding[] -> CoverageMapping
    (dimension_coverage keyed by stable Guide dim id, strengths, redundancies). NEVER sufficiency/idea.

  build_judge_evidence (DETERMINISTIC, no model): CreativeIntent/scope + positive semantic evidence
    (Mapper strengths) + FACTUAL MaterialScopeEvidence (from MomentUnderstanding useful_segments) +
    redundancy + pending_count. The INFORMATION FIREWALL: it NEVER passes Guide dimensions, coverage
    states, could_use_more, candidates, capture possibilities, or represented ids to the Judge — the
    J-A/J-B ablation proved those reintroduce completion bias. assert_no_guide_leakage() enforces it.

  CALL 2 RealStoryJudgmentEngine (prompt story_judgment/v2, Opus 4.6): evidence -> StoryJudgment
    (sufficiency + story_idea|null). Material scope is EVIDENCE, not a formula.

compose() -> StoryCoverageContractV2.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Protocol, runtime_checkable
from uuid import UUID

from contracts.schemas.ai_contracts import (
    CoverageMapping, CoverageStoryIdeaV2, CoverageSufficiency, DimensionCoverage,
    MaterialScopeEvidence, StoryCoverageContractV2, StoryJudgment, SufficiencyStatus,
)
from model_gateway import (
    ModelGateway, ProviderError, StructuredOutputError, StructuredRequest, StructuredResult,
)

MAPPER_PROMPT_VERSION = "story_coverage/mapper-v1"
JUDGE_PROMPT_VERSION = "story_judgment/v2"
SCHEMA_VERSION = "story_coverage/2"
DEFAULT_COVERAGE_MODEL = "us.anthropic.claude-opus-4-6-v1"
_PROMPTS = Path(__file__).resolve().parent.parent.parent / "prompts"
_STATES = ["strong", "looking_good", "could_use_more", "unknown"]
_SUFF = ["insufficient", "workable", "sufficient"]

# Tokens the Judge input must NEVER contain (information firewall).
_FORBIDDEN_JUDGE_KEYS = {
    "story_guide", "dimensions", "dimension_coverage", "capture_possibilities",
    "represented_possibility_ids", "story_guide_dimension_id", "candidates",
    "optional_opportunity_candidates", "state", "coverage",
}
_FORBIDDEN_JUDGE_SUBSTR = ("could_use_more", "looking_good", "capture_possib")


def _load(path: str) -> str:
    return (_PROMPTS / path / "system.md").read_text()


class CoverageUnavailableError(RuntimeError):
    """Raised when Coverage/2 could not be computed. Caller MUST keep the previous valid cache."""


# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------
@dataclass
class CoverageV2Input:
    story_id: UUID
    story_guide: dict[str, Any]                  # frozen StoryGuide/1 (dimensions w/ stable ids)
    creative_intent: dict[str, Any]
    scope: dict[str, Any]                        # {target_duration_seconds?, format?}
    moment_understandings: list[dict[str, Any]]  # completed MU dicts (observed+story_context+useful_segments)
    pending_count: int = 0
    story_guide_version: str = "story_guide/1"


# ---------------------------------------------------------------------------
# CALL 1 — Mapper
# ---------------------------------------------------------------------------
class RealStoryCoverageMapper:
    def __init__(self, gateway: ModelGateway, model_id: str | None = None):
        self._gw = gateway
        self._model_id = model_id or DEFAULT_COVERAGE_MODEL
        self._system = _load("story_coverage/mapper-v1")

    @staticmethod
    def _guide_compact(guide: dict) -> dict:
        return {"framing_summary": guide.get("framing_summary", ""), "dimensions": [
            {"id": d["id"], "label": d["label"], "purpose": d.get("purpose", ""),
             "capture_possibilities": [{"id": p["id"], "label": p["label"]} for p in d.get("capture_possibilities", [])]}
            for d in guide.get("dimensions", [])]}

    @staticmethod
    def _compact_mu(mu: dict) -> dict:
        o = mu.get("observed", {}) or {}
        sc = mu.get("story_context", {}) or {}
        return {"moment_id": str(mu.get("moment_id") or mu.get("id") or ""),
                "summary": o.get("summary", ""), "subjects": o.get("subjects", []),
                "events": [e.get("description", "") for e in o.get("events", []) if isinstance(e, dict)],
                "useful_segments": [s.get("why_useful", "") for s in o.get("useful_segments", []) if isinstance(s, dict)],
                "story_utility": sc.get("story_utility")}

    def _schema(self, gids: list[str], pids: list[str]) -> dict:
        return {"type": "object", "additionalProperties": False, "properties": {
            "dimension_coverage": {"type": "array", "items": {"type": "object", "additionalProperties": False,
                "properties": {"story_guide_dimension_id": {"type": "string", "enum": gids},
                    "state": {"type": "string", "enum": _STATES}, "note": {"type": "string"},
                    "evidence_moment_ids": {"type": "array", "items": {"type": "string"}},
                    "represented_possibility_ids": {"type": "array",
                        "items": ({"type": "string", "enum": pids} if pids else {"type": "string"})}},
                "required": ["story_guide_dimension_id", "state"]}},
            "strengths": {"type": "array", "items": {"type": "string"}},
            "redundancies": {"type": "array", "items": {"type": "string"}}},
            "required": ["dimension_coverage", "strengths", "redundancies"]}

    def map(self, inp: CoverageV2Input) -> tuple[CoverageMapping, list[str]]:
        import json as _json
        gids = [d["id"] for d in inp.story_guide.get("dimensions", [])]
        pids = [p["id"] for d in inp.story_guide.get("dimensions", []) for p in d.get("capture_possibilities", [])]
        payload = {"story_guide": self._guide_compact(inp.story_guide), "pending_count": inp.pending_count,
                   "moments": [self._compact_mu(m) for m in inp.moment_understandings]}
        user = ("Map the understood material onto this StoryGuide. One dimension_coverage entry per "
                "Guide dimension (by id). Purpose > literal possibility. Return ONLY the CoverageMapping.\n\n"
                + _json.dumps(payload))
        req = StructuredRequest(task="story_coverage.map", schema=self._schema(gids, pids),
                                prompt_version=MAPPER_PROMPT_VERSION, system=self._system,
                                user_content=user, max_repair_attempts=2, max_tokens=8192, temperature=0.0)
        try:
            res = self._gw.generate_structured(req)
        except (StructuredOutputError, ProviderError) as e:
            raise CoverageUnavailableError(f"mapper unavailable ({type(e).__name__}: {e})") from e
        # A truncated structured output can validate as an EMPTY dimension_coverage (schema allows []), which
        # silently drops ALL coverage. One entry per Guide dimension is REQUIRED by construction, so an empty
        # result for a populated guide is a failure, not a valid mapping — surface it so the cache is kept and
        # the next recompute retries, rather than caching an empty mapping that marks everything "Shoot".
        if gids and not (res.data or {}).get("dimension_coverage"):
            raise CoverageUnavailableError(
                f"mapper returned empty dimension_coverage for {len(gids)} guide dimensions "
                f"(likely truncated at stop_reason={getattr(res, 'stop_reason', '?')})")
        d = dict(res.data)
        # evidence_moment_ids remap to real UUIDs (Milestone-B id discipline)
        src = {str(m.get("moment_id") or m.get("id")) for m in inp.moment_understandings if (m.get("moment_id") or m.get("id"))}
        dc = []
        for c in d.get("dimension_coverage", []):
            ev = [e for e in (c.get("evidence_moment_ids") or []) if isinstance(e, str) and e in src]
            dc.append(DimensionCoverage(
                story_guide_dimension_id=c["story_guide_dimension_id"], state=c["state"],
                note=c.get("note"), evidence_moment_ids=[UUID(e) for e in ev],
                represented_possibility_ids=[p for p in (c.get("represented_possibility_ids") or []) if p in pids]))
        return CoverageMapping(dimension_coverage=dc, strengths=d.get("strengths", []),
                               redundancies=d.get("redundancies", [])), gids


# ---------------------------------------------------------------------------
# Deterministic evidence builder (NO model) + information firewall
# ---------------------------------------------------------------------------
def _seg_dur(s: dict) -> float | None:
    a = s.get("t_start_s", s.get("start_time", s.get("start_seconds")))
    b = s.get("t_end_s", s.get("end_time", s.get("end_seconds")))
    try:
        return float(b) - float(a) if a is not None and b is not None else None
    except Exception:
        return None


def material_scope(inp: CoverageV2Input) -> MaterialScopeEvidence:
    """FACTUAL, deterministic — derived from MomentUnderstanding useful_segments. NOT a formula."""
    comp = len(inp.moment_understandings)
    umom = 0
    total = 0.0
    for mu in inp.moment_understandings:
        segs = (mu.get("observed", {}) or {}).get("useful_segments", []) or []
        any_useful = False
        for s in segs:
            if isinstance(s, dict):
                d = _seg_dur(s)
                if d and d > 0:
                    total += d; any_useful = True
        if any_useful or segs:
            umom += 1
    target = inp.scope.get("target_duration_seconds")
    return MaterialScopeEvidence(understood_moment_count=comp, useful_moment_count=umom,
                                 total_useful_segment_duration_seconds=round(total, 1),
                                 target_output_duration_seconds=target)


def build_judge_evidence(inp: CoverageV2Input, mapping: CoverageMapping) -> dict[str, Any]:
    """Positive semantic evidence (Mapper strengths) + factual material scope + redundancy + pending.
    NO Guide, NO dimension states, NO candidates. Firewalled by assert_no_guide_leakage()."""
    ms = material_scope(inp)
    ev = {"creative_intent": inp.creative_intent, "scope": inp.scope,
          "positive_actual_story_evidence": list(mapping.strengths),
          "material_scope_evidence": ms.model_dump(mode="json"),
          "redundancy": list(mapping.redundancies), "pending_count": inp.pending_count}
    assert_no_guide_leakage(ev)
    return ev


def assert_no_guide_leakage(evidence: dict[str, Any]) -> None:
    """Load-bearing firewall: fail LOUD if Judge input carries any Guide/completion signal."""
    top = set(evidence.keys())
    bad = top & _FORBIDDEN_JUDGE_KEYS
    if bad:
        raise CoverageUnavailableError(f"Judge-evidence firewall breached: forbidden keys {sorted(bad)}")
    import json as _json
    blob = _json.dumps(evidence).lower()
    for sub in _FORBIDDEN_JUDGE_SUBSTR:
        if sub in blob:
            raise CoverageUnavailableError(f"Judge-evidence firewall breached: forbidden token '{sub}'")


# ---------------------------------------------------------------------------
# CALL 2 — Judge
# ---------------------------------------------------------------------------
class RealStoryJudgmentEngine:
    def __init__(self, gateway: ModelGateway, model_id: str | None = None):
        self._gw = gateway
        self._model_id = model_id or DEFAULT_COVERAGE_MODEL
        self._system = _load("story_judgment/v2")

    _SCHEMA = {"type": "object", "additionalProperties": False, "properties": {
        "sufficiency": {"type": "object", "additionalProperties": False,
            "properties": {"status": {"type": "string", "enum": _SUFF}, "reason": {"type": "string"}}, "required": ["status"]},
        "story_idea": {"type": ["object", "null"], "additionalProperties": False, "properties": {
            "title": {"type": "string"}, "description": {"type": "string"}, "rationale": {"type": "string"},
            "target_story_guide_dimension_id": {"type": ["string", "null"]}}, "required": ["title", "description"]}},
        "required": ["sufficiency", "story_idea"]}

    def judge(self, evidence: dict[str, Any]) -> StoryJudgment:
        import json as _json
        assert_no_guide_leakage(evidence)  # firewall again at the call site
        user = ("Judge this Story from the semantic evidence AND the factual material-scope evidence.\n\n"
                + _json.dumps(evidence)
                + "\n\nmaterial_scope_evidence is neutral FACT, not a quota. Decide sufficiency "
                  "independently, then whether ONE genuinely NEW opportunity is worth surfacing (else "
                  "null). Return ONLY the StoryJudgment.")
        req = StructuredRequest(task="story_judgment.decide", schema=self._SCHEMA,
                                prompt_version=JUDGE_PROMPT_VERSION, system=self._system,
                                user_content=user, max_repair_attempts=2, max_tokens=1200, temperature=0.0)
        try:
            res = self._gw.generate_structured(req)
        except (StructuredOutputError, ProviderError) as e:
            raise CoverageUnavailableError(f"judge unavailable ({type(e).__name__}: {e})") from e
        d = res.data
        idea = d.get("story_idea")
        return StoryJudgment(
            sufficiency=CoverageSufficiency(status=d["sufficiency"]["status"], reason=d["sufficiency"].get("reason")),
            story_idea=(CoverageStoryIdeaV2(
                title=idea["title"], description=idea["description"], rationale=idea.get("rationale"),
                target_story_guide_dimension_id=idea.get("target_story_guide_dimension_id")) if idea else None))


# ---------------------------------------------------------------------------
# Composition -> public StoryCoverage/2
# ---------------------------------------------------------------------------
def compose(inp: CoverageV2Input, mapping: CoverageMapping, judgment: StoryJudgment) -> StoryCoverageContractV2:
    src_ids = [UUID(str(m.get("moment_id") or m.get("id"))) for m in inp.moment_understandings
               if (m.get("moment_id") or m.get("id"))]
    return StoryCoverageContractV2(
        story_id=inp.story_id,
        story_guide_id=str(inp.story_guide.get("story_id") or inp.story_guide.get("id") or ""),
        story_guide_version=inp.story_guide_version,
        moment_count=len(inp.moment_understandings), pending_count=inp.pending_count,
        source_understanding_ids=src_ids,
        dimension_coverage=mapping.dimension_coverage, strengths=mapping.strengths,
        redundancies=mapping.redundancies, sufficiency=judgment.sufficiency, story_idea=judgment.story_idea)


@runtime_checkable
class StoryCoverageV2Engine(Protocol):
    def compute(self, inp: CoverageV2Input) -> StoryCoverageContractV2: ...


class RealStoryCoverageV2Engine:
    """Orchestrates the frozen two-call pipeline into the public contract."""

    def __init__(self, gateway: ModelGateway, model_id: str | None = None):
        self._mapper = RealStoryCoverageMapper(gateway, model_id)
        self._judge = RealStoryJudgmentEngine(gateway, model_id)

    def compute(self, inp: CoverageV2Input) -> StoryCoverageContractV2:
        mapping, _gids = self._mapper.map(inp)
        evidence = build_judge_evidence(inp, mapping)
        judgment = self._judge.judge(evidence)
        return compose(inp, mapping, judgment)


__all__ = [
    "MAPPER_PROMPT_VERSION", "JUDGE_PROMPT_VERSION", "SCHEMA_VERSION", "DEFAULT_COVERAGE_MODEL",
    "CoverageV2Input", "CoverageUnavailableError", "material_scope", "build_judge_evidence",
    "assert_no_guide_leakage", "compose", "RealStoryCoverageMapper", "RealStoryJudgmentEngine",
    "RealStoryCoverageV2Engine", "StoryCoverageV2Engine",
]
