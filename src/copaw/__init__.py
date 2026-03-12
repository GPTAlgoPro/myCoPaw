# -*- coding: utf-8 -*-
import logging
import os
import time


# Filter Nacos SDK warning from agentscope-runtime before any import.
# This warning occurs at module import time when nacos-sdk-python is not
# installed, but copaw does not use Nacos functionality.
class _NacosWarningFilter(logging.Filter):
    """Filter out Nacos SDK unavailability warnings from agentscope-runtime."""

    def filter(self, record: logging.LogRecord) -> bool:
        msg = record.getMessage()
        if "NacosRegistry" in msg or "nacos-sdk-python" in msg:
            return False
        return True


logging.getLogger().addFilter(_NacosWarningFilter())

from .utils.logging import setup_logger  # noqa: E402

# Fallback before we can safely read canonical constant definitions.
LOG_LEVEL_ENV = "COPAW_LOG_LEVEL"

_bootstrap_err: Exception | None = None
try:
    # Load persisted env vars before importing modules that read env-backed
    # constants at import time (e.g., WORKING_DIR).
    from .envs import load_envs_into_environ

    load_envs_into_environ()
except Exception as exc:
    # Best effort: package import should not fail if env bootstrap fails.
    _bootstrap_err = exc

_t0 = time.perf_counter()
setup_logger(os.environ.get(LOG_LEVEL_ENV, "info"))
if _bootstrap_err is not None:
    logging.getLogger(__name__).warning(
        "copaw: failed to load persisted envs on init: %s",
        _bootstrap_err,
    )
logging.getLogger(__name__).debug(
    "%.3fs package init",
    time.perf_counter() - _t0,
)
