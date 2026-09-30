"""Story API — FastAPI application (Milestone A walking skeleton).

Endpoints:
  GET  /health                     -> liveness (App Runner health check)
  POST /v1/stories                 -> create a Story (mock StoryEngine)
  POST /v1/stories/{id}/outputs    -> create a mock GeneratedOutput

The app depends on engine PROTOCOLS via app.deps (DI), so mocks can be
swapped for real AI engines without touching this module. All app/backend
routes live under /v1 (03-system-architecture.md §14).
"""

from __future__ import annotations

from uuid import UUID

from fastapi import Depends, FastAPI, HTTPException

from contracts.schemas.dto import (
    CreateStoryRequest,
    GeneratedOutputDTO,
    StoryDTO,
)
from director_engine import DirectorEngine  # noqa: F401  (available for future shoot endpoint)
from edit_engine import EditEngine
from observability import get_logger
from story_engine import StoryEngine

from app.deps import get_director_engine, get_edit_engine, get_story_engine
from app.store import InMemoryStoryStore

SERVICE_NAME = "story-api"
SERVICE_VERSION = "0.1.0"  # Milestone A


def create_app() -> FastAPI:
    """Construct the FastAPI app. A factory so tests get a fresh instance
    (and a fresh in-memory store) per app."""
    app = FastAPI(title="Story API", version=SERVICE_VERSION)
    log = get_logger("story-api")

    # Non-persistent demo store (see app/store.py). One per app instance.
    store = InMemoryStoryStore()

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok", "service": SERVICE_NAME, "version": SERVICE_VERSION}

    @app.post("/v1/stories", response_model=StoryDTO, status_code=201)
    def create_story(
        body: CreateStoryRequest,
        story_engine: StoryEngine = Depends(get_story_engine),
    ) -> StoryDTO:
        """Derive a CreativeIntent from raw_text and create a Story."""
        intent = story_engine.derive_creative_intent(body.raw_text)
        story = story_engine.create_story(body.title, intent)
        store.put(story)
        log.info(
            "story_created",
            extra={"operation": "create_story", "story_id": str(story.id)},
        )
        return StoryDTO.from_domain(story)

    @app.post(
        "/v1/stories/{story_id}/outputs",
        response_model=GeneratedOutputDTO,
        status_code=201,
    )
    def create_output(
        story_id: UUID,
        edit_engine: EditEngine = Depends(get_edit_engine),
    ) -> GeneratedOutputDTO:
        """Create a mock GeneratedOutput for a Story.

        INVARIANT: Create != Complete. This MUST NOT change story.status.
        """
        story = store.get(story_id)
        if story is None:
            raise HTTPException(status_code=404, detail="Story not found")

        status_before = story.status
        output = edit_engine.create_generated_output(story)
        story.add_generated_output(output)  # domain method leaves status untouched

        # Defensive assertion of the product invariant.
        assert story.status == status_before, "Create My Story must not change status"

        log.info(
            "generated_output_created",
            extra={
                "operation": "create_output",
                "story_id": str(story.id),
                "output_id": str(output.id),
                "status_unchanged": story.status == status_before,
            },
        )
        return GeneratedOutputDTO.from_domain(output)

    return app


# Module-level app for `uvicorn app.main:app`.
app = create_app()
