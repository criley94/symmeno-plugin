# The /sc:help page

Show the person one plain page, built from the steps below. Do not sign anyone in. Do not mention REST, stub
files, `/sc-bootstrap`, keys or key files.

1. **Check the connection.** You need a `whoami` tool on a Symmeno connection: `mcp__sc__whoami` (a crew-key
   connection in this folder) or, if that does not exist, `mcp__plugin_sc_sc__whoami` (the plugin's signed-in
   connection). If one is listed as deferred, load it first (ToolSearch, query `select:mcp__sc__whoami` or
   `select:mcp__plugin_sc_sc__whoami`). If neither exists, show only the "How to start" part below, then "Symmeno is
   not connected here yet: /sc:start <crew> signs you in (or connects this folder on a shared computer).", and stop.

2. **Ask Core.** Call that `whoami` with no arguments. If Core refuses, show its sentence as it is and stop.

3. **Show the page**, in this order:

   **How to start**
   - `/sc:start <crew>` starts the crew's lead.
   - `/sc:start <crew> <teammate>` starts that teammate.
   - Add a project after either: `/sc:start <crew> <project>` or `/sc:start <crew> <teammate> <project>`.
   - First time on this computer, `/sc:start <crew>` signs you in once (a link opens in your browser) and carries on.
     On a shared computer it connects the folder with the crew's key instead, asking once; then type
     `/reload-plugins` (in the desktop app: open a new session in the folder) and `/sc:start <crew>` again.

   **Your crew** (crew-key connection, or a signed-in connection that has started a crew): `crew.name` (type
   `crew.slug`).
   **Your crews** (signed-in connection, nothing started yet): "Signed in as <email>." then one line per entry of
   `crews`: `name` (type `slug`), with its lead's name.

   **Teammates:** a table with columns Name, Role, Type, in the order `teammates` gives, for the crew above; on a
   signed-in connection with several crews, one table per crew. Type is the part of the slug before the first `-`
   (for `lena-ux`, type `lena`). Mark the row whose slug equals `lead` with "(lead)" after the name.

   **Recent projects:** if `recent_projects` is present and not empty, list them as the names to reuse after
   `/sc:start`, so a project keeps one spelling. If it is empty or absent, leave this part out.

   End with: "The lead brings teammates in when you ask, so you usually start only the lead."

If `whoami` has no `teammates` field and no `crews` field, this Core is older than the plugin: show "How to start",
then "Your crew: `team`", then "This Symmeno Core does not list its teammates yet." and stop.
