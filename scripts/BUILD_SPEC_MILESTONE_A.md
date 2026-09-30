# Milestone A — Walking Skeleton Build Spec (for the build worker)

Repo root: `/Users/lingzhang/Workplace/story`. Directory tree already exists:
`apps/api`, `apps/ios`, `packages/{story_engine,director_engine,asset_engine,music_engine,edit_engine,model_gateway,observability}`,
`infrastructure/cdk`, `contracts/{schemas,openapi}`, `evals`, `scripts`. Root `.gitignore` exists.
`contracts/schemas/domain.py` ALREADY EXISTS (Story/StoryStatus/CreativeIntent/Moment/Asset/GeneratedOutput/MomentSource dataclasses) — READ it and reuse as domain source of truth; do not redefine. `packages/story_engine/__init__.py` exists.

## Specs (source of truth — READ first, authoritative, do NOT redesign)
- specs/story-specs/spec/production/story-production-latest.md
- specs/story-specs/spec/implementation-plan/mvp-build-plan.md
- specs/story-specs/spec/implementation-plan/02-core-story-schema.md
- specs/story-specs/spec/implementation-plan/03-system-architecture.md
- specs/story-specs/spec/implementation-plan/04-aws-infrastructure.md

## Architecture (fixed)
Python 3.12 / FastAPI; AWS App Runner; ECR; TypeScript AWS CDK. NO API Gateway, DynamoDB, SQS, Lambda, S3, Cognito this milestone. Mock intelligence only — NO Bedrock, no real AI.

## PART A — Engine packages (packages/*)
For story_engine, director_engine, edit_engine: a Protocol interface + a deterministic Mock (MockStoryEngine, MockDirectorEngine, MockEditEngine). Engines must NOT import each other. Determinism: derive mock output from inputs (e.g. hash of raw_text). Interfaces:
- StoryEngine.derive_creative_intent(raw_text)->CreativeIntent; StoryEngine.create_story(title, intent)->Story
- DirectorEngine.direct_moment(story)->small dataclass with a shot-suggestion string
- EditEngine.create_generated_output(story)->GeneratedOutput (title, duration, moment_ids from story.moments)
asset_engine, music_engine, model_gateway: __init__.py with a Protocol stub + minimal mock or a clear "not needed for slice" docstring — do not over-build. observability: get_logger() returning a stdlib logging logger with JSON-ish structured output to stdout (App Runner->CloudWatch).

## PART B — Contracts (contracts/)
- contracts/schemas/dto.py: Pydantic v2 API WIRE models (StoryDTO, CreativeIntentDTO, MomentDTO, AssetDTO, GeneratedOutputDTO, StoryStatus enum) — network only, distinct from domain.py, NO persistence/SwiftData fields. Provide to_dto/from_domain helpers.
- contracts/schemas/__init__.py exporting domain + dto names.
- contracts/generate_schema.py: writes contracts/schemas/story.schema.json from Pydantic model_json_schema().
- contracts/openapi/README.md: explains openapi.json is emitted by FastAPI at /openapi.json.
- scripts/export_openapi.py: imports the app, dumps app.openapi() to contracts/openapi/openapi.json.
Preserve the three-way distinction: domain model / API DTO / persistence (SwiftData, iOS side).

