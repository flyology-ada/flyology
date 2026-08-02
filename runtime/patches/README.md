# Runtime patch families

Patch directories name the GNAT release range whose bundled runtime sources
have been tested. `prepare-rts.sh` reads the active compiler release and
refuses to continue when no matching family exists; it never guesses or falls
back to an unverified patch.

`gnat-13-16` is verified against the Alire `gnat_native` releases 13.2.2,
14.1.3, 14.2.1, 15.1.2, 15.3.1, and 16.1.0. Platform-specific changes live in
`darwin/` and `linux/`; changes shared by both GNARL implementations live in
`common/`.

When a future GNAT release changes the affected GNARL sources, add a new
versioned family rather than weakening patch validation. A family may span
multiple majors only while the same patch is built and behaviorally tested on
every advertised major.
