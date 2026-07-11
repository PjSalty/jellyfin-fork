# Security

Report vulnerabilities privately through GitHub security advisories on this repository (Security tab, "Report a vulnerability"). Don't open public issues for security reports.

Scope worth knowing when assessing impact: the patches touch migration gating, background-task scheduling, and the auth token lookup path. The token read-through only widens a cache miss to one database query; no credential material is stored anywhere new.
