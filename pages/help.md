# The /sc:help page

Show the person one plain page, built from the steps below. Do not sign anyone in. Do not mention REST, stub
files, `/sc-bootstrap`, keys or key files.

1. **Check the connection.** You need the tool `mcp__sc__whoami`. If it is listed as deferred, load it first
   (ToolSearch, query `select:mcp__sc__whoami`). If there is no `mcp__sc__whoami` tool at all, Symmeno is not
   connected in this folder: show only the "How to start" part below, then "Symmeno is not connected in this
   folder yet.", and stop.

2. **Ask Core.** Call `mcp__sc__whoami` with no arguments. If Core refuses, show its sentence as it is and stop.

3. **Show the page**, in this order:

   **How to start**
   - `/sc:start <crew>` starts the crew's lead.
   - `/sc:start <crew> <teammate>` starts that teammate.
   - Add a project after either: `/sc:start <crew> <project>` or `/sc:start <crew> <teammate> <project>`.
   - First time in a folder, `/sc:start <crew>` connects it (it asks once if this computer runs more than one
     crew). Then type `/reload-plugins` (in the desktop app: open a new session in the folder) and
     `/sc:start <crew>` again.

   **Your crew:** `crew.name` (type `crew.slug`).

   **Teammates:** a table with columns Name, Role, Type, in the order `teammates` gives. Type is the part of the
   slug before the first `-` (for `lena-ux`, type `lena`). Mark the row whose slug equals `lead` with "(lead)" after
   the name.

   **Recent projects:** if `recent_projects` is not empty, list them as the names to reuse after `/sc:start`, so a
   project keeps one spelling. If it is empty, leave this part out.

   End with: "The lead brings teammates in when you ask, so you usually start only the lead."

If `whoami` has no `teammates` field, this Core is older than the plugin: show "How to start", then
"Your crew: `team`", then "This Symmeno Core does not list its teammates yet." and stop.
