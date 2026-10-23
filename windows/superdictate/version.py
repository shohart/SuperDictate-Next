"""The port's version.

Tracks the macOS build it is a port of, rather than carrying its own
numbering: the two ship the same features from the same repository, and two
version lines for one product is a support problem nobody needs. Read from
swift/Info.plist by hand when bumping — there is no build step here that
could read it automatically.
"""

VERSION = "0.8.4"
UPSTREAM_BASE = (
    "SuperDictate Next (macOS), itself a fork of SuperDictate by shlgd "
    "and Parakey by Richard Courtman"
)
