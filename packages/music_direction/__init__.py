"""MusicDirection Engine — infer the intended soundtrack CHARACTER (Milestone M-c).

MusicDirection is a lightweight, relatively-stable *feel* (not a track): mood_tags
+ energy + a short human summary. Per the M-c owner decision it is inferred from:

  - CreativeIntent (desired_feeling, style_tags, pace, summary)
  - StoryGuide.framing_summary  (lightweight creative context only)

It does NOT consume StoryCoverage, and is NOT regenerated as Moments arrive.

INFERENCE IS DETERMINISTIC — no model call. CreativeIntent is already the product
of the (Opus) resolver; MusicDirection is a cheap categorical projection of that
output plus the Guide's one-line framing. This matches the owner directive
("choose the simplest inference consistent with existing architecture; do not
assume another expensive Opus call") and mirrors the frozen Figma's own
deterministic `inferMusicLabel`. A model call would add cost + latency + a second
place for the feel to drift from CreativeIntent, with no evidenced quality gain.

A user-authored MusicDirection OVERRIDES this inference and is never regenerated
here (the caller owns persistence + override precedence).
"""

from __future__ import annotations

from typing import Protocol, runtime_checkable

from contracts.schemas.ai_contracts import (
    CreativeIntentContract,
    MusicDirectionContract,
    MusicEnergy,
    Pace,
)

# pace -> soundtrack energy (categorical, no numeric scores)
_PACE_ENERGY: dict[Pace, MusicEnergy] = {
    Pace.SLOW: MusicEnergy.LOW,
    Pace.MODERATE: MusicEnergy.MEDIUM,
    Pace.FAST: MusicEnergy.HIGH,
}

# feeling/style keyword -> a mood tag (first match wins per keyword; order-stable)
_MOOD_KEYWORDS: tuple[tuple[tuple[str, ...], str], ...] = (
    (("epic", "grand", "cinematic", "sweeping"), "cinematic"),
    (("emotional", "moving", "tender", "heartfelt", "nostalgic"), "emotional"),
    (("intimate", "personal", "warm", "close"), "intimate"),
    (("calm", "quiet", "still", "minimal", "serene", "peaceful"), "calm"),
    (("dreamy", "ethereal", "atmospheric", "ambient"), "atmospheric"),
    (("playful", "fun", "bright", "lively"), "playful"),
    (("energetic", "kinetic", "driving", "upbeat"), "energetic"),
    (("gritty", "raw", "intense"), "gritty"),
    (("hopeful", "uplifting", "triumphant"), "uplifting"),
)


@runtime_checkable
class MusicDirectionEngine(Protocol):
    def infer(
        self, intent: CreativeIntentContract, guide_framing_summary: str | None = None
    ) -> MusicDirectionContract:
        """Infer intended soundtrack character. Deterministic, no model call."""
        ...


class DeterministicMusicDirectionEngine:
    """Projects CreativeIntent (+ optional Guide framing) into MusicDirection.

    Pure, deterministic, cheap. Never fabricates beyond the intent's own words."""

    def infer(
        self, intent: CreativeIntentContract, guide_framing_summary: str | None = None
    ) -> MusicDirectionContract:
        # ---- energy from pace ----
        energy = _PACE_ENERGY.get(intent.pace) if intent.pace else None

        # ---- mood_tags from desired_feeling + style_tags (dedup, order-stable) ----
        hay_terms = list(intent.desired_feeling or []) + list(intent.style_tags or [])
        hay = " ".join(hay_terms).lower()
        mood_tags: list[str] = []
        for keywords, tag in _MOOD_KEYWORDS:
            if any(k in hay for k in keywords) and tag not in mood_tags:
                mood_tags.append(tag)
        # fall back to the raw desired_feeling words if no keyword matched, so we
        # never emit an empty, generic feel — but keep it the intent's own vocab.
        if not mood_tags and intent.desired_feeling:
            mood_tags = [f.lower() for f in intent.desired_feeling][:3]

        # ---- summary: the Guide's framing is the lightweight creative context ----
        feel_phrase = " · ".join(mood_tags) if mood_tags else "fitting"
        article = "An" if feel_phrase[:1].lower() in "aeiou" else "A"
        framing = (guide_framing_summary or "").strip()
        if framing:
            summary = f"{article} {feel_phrase} soundtrack for {framing[0].lower()}{framing[1:]}"
        else:
            base = (intent.summary or "this Story").strip()
            summary = (
                f"{article} {feel_phrase} soundtrack for {base[0].lower()}{base[1:]}"
                if base else f"{article} {feel_phrase} soundtrack"
            )

        return MusicDirectionContract(
            summary=summary,
            mood_tags=mood_tags,
            energy=energy,
            progression=None,  # structured arc is MusicPlan's job, not MusicDirection
            raw_user_description=None,  # set only when user authors it
        )


__all__ = [
    "MusicDirectionEngine",
    "DeterministicMusicDirectionEngine",
]
