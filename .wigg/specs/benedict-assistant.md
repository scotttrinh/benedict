# Spec: Benedict Assistant (Deployment Pattern)

**Status:** Draft / RFC
**Context:** Defining the "Life OS" capabilities of Benedict.
**Philosophy:** "Benedict is the Engine; The Assistant is a Run-Configuration."

## 1. Concept

"Benedict Assistant" is **not a separate package**. It is a deployment pattern where the standard `benedict` package is run in **Headless Mode** (via an Emacs Daemon), configured to act as an always-on Life Operating System.

This requires adding specific capabilities (Modules) to the core `benedict` package that enable headless, event-driven operation.

## 2. New Core Modules

To support this pattern, `benedict` will implement the following modules. These can be used interactively in a user's coding session *or* headless in the daemon.

### 2.1 `benedict-matrix.el` (The Connectivity Bus)
**Role:** Enables Benedict to talk to the outside world (Mobile, other Emacs instances).

*   **Functionality:**
    *   **Listener:** Connects to a Matrix homeserver using `ement.el` (or internal client).
    *   **Router:** Maps Room IDs -> Agent Profiles (e.g., `#shopping` -> `shopper-agent`, `#control` -> `router-agent`).
    *   **Input Handler:** Accepts Text, Images, and Files.
    *   **Output Handler:** Renders agent responses (markdown) back to the room.

### 2.2 `benedict-scheduler.el` (The Heartbeat)
**Role:** Enables Benedict to act without user provocation.

*   **Functionality:**
    *   Wraps Emacs timers (`run-at-time`, `run-with-idle-timer`).
    *   **Registry:** allows registering "Jobs":
        ```elisp
        (benedict-schedule-job
          :id 'morning-briefing
          :cron "0 8 * * *"  ;; Or simple string "08:00am"
          :agent-profile 'personal-secretary
          :prompt "Check org-agenda and write a summary to #general"
          :target-room "!roomid:matrix.org")
        ```
    *   **Persistence:** Jobs should ideally survive restarts (saved to a sexp file).

### 2.3 `benedict-tools-browser.el` (The Eyes)
**Role:** Enables interaction with the modern dynamic web (SaaS apps).

*   **Tool:** `browser-cdp`
*   **Mechanism:** Connects to a headless Chrome/Chromium instance via Chrome DevTools Protocol (CDP) over WebSocket.
*   **Capabilities:**
    *   `navigate(url)`
    *   `screenshot()` (Returned as image to Matrix)
    *   `click(selector)`
    *   `type(selector, text)`
    *   `extract(selector)`

### 2.4 `benedict-context-life.el` (The Context)
**Role:** Adapters for Emacs "Life" packages.

*   **Org Adapter:** Tools to read Agenda, search Roam notes, and Capture items.
*   **Mail Adapter:** Tools to read headers/bodies from `mu4e` or `notmuch`.
*   **System Adapter:** `sys-exec` for safe, non-interactive shell commands.

## 3. Architecture: The Matrix Mesh

This deployment pattern implies a "Two-Emacs" topology connected by Matrix.

1.  **The Daemon (Service):**
    *   Runs `emacs --daemon`.
    *   Loads `benedict`.
    *   Starts `benedict-matrix` (listener) and `benedict-scheduler`.
    *   **Identity:** `@benedict-bot:local`.

2.  **The Client (Coding Emacs):**
    *   User's daily driver.
    *   Connects to Matrix via `ement.el`.
    *   **Interaction:** User talks to the Daemon via the `#control` room.

3.  **The Mobile (Element App):**
    *   User's phone.
    *   Connects to Matrix via Tailscale.
    *   **Interaction:** User sends photos/voice-notes to `#control`.

## 4. Deployment: The Nix Module

The "Product" is a **NixOS / Home Manager Module** that orchestrates this stack.

**`modules/benedict-service.nix`:**
```nix
{ config, lib, pkgs, ... }:
{
  services.benedict-assistant = {
    enable = true;
    
    # Isolation
    user = "benedict"; 
    home = "/var/lib/benedict";
    
    # Dependencies
    package = pkgs.emacsWithPackages (epkgs: [ 
      epkgs.benedict 
      epkgs.ement 
      epkgs.mu4e 
    ]);

    # Infrastructure
    services.matrix-synapse.enable = true; # Optional local homeserver
    services.headless-chrome.enable = true; # For CDP tools
    
    # Configuration (The Init File)
    config = ''
      (require 'benedict-assistant-loader)
      
      ;; Connect to the Mesh
      (benedict-matrix-start 
        :user "@benedict:local" 
        :token (f-read-text "/run/secrets/matrix-token"))
      
      ;; Start the Heartbeat
      (benedict-scheduler-start)
      
      ;; Load Life Context
      (setq org-directory "/home/shared/org")
      (benedict-load-skills "/home/shared/benedict/skills")
    '';
  };
}
```

## 5. The "Learning Loop" (Self-Extension)

Because the Daemon runs unattended, the **Dynamic Skills** capability (`skill-save`) is critical.

*   **Scenario:** Daemon tries to check a new website for a price. It fails.
*   **Recovery:** Daemon (using `exec-elisp`) iterates on a new scraping script until it works.
*   **Persistence:** Daemon saves the script as a new Skill.
*   **Result:** The Assistant gets smarter without a code deploy.

## 6. Implementation Plan

1.  **Core Extension:** Add `benedict-matrix` and `benedict-scheduler` to the main repo.
2.  **Tooling:** Add `benedict-tools-browser` (CDP wrapper).
3.  **Nix Packaging:** Create the `flake.nix` and module definition.
4.  **Verification:** "The REI Shoe Test" (Mobile Photo -> Matrix -> Daemon -> Org Capture).

## 7. Resources

*   **CDP in Emacs:** `chrome.el` or direct websocket via `websocket.el`.
*   **Matrix:** `ement.el` (likely robust enough for bot usage).
*   **Scheduler:** Native `timer.el`.
