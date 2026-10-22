"""Entry point of ``SuperDictateOvHost.exe``, the NPU speech-recognition host.

A separate executable rather than a flag on ``SuperDictate.exe``: the app is
a windowed (no console) build, and a helper that speaks binary frames on
stdin/stdout wants real standard handles. See :mod:`superdictate.openvino_host`.
"""

import sys

from superdictate.openvino_host import main

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
