# Bundled SQLite

This directory contains the SQLite 3.53.4 amalgamation from the official
SQLite release. SQLite is public domain.

Source archive: `https://www.sqlite.org/2026/sqlite-amalgamation-3530400.zip`

Archive SHA3-256:
`628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e`

The amalgamation is used only when a system `sqlite3` dependency is not
available, or when Meson is configured with `-Dsqlite=bundled`.
