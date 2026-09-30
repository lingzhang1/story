"""Model Gateway — provider-independent AI access.

Milestone A uses MOCK intelligence only, so NO provider is wired here.
This package exists to hold the boundary: it is the ONLY backend module
that will ever know provider-specific model APIs (Bedrock / external),
per 03-system-architecture.md §15.

Not needed for the walking-skeleton slice beyond this Protocol stub —
real provider adaptation, structured-output enforcement, retries, and
usage logging arrive with Milestone C (Creative Intent).
"""

from __future__ import annotations

from typing import Any, Protocol, runtime_checkable


@runtime_checkable
class ModelGateway(Protocol):
    """Provider-independent structured-generation interface (stub).

    A real implementation routes to Amazon Bedrock or an approved external
    provider, enforces structured output, and logs usage/latency. Model
    names are configuration, never domain constants.
    """

    def generate_structured(self, request: dict[str, Any]) -> dict[str, Any]:
        """Return a structured (schema-conforming) model response."""
        ...
