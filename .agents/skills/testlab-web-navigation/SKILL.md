---
name: testlab-web-navigation
description: >-
  Procedures, commands, and best practices for launching, inspecting, and interactively navigating
  the BuddyBackup Unraid testlab WebGUI using Chrome DevTools MCP. Use this skill when testing or
  verifying BuddyBackup, Unraid WebGUI features, settings, plugin installation, or web interfaces
  on local QEMU/WSL nodes (nodeA and nodeB), including taking DOM snapshots, filling forms, clicking
  buttons, taking screenshots, and troubleshooting web UI behavior.
---

# BuddyBackup Testlab & WebGUI Navigation Guide

This skill provides step-by-step instructions for interacting with the BuddyBackup Unraid test lab and driving its web interfaces interactively using Chrome DevTools MCP.

---

## 1. Testlab Architecture & Node Mapping

The test lab runs dual Unraid virtual machine instances inside WSL2 (`Ubuntu`) using QEMU on the Windows host.

| Node | Unraid Version | HTTP WebGUI | HTTPS WebGUI | SSH (Localhost) | Instance Name |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **nodeA** | `7.2.6` (Certified baseline) | `http://127.0.0.1:8080` | `https://127.0.0.1:8443` | Port `2222` | `buddybackup-node-a` |
| **nodeB** | `7.3.0` (Latest release) | `http://127.0.0.1:8081` | `https://127.0.0.1:8444` | Port `2223` | `buddybackup-node-b` |

### Default Credentials
- **Username:** `root`
- **Password:** Defined in `testlab/config/lab.local.json` under `setup.manualAccess.rootPassword` (default: `buddybackup-testlab`).

---

## 2. Fast Status Check & Helper Script

A dedicated helper script is available at `testlab/scripts/testlab-ui-helper.ps1`:

```powershell
# 1. Quick status summary of both nodes (QEMU PID, SSH port, WebGUI HTTP response)
powershell -ExecutionPolicy Bypass -File .\testlab\scripts\testlab-ui-helper.ps1 -Action Status

# 2. Output all direct URLs and credentials
powershell -ExecutionPolicy Bypass -File .\testlab\scripts\testlab-ui-helper.ps1 -Action Urls

# 3. Output machine-readable JSON (ideal for agent inspection)
powershell -ExecutionPolicy Bypass -File .\testlab\scripts\testlab-ui-helper.ps1 -Action Status -Json
```

---

## 3. Launching & Tearing Down Nodes

### Launching the Lab
To start both nodes and provision BuddyBackup and ZFS datasets:

```powershell
# Dry run (checks config and payload readiness without modifying state):
powershell -ExecutionPolicy Bypass -File .\testlab\scripts\provision-lab.ps1 -LabConfig .\testlab\config\lab.local.json

# Live execution (starts QEMU VMs in WSL and applies baseline configuration):
powershell -ExecutionPolicy Bypass -File .\testlab\scripts\provision-lab.ps1 -LabConfig .\testlab\config\lab.local.json -Execute
```

### Stopping / Tearing Down
```powershell
# Stop all running lab nodes:
powershell -ExecutionPolicy Bypass -File .\testlab\scripts\teardown-wsl-qemu-lab.ps1 -LabConfig .\testlab\config\lab.local.json -Execute

# Stop only one node:
powershell -ExecutionPolicy Bypass -File .\testlab\scripts\teardown-wsl-qemu-lab.ps1 -LabConfig .\testlab\config\lab.local.json -Execute -NodeNames nodeA
```

---

## 4. Interactive Browser Navigation with Chrome DevTools MCP

The agent has access to `chrome-devtools-mcp` tools to control headless/remote Chrome.

### Protocol & Connection Rule
- **Always use HTTP (`http://127.0.0.1:8080` or `http://127.0.0.1:8081`) rather than HTTPS.**
  Unraid generates self-signed TLS certificates for local ports. Navigating to HTTPS will show Chrome's "Your connection is not private" warning page. HTTP connects directly without certificate warnings.

### Key Tools & Standard Workflow

#### 1. Page Management
- Check existing open pages:
  `call_mcp_tool(ServerName="chrome-devtools-mcp", ToolName="list_pages", Arguments={})`
- Open a new tab:
  `call_mcp_tool(ServerName="chrome-devtools-mcp", ToolName="new_page", Arguments={"url": "http://127.0.0.1:8080"})`
