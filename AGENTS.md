# Agent Guidelines & Development Rules for BuddyBackup

## External Vendor Dependencies Policy
- **DO NOT MODIFY EXTERNAL DEPENDENCIES**: The following directories and files contain upstream vendor dependencies:
  - `src/usr/local/emhttp/plugins/buddybackup/deps/sanoid` (upstream Sanoid by Jim Salter)
  - `src/usr/local/emhttp/plugins/buddybackup/deps/syncoid` (upstream Syncoid by Jim Salter)
  - `src/usr/local/emhttp/plugins/buddybackup/deps/sanoid.defaults.conf`
  - `deps/*` (bundled third-party packages: mbuffer, perl packages)
- **Zero Modifications Rule**: Do **not** make code edits, patches, or modifications directly inside external dependency files. Modifying external dependencies makes upgrading to newer upstream releases difficult and error-prone.
- **Implement Customizations via Wrappers**: Any plugin-specific customizations, safety guards, workarounds, or behavioral enhancements must be implemented in BuddyBackup's own scripts and pages:
  - `src/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup`
  - `src/usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php`
  - WebGUI pages (`*.page`) or dedicated plugin helper scripts.
