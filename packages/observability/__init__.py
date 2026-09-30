"""Observability — structured stdout logging for the Story backend.

App Runner captures stdout/stderr to CloudWatch, so a stdlib logging
logger that emits one JSON object per line to stdout is all Milestone A
needs. No external logging dependencies.

Per 03-system-architecture.md §37: include a correlation/request id where
available; never log raw media bytes or user PII.
"""

from __future__ import annotations

import json
import logging
import sys
from datetime import datetime, timezone

_CONFIGURED: set[str] = set()


class _JsonFormatter(logging.Formatter):
    """Format each record as a single-line JSON object (JSON-ish structured
    output to stdout for CloudWatch)."""

    # Standard LogRecord attributes we do NOT copy into the "extra" bag.
    _RESERVED = {
        "name", "msg", "args", "levelname", "levelno", "pathname", "filename",
        "module", "exc_info", "exc_text", "stack_info", "lineno", "funcName",
        "created", "msecs", "relativeCreated", "thread", "threadName",
        "processName", "process", "taskName",
    }

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, object] = {
            "ts": datetime.fromtimestamp(record.created, tz=timezone.utc).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        # Merge any structured fields passed via logger.info(msg, extra={...}).
        for key, value in record.__dict__.items():
            if key not in self._RESERVED and not key.startswith("_"):
                payload[key] = value
        if record.exc_info:
            payload["exc"] = self.formatException(record.exc_info)
        return json.dumps(payload, default=str)


def get_logger(name: str = "story", level: int = logging.INFO) -> logging.Logger:
    """Return a stdlib logger emitting structured JSON lines to stdout.

    Idempotent: repeated calls for the same name do not add duplicate
    handlers. Propagation is disabled so records are not double-emitted by
    the root logger.
    """
    logger = logging.getLogger(name)
    if name not in _CONFIGURED:
        handler = logging.StreamHandler(sys.stdout)
        handler.setFormatter(_JsonFormatter())
        logger.addHandler(handler)
        logger.setLevel(level)
        logger.propagate = False
        _CONFIGURED.add(name)
    return logger
