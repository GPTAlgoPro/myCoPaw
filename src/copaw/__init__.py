# -*- coding: utf-8 -*-
import logging
import os
import time
import warnings

# Filter websockets deprecation warnings from third-party libraries
# (lark_oapi/websockets legacy API usage).
# Keep this at package-import time so CLI + uvicorn workers both inherit it.
warnings.filterwarnings(
    "ignore",
    message=r"websockets\.legacy is deprecated.*",
    category=DeprecationWarning,
)
warnings.filterwarnings(
    "ignore",
    message=r"websockets\.InvalidStatusCode is deprecated.*",
    category=DeprecationWarning,
)
# Be explicit about source modules as an extra safeguard when Python warning
# policy is configured externally (e.g. PYTHONWARNINGS=default).
warnings.filterwarnings(
    "ignore",
    category=DeprecationWarning,
    module=r"lark_oapi\.ws\.client",
)
warnings.filterwarnings(
    "ignore",
    category=DeprecationWarning,
    module=r"websockets\.legacy(\..*)?",
)

# Silence noisy MCP transport INFO logs from third-party client internals.
for _logger_name in (
    "mcp.client.session._stateful_client_base",
    "_stateful_client_base",
):
    logging.getLogger(_logger_name).setLevel(logging.WARNING)

# Some MCP/SDK dependencies emit logs via loguru instead of stdlib logging.
# Disable the known noisy logger names if loguru is available.
try:
    from loguru import logger as _loguru_logger

    # Disable noisy MCP connection logs regardless of exact module naming.
    for _module_name in (
        "_stateful_client_base",
        "mcp.client.session._stateful_client_base",
        "mcp.client.session",
        "mcp.client",
        "mcp",
    ):
        _loguru_logger.disable(_module_name)
except Exception:
    pass

from .utils.logging import setup_logger

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
