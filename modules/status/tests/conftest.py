"""Puts the plugin on sys.path and sets the env the plugin reads."""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "plugin"))
os.environ.setdefault("STATUS_KEY_PARAMETER", "/eggdrop/status-key")