- Navigate existing page:
  `call_mcp_tool(ServerName="chrome-devtools-mcp", ToolName="navigate_page", Arguments={"pageId": 1, "type": "url", "url": "http://127.0.0.1:8080/Dashboard"})`

#### 2. Analyzing the UI (`take_snapshot`)
**Always prefer `take_snapshot` over guessing selectors or taking screenshots.**
`take_snapshot` dumps the accessibility tree with roles, values, labels, and exact `uid`s (e.g. `uid=1_10`):
```json
{
  "pageId": 1
}
```
Example output:
```text
uid=1_0 RootWebArea "Tower/SetPassword" url="http://127.0.0.1:8080/login"
  uid=1_5 form
    uid=1_7 textbox "Username not changeable" disabled value="root"
    uid=1_10 textbox "Username Password" required
    uid=1_12 textbox "Confirm Password" required
    uid=1_13 button "SET PASSWORD"
```

#### 3. Entering Text into Fields (`fill`)
Use the `uid` from the snapshot:
```json
{
  "pageId": 1,
  "uid": "1_10",
  "value": "buddybackup-testlab"
}
```

> [!TIP]
> **Reactive Form Validation**: In some Unraid forms, submit buttons may remain disabled until DOM `input` or `change` events are triggered. If a button remains disabled after `fill`, use `evaluate_script` to dispatch the events:
> ```javascript
> document.querySelectorAll('input').forEach(i => {
>   i.dispatchEvent(new Event('input', { bubbles: true }));
>   i.dispatchEvent(new Event('change', { bubbles: true }));
> });
> ```

#### 4. Clicking Buttons, Tabs, and Links (`click`)
Use the target element's `uid`. Pass `includeSnapshot: true` to get the updated page state immediately in the same response:
```json
{
  "pageId": 1,
  "uid": "1_13",
  "includeSnapshot": true
}
```

#### 5. Capturing Screenshots (`take_screenshot`)
> [!IMPORTANT]
> **Omit `filePath`**: Do **not** provide a `filePath` pointing to network drive `Y:\`. Chrome DevTools MCP enforces workspace boundary restrictions and rejects mapped UNC paths (`\\192.168.0.40\...`).
> When `filePath` is omitted, the MCP tool automatically offloads the screenshot into the conversation media storage (e.g. `file:///C:/Users/.../media_0.png`). You can then view it using `view_file` or embed it in artifacts.

```json
{
  "pageId": 1
}
```

#### 6. Debugging Console & Network Requests
If a page fails to load or an AJAX action does not update the UI:
- Check JavaScript errors:
  `call_mcp_tool(ServerName="chrome-devtools-mcp", ToolName="list_console_messages", Arguments={"pageId": 1})`
- Check network calls:
  `call_mcp_tool(ServerName="chrome-devtools-mcp", ToolName="list_network_requests", Arguments={"pageId": 1})`

---

## 5. Unraid & BuddyBackup Web Interface Map

Direct URL routing on nodeA (`http://127.0.0.1:8080`) and nodeB (`http://127.0.0.1:8081`):

| Page | URL Path | Description |
| :--- | :--- | :--- |
| **Login / Setup** | `/login` | Set initial root password or log in to the server. |
| **Dashboard** | `/Dashboard` | System health, arrays, network, and BuddyBackup tile. |
| **Plugins** | `/Plugins` | Installed plugins and manual .plg URL installer tab. |
| **Tools (BuddyBackup)** | `/Tools/BuddyBackup` | Main BuddyBackup replication and dataset pairing page. |
| **Settings (BuddyBackup)** | `/Settings/BuddyBackup` | BuddyBackup configuration, schedules, and options. |
| **Shares** | `/Shares` | Unraid share manager. |
| **Tools** | `/Tools` | Registration, system logs, processes, and utilities. |

---

## 6. Standard Login Routine for Fresh or Running Nodes

1. **Navigate:** Go to `http://127.0.0.1:8080/login`.
2. **Snapshot:** Call `take_snapshot`.
3. **Determine State:**
   - If the page is **Tower/SetPassword**: Fill the password and confirmation password fields with `buddybackup-testlab`, dispatch input events, and click **"SET PASSWORD"**.
   - If the page is **Tower/Login**: Enter username `root` (if not prefilled) and password `buddybackup-testlab`, then click **"SIGN IN"**.
4. **Verify:** Confirm the page title becomes `Tower/Dashboard` or `Tower/Registration`.
