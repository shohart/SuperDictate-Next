"""Dictation for Windows, local push-to-talk dictation.

A Windows port of https://github.com/shlgd/SuperDictate (macOS, Swift),
which is itself based on Parakey by Richard Courtman. Same speech model
(NVIDIA Parakeet TDT 0.6B v3), same interaction model, MIT licensed.
"""

from .version import VERSION

__all__ = ["VERSION"]