## PART C — Backend (apps/api)
FastAPI app apps/api/app/main.py with create_app(). GET /health -> {"status":"ok","service":"story-api","version":<const>}. DI module apps/api/app/deps.py returns Protocol-typed mocks (app depends on interfaces, not concrete classes). Endpoints (in-memory dict store, clearly commented as non-persistent demo — MVP has no server DB):
- POST /v1/stories (body: raw_text + title) -> MockStoryEngine -> StoryDTO
- POST /v1/stories/{id}/outputs -> mock GeneratedOutputDTO; MUST NOT change status
pyproject.toml deps: fastapi, uvicorn[standard], pydantic>=2; dev: pytest, httpx. Make packages/* importable from repo root (simplest working approach: root pyproject or conftest.py adding paths, or editable installs). `pytest` must pass from repo root and `uvicorn` must run.

## PART D — Container
apps/api/Dockerfile: python:3.12-slim, install deps, copy packages/ + apps/api, EXPOSE 8080, CMD uvicorn 0.0.0.0:8080. Add .dockerignore. Same app runs locally / container / App Runner. NO AWS-specific code in engines.

## PART E — CDK (infrastructure/cdk)
TypeScript CDK: cdk.json, package.json, tsconfig.json, bin/app.ts, lib/story-api-stack.ts. Provision ONLY: ECR repo; App Runner service pulling the ECR image (prefer @aws-cdk/aws-apprunner-alpha if it installs, else L1 CfnService — whichever synths cleanly on cdk 2.1143); App Runner instance role; rely on built-in CloudWatch logging. Health check path /health, port 8080. NO SQS/Lambda/DynamoDB/Fargate/API Gateway/Cognito/S3.
Jest test test/story-api-stack.test.ts asserting: ECR repo present; App Runner service present; health check path /health; and ZERO of AWS::DynamoDB, AWS::SQS, AWS::Lambda::Function, AWS::S3::Bucket, AWS::ApiGateway* resources.
package.json scripts: build (tsc), synth, test (jest). devDeps: aws-cdk-lib, constructs, typescript, ts-node, jest, ts-jest, @types/jest, @types/node (+ @aws-cdk/aws-apprunner-alpha if used). Try `npm install` once in infrastructure/cdk and REPORT whether it succeeded. Do NOT run cdk synth (parent does it).

## PART F — iOS source (apps/ios) — author only, do NOT compile
Complete SwiftUI app "Story" for the slice: Launch->Home->Start a Story->Creative Direction (text)->mock CreativeIntent->create Story->persist SwiftData->Story Home->Shoot a Moment->Mock Director suggestion->real camera (AVFoundation)->save local video (file in app Documents dir; store PATH/bookmark in SwiftData, NEVER the blob)->create+persist Moment->back to Story Home->Create My Story->mock GeneratedOutput persisted (metadata only). Feature-oriented structure per 03-system-architecture.md.
Files: apps/ios/README.md (EXACT Xcode setup: how to create the project and add these sources OR a Swift Package approach — pick least error-prone for a solo dev and document it; bundle id, Info.plist keys NSCameraUsageDescription/NSMicrophoneUsageDescription/NSPhotoLibraryUsageDescription, signing, target iOS 17+); SwiftData @Model classes (StoryModel, MomentModel, AssetModel, GeneratedOutputModel — media as relative file path, not Data); protocol-based engine clients (StoryEngineProtocol/DirectorEngineProtocol/EditEngineProtocol + Mock* impls, UI depends on protocols); SwiftUI views (HomeView, CreativeDirectionView, StoryHomeView, ShootMomentView with a UIViewControllerRepresentable camera, CreateMyStoryView); app entry StoryApp.swift with ModelContainer; MediaStore helper resolving/playing local video paths. XCTest files for: Story creation, Story persistence, Moment creation, Moment persistence, GeneratedOutput persistence, active/completed status model, media-path resolution.

## Constraints
Local-first: no media upload, no cloud URLs for assets, no video blobs in SwiftData. No real AI. No unnecessary AWS. Minimal — no abstractions just to fill dirs.

## Report back (verifiable)
1. Full file list grouped by part.
2. Whether backend pytest passes — run it (venv: python3.12 -m venv .venv; pip install deps or -e .; report exact command + result).
3. Whether `npm install` in infrastructure/cdk succeeded.
4. Spec inconsistencies found.
5. Anything not verified.
DO NOT: cdk deploy, cdk synth, git commit, any AWS calls, install Xcode, run xcodebuild.
