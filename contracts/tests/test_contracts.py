"""Contract tests: domain -> DTO conversion and JSON Schema generation."""

from __future__ import annotations

from contracts.generate_schema import build_schema
from contracts.schemas.domain import (
    Asset,
    Moment,
    MomentSource,
    StoryStatus,
    new_id,
)
from contracts.schemas.dto import GeneratedOutputDTO, StoryDTO
from story_engine import MockStoryEngine
from edit_engine import MockEditEngine


def _story_with_moment_and_output():
    eng = MockStoryEngine()
    story = eng.create_story("Trip", eng.derive_creative_intent("a bright playful day out"))
    asset = Asset(
        id=new_id(),
        local_uri="file:///Documents/clips/a.mov",
        duration_seconds=5.0,
        source=MomentSource.EXISTING_MEDIA,
    )
    story.add_moment(
        Moment(id=new_id(), story_id=story.id, asset=asset, source=MomentSource.EXISTING_MEDIA)
    )
    story.add_generated_output(MockEditEngine().create_generated_output(story))
    return story


def test_story_dto_round_trips_from_domain():
    story = _story_with_moment_and_output()
    dto = StoryDTO.from_domain(story)

    assert dto.id == story.id
    assert dto.status == StoryStatus.ACTIVE.value or dto.status.value == "active"
    assert len(dto.moments) == 1
    assert dto.moments[0].asset.local_uri == "file:///Documents/clips/a.mov"
    assert len(dto.generated_outputs) == 1
    assert dto.generated_outputs[0].moment_ids == [story.moments[0].id]

    # Serializes cleanly to JSON (wire form).
    payload = dto.model_dump(mode="json")
    assert payload["title"] == "Trip"


def test_generated_output_dto_metadata_only():
    story = _story_with_moment_and_output()
    out = story.generated_outputs[0]
    dto = GeneratedOutputDTO.from_domain(out)
    fields = set(dto.model_dump().keys())
    # No media blob / cloud url fields — metadata only.
    assert "media" not in fields and "url" not in fields and "blob" not in fields
    assert dto.duration_seconds > 0


def test_json_schema_builds():
    schema = build_schema()
    assert schema["title"] == "Story"
    assert "properties" in schema
    assert "creative_intent" in schema["properties"]
