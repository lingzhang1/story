"""Story API application package (FastAPI orchestration layer).

Depends on engine Protocols (not concrete mocks) via app.deps. Owns HTTP
routing, request validation, and DTO conversion — never product AI
reasoning, which lives in the engine packages.
"""
