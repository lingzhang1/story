"""Unit tests for the mock engines (deterministic, no AWS, no network)."""

from __future__ import annotations

from contracts.schemas.domain import (
    Asset,
    Moment,
    MomentSource,
    StoryStatus,
    new_id,
)
from director_engine import DirectorEngine, MockDirectorEngine, ShotSuggestion
from edit_engine import EditEngine, MockEditEngine
from story_engine import MockStoryEngine, StoryEngine


def _make_story(raw_text: str = "a cinematic hike in the alps", title: str = "TMB"):
    eng = MockStoryEngine()
    intent = eng.derive_creative_intent(raw_text)
    return eng, eng.create_story(title, intent)


def test_story_engine_satisfies_protocol():
    assert isinstance(MockStoryEngine(), StoryEngine)


def test_director_engine_satisfies_protocol():
    assert isinstance(MockDirectorEngine(), DirectorEngine)


def test_edit_engine_satisfies_protocol():
    assert isinstance(MockEditEngine(), EditEngine)


def test_creative_intent_is_deterministic():
    eng = MockStoryEngine()
    a = eng.derive_creative_intent("sunset at the beach")
    b = eng.derive_creative_intent("sunset at the beach")
    assert (a.theme, a.tone, a.summary) == (b.theme, b.tone, b.summary)


def test_create_story_starts_active():
    _, story = _make_story()
    assert story.status is StoryStatus.ACTIVE
    assert story.title == "TMB"
    assert story.creative_intent.raw_text == "a cinematic hike in the alps"


def test_director_suggestion_is_deterministic_and_shaped():
    _, story = _make_story()
    d = MockDirectorEngine()
    s1 = d.direct_moment(story)
    s2 = d.direct_moment(story)
    assert isinstance(s1, ShotSuggestion)
    assert (s1.concept_title, s1.instruction) == (s2.concept_title, s2.instruction)
    assert s1.instruction  # non-empty
    assert s1.target_duration_seconds > 0


def test_edit_output_uses_moment_ids_and_preserves_status():
    _, story = _make_story()
    # Attach one Moment so moment_ids is exercised.
    asset = Asset(
        id=new_id(),
        local_uri="file:///Documents/clips/clip1.mov",
        duration_seconds=6.0,
        source=MomentSource.DIRECTED,
    )
    moment = Moment(id=new_id(), story_id=story.id, asset=asset, source=MomentSource.DIRECTED)
    story.add_moment(moment)

    status_before = story.status
    out = MockEditEngine().create_generated_output(story)

    assert out.story_id == story.id
    assert out.moment_ids == [moment.id]
    assert out.duration_seconds > 0
    # Producing the output alone did not change status (engine is pure).
    assert story.status == status_before
