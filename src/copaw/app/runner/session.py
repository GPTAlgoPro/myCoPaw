# -*- coding: utf-8 -*-
"""Safe JSON session with filename sanitization and Unicode hardening.

Windows filenames cannot contain: \\ / : * ? " < > |
This module wraps agentscope's JSONSession so that session_id and user_id
are sanitized before being used as filenames.

It also scrubs lone surrogates and other non-UTF-8-safe codepoints from
session state before saving, so that corrupted message history can never
poison future model API calls.
"""
import json
import logging
import os
import re

from agentscope.session import JSONSession


logger = logging.getLogger(__name__)

# Characters forbidden in Windows filenames
_UNSAFE_FILENAME_RE = re.compile(r'[\\/:*?"<>|]')

# Lone surrogates: U+D800..U+DFFF — valid in Python str but invalid UTF-8.
_SURROGATE_RE = re.compile(r"[\ud800-\udfff]")


def sanitize_filename(name: str) -> str:
    """Replace characters that are illegal in Windows filenames with ``--``.

    >>> sanitize_filename('discord:dm:12345')
    'discord--dm--12345'
    >>> sanitize_filename('normal-name')
    'normal-name'
    """
    return _UNSAFE_FILENAME_RE.sub("--", name)


def _scrub_surrogates(obj):
    """Recursively replace lone surrogates in all strings within *obj*.

    Returns a new object (leaves the original untouched).
    """
    if isinstance(obj, str):
        return _SURROGATE_RE.sub("\ufffd", obj)
    if isinstance(obj, dict):
        return {_scrub_surrogates(k): _scrub_surrogates(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        cleaned = [_scrub_surrogates(item) for item in obj]
        return type(obj)(cleaned)
    return obj


class SafeJSONSession(JSONSession):
    """JSONSession subclass that sanitizes session_id / user_id before
    building file paths, and scrubs invalid Unicode from state dicts.
    """

    def _get_save_path(self, session_id: str, user_id: str) -> str:
        """Return a filesystem-safe save path.

        Overrides the parent implementation to ensure the generated
        filename is valid on Windows, macOS and Linux.
        """
        os.makedirs(self.save_dir, exist_ok=True)
        safe_sid = sanitize_filename(session_id)
        safe_uid = sanitize_filename(user_id) if user_id else ""
        if safe_uid:
            file_path = f"{safe_uid}_{safe_sid}.json"
        else:
            file_path = f"{safe_sid}.json"
        return os.path.join(self.save_dir, file_path)

    async def save_session_state(
        self,
        session_id: str,
        user_id: str = "",
        **state_modules_mapping,
    ) -> None:
        """Save state after scrubbing lone surrogates.

        Upstream uses ``errors="surrogatepass"`` which lets lone surrogates
        leak into the JSON file.  On the next load the corrupted strings
        end up in the model context and blow up the API call with
        ``UnicodeDecodeError`` deep inside the HTTP layer.

        We intercept the state dicts, scrub surrogates, and write plain
        ``encoding="utf-8"`` so the file is always valid UTF-8.
        """
        state_dicts = {
            name: _scrub_surrogates(mod.state_dict())
            for name, mod in state_modules_mapping.items()
        }
        path = self._get_save_path(session_id, user_id=user_id)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(state_dicts, fh, ensure_ascii=False)

    async def load_session_state(
        self,
        session_id: str,
        user_id: str = "",
        allow_not_exist: bool = True,
        **state_modules_mapping,
    ) -> None:
        """Load state, scrubbing any surrogates left by older saves."""
        path = self._get_save_path(session_id, user_id=user_id)
        if not os.path.exists(path):
            if allow_not_exist:
                logger.info(
                    "Session file %s does not exist. Skip loading.",
                    path,
                )
                return
            raise ValueError(
                f"Session file {path} does not exist.",
            )

        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            states = _scrub_surrogates(json.load(fh))

        for name, mod in state_modules_mapping.items():
            if name in states:
                mod.load_state_dict(states[name])
        logger.info("Loaded session state from %s.", path)
