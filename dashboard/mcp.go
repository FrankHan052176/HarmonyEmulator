package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
)

// Streamable HTTP MCP (JSON-RPC 2.0) server at /mcp for Fancy and other MCP clients.
// Compatible with MCP 2025-03-26 (and 2024-11-05) over HTTP POST with application/json.

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type rpcResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Result  any             `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

type mcpToolDef struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	InputSchema map[string]any `json:"inputSchema"`
}

type mcpContent struct {
	Type     string `json:"type"`
	Text     string `json:"text,omitempty"`
	Data     string `json:"data,omitempty"`
	MimeType string `json:"mimeType,omitempty"`
}

func mcpToolDefs() []mcpToolDef {
	return []mcpToolDef{
		{
			Name:        "ohos_status",
			Description: "Inspect HarmonyEmulatorDashboard status: runtime usability, running HarmonyOS 7 QEMU instances, hdc ports, UDIDs, saved instances, and dashboard/MCP URLs. Starts nothing.",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"instance": map[string]any{"type": "string", "description": "Optional instance name filter"},
				},
			},
		},
		{
			Name:        "ohos_launch",
			Description: "Start or reuse a Linux 6.6 + HarmonyOS 7.0.0.107 emulator under open-source QEMU arm64_virt and wait until SceneBoard is ready and unlocked.",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"instance":        map[string]any{"type": "string", "description": "Instance name (default: default)"},
					"profile":         map[string]any{"type": "string", "enum": []string{"phone", "pc"}, "description": "Device profile: phone (1080x2340, default) or pc (1920x1080 HarmonyOS PC)"},
					"width":           map[string]any{"type": "integer", "description": "Optional custom screen width in pixels"},
					"height":          map[string]any{"type": "integer", "description": "Optional custom screen height in pixels"},
					"reset":           map[string]any{"type": "boolean", "description": "Clone clean post-OOBE provisioned userdata before booting"},
					"display":         map[string]any{"type": "string", "enum": []string{"none", "cocoa", "vnc"}, "description": "QEMU display mode (default: none)"},
					"peer":            map[string]any{"type": "string", "description": "Dual-emulator LAN mode: off (default), listen[:PORT], or connect[:PORT]"},
					"net_mode":        map[string]any{"type": "string", "enum": []string{"auto", "bridged", "shared", "user"}, "description": "Ethernet backend: auto (default: prefers bridged -> shared -> user), bridged (L2 bridge via socket_vmnet_bridged), shared, or user"},
					"memory_mb":       map[string]any{"type": "integer", "description": "RAM in MiB (default 6144 for phone, 8192 for pc)"},
					"smp":             map[string]any{"type": "integer", "description": "vCPU count (default 4)"},
					"unlock":          map[string]any{"type": "boolean", "description": "Auto wake, keep awake and unlock to Home Screen (default true)"},
					"timeout_seconds": map[string]any{"type": "integer", "description": "Boot timeout in seconds (default 90)"},
				},
			},
		},
		{
			Name:        "ohos_stop",
			Description: "Sync userdata, disconnect hdc, and stop one running HarmonyOS 7 emulator instance (or all instances).",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"instance": map[string]any{"type": "string", "description": "Instance name (default: default or sole running instance)"},
					"all":      map[string]any{"type": "boolean", "description": "Stop all running instances"},
				},
			},
		},
		{
			Name:        "ohos_observe",
			Description: "Inspect a running HarmonyOS 7 emulator without mutating it: status, windows, hilog, faultlogs, bundles, or network.",
			InputSchema: map[string]any{
				"type":     "object",
				"required": []string{"what"},
				"properties": map[string]any{
					"what":     map[string]any{"type": "string", "enum": []string{"status", "windows", "hilog", "faultlogs", "bundles", "network"}},
					"instance": map[string]any{"type": "string"},
					"bundle":   map[string]any{"type": "string", "description": "hilog/bundles filter by bundle or process name"},
					"grep":     map[string]any{"type": "string", "description": "case-insensitive substring filter"},
					"limit":    map[string]any{"type": "integer", "description": "Max lines (default 80, max 300)"},
					"clear":    map[string]any{"type": "boolean", "description": "hilog: clear ring buffer after reading"},
				},
			},
		},
		{
			Name:        "ohos_screenshot",
			Description: "Capture the live 1080x2340 HarmonyOS 7 screen via QEMU QMP virtio-gpu screendump (or in-guest snapshot_display), save PNG to disk, and return its path/URL (plus optional base64 image block).",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"instance":       map[string]any{"type": "string"},
					"source":         map[string]any{"type": "string", "enum": []string{"qmp", "snapshot_display"}},
					"include_base64": map[string]any{"type": "boolean", "description": "Also include an MCP image content block with base64 pixels (default false; use view_image on returned path in Fancy)"},
				},
			},
		},
		{
			Name:        "ohos_act",
			Description: "Interact with a running HarmonyOS 7 emulator: tap, swipe, key, text, launch_app, stop_app, wake, or shell.",
			InputSchema: map[string]any{
				"type":     "object",
				"required": []string{"action"},
				"properties": map[string]any{
					"action":          map[string]any{"type": "string", "enum": []string{"tap", "swipe", "key", "text", "launch_app", "stop_app", "wake", "shell"}},
					"instance":        map[string]any{"type": "string"},
					"x":               map[string]any{"type": "integer", "description": "tap/swipe start X (0..1080)"},
					"y":               map[string]any{"type": "integer", "description": "tap/swipe start Y (0..2340)"},
					"x2":              map[string]any{"type": "integer", "description": "swipe end X"},
					"y2":              map[string]any{"type": "integer", "description": "swipe end Y"},
					"duration_ms":     map[string]any{"type": "integer", "description": "swipe duration ms (default 250)"},
					"key":             map[string]any{"type": "string", "description": "home, back, power, enter, volume_up, volume_down, or numeric keycode"},
					"text":            map[string]any{"type": "string", "description": "text to type"},
					"bundle":          map[string]any{"type": "string", "description": "bundleName for launch_app/stop_app"},
					"ability":         map[string]any{"type": "string", "description": "abilityName for launch_app (default EntryAbility)"},
					"command":         map[string]any{"type": "string", "description": "command for action=shell via hdc shell"},
					"timeout_seconds": map[string]any{"type": "integer", "description": "shell timeout seconds (default 30)"},
				},
			},
		},
		{
			Name:        "ohos_install",
			Description: "Sign (with emulator private PKI by default) and install a HarmonyOS .hap package via hdc install -r, optionally launching it.",
			InputSchema: map[string]any{
				"type":     "object",
				"required": []string{"path"},
				"properties": map[string]any{
					"path":       map[string]any{"type": "string", "description": "Host path to .hap file"},
					"instance":   map[string]any{"type": "string"},
					"sign":       map[string]any{"type": "boolean", "description": "Re-sign with emulator PKI (default true)"},
					"system_app": map[string]any{"type": "boolean", "description": "Sign with hos_system_app / system_basic"},
					"launch":     map[string]any{"type": "boolean", "description": "Launch after install"},
					"ability":    map[string]any{"type": "string", "description": "Ability to launch (default EntryAbility)"},
				},
			},
		},
		{
			Name:        "ohos_privacy",
			Description: "Read or toggle AppGallery standardized privacy auto-agree (@hms.core.appgalleryservice.privacyManager) for self-signed debug HAPs inside a running emulator.",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"instance":   map[string]any{"type": "string"},
					"auto_agree": map[string]any{"type": "boolean", "description": "Omit to read current state; true returns FULL_MODE_AGREED, false returns DISAGREED"},
				},
			},
		},
	}
}

func (m *Manager) handleMCP(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet || r.Method == http.MethodDelete {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var req rpcRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeRPC(w, rpcResponse{JSONRPC: "2.0", Error: &rpcError{Code: -32700, Message: "invalid JSON: " + err.Error()}})
		return
	}

	// JSON-RPC notifications have no id and expect 202 Accepted with empty body.
	if len(req.ID) == 0 || string(req.ID) == "null" {
		w.WriteHeader(http.StatusAccepted)
		return
	}

	switch req.Method {
	case "initialize":
		writeRPC(w, rpcResponse{
			JSONRPC: "2.0",
			ID:      req.ID,
			Result: map[string]any{
				"protocolVersion": "2025-03-26",
				"capabilities": map[string]any{
					"tools": map[string]any{"listChanged": false},
				},
				"serverInfo": map[string]any{
					"name":    "HarmonyEmulatorDashboard",
					"version": "1.0.0",
				},
			},
		})
	case "ping":
		writeRPC(w, rpcResponse{JSONRPC: "2.0", ID: req.ID, Result: map[string]any{}})
	case "tools/list":
		writeRPC(w, rpcResponse{
			JSONRPC: "2.0",
			ID:      req.ID,
			Result: map[string]any{
				"tools": mcpToolDefs(),
			},
		})
	case "tools/call":
		var p struct {
			Name      string          `json:"name"`
			Arguments json.RawMessage `json:"arguments"`
		}
		if err := json.Unmarshal(req.Params, &p); err != nil {
			writeRPC(w, rpcResponse{JSONRPC: "2.0", ID: req.ID, Error: &rpcError{Code: -32602, Message: "invalid params: " + err.Error()}})
			return
		}
		content, isErr := m.dispatchMCPTool(r.Context(), p.Name, p.Arguments)
		writeRPC(w, rpcResponse{
			JSONRPC: "2.0",
			ID:      req.ID,
			Result: map[string]any{
				"content": content,
				"isError": isErr,
			},
		})
	default:
		writeRPC(w, rpcResponse{
			JSONRPC: "2.0",
			ID:      req.ID,
			Error:   &rpcError{Code: -32601, Message: fmt.Sprintf("method not found: %s", req.Method)},
		})
	}
}

func (m *Manager) dispatchMCPTool(ctx context.Context, name string, raw json.RawMessage) ([]mcpContent, bool) {
	if len(strings.TrimSpace(string(raw))) == 0 {
		raw = json.RawMessage(`{}`)
	}
	okJSON := func(v any) ([]mcpContent, bool) {
		b, _ := json.MarshalIndent(v, "", "  ")
		return []mcpContent{{Type: "text", Text: string(b)}}, false
	}
	fail := func(err error) ([]mcpContent, bool) {
		return []mcpContent{{Type: "text", Text: err.Error()}}, true
	}

	switch name {
	case "ohos_status":
		var args struct {
			Instance string `json:"instance"`
		}
		if err := json.Unmarshal(raw, &args); err != nil {
			return fail(err)
		}
		return okJSON(m.Status(args.Instance))

	case "ohos_launch":
		var args LaunchRequest
		if err := json.Unmarshal(raw, &args); err != nil {
			return fail(err)
		}
		res, err := m.Launch(ctx, args)
		if err != nil {
			return fail(err)
		}
		return okJSON(res)

	case "ohos_stop":
		var args StopRequest
		if err := json.Unmarshal(raw, &args); err != nil {
			return fail(err)
		}
		res, err := m.Stop(ctx, args)
		if err != nil {
			return fail(err)
		}
		return okJSON(res)

	case "ohos_observe":
		var args ObserveRequest
		if err := json.Unmarshal(raw, &args); err != nil {
			return fail(err)
		}
		out, err := m.Observe(ctx, args)
		if err != nil {
			return fail(err)
		}
		return []mcpContent{{Type: "text", Text: out}}, false

	case "ohos_screenshot":
		var args struct {
			Instance      string `json:"instance"`
			Source        string `json:"source"`
			IncludeBase64 bool   `json:"include_base64"`
		}
		if err := json.Unmarshal(raw, &args); err != nil {
			return fail(err)
		}
		shot, err := m.Screenshot(ctx, args.Instance, args.Source)
		if err != nil {
			return fail(err)
		}
		meta, _ := json.MarshalIndent(shot, "", "  ")
		parts := []mcpContent{{Type: "text", Text: string(meta)}}
		if args.IncludeBase64 {
			parts = append(parts, mcpContent{
				Type:     "image",
				Data:     base64.StdEncoding.EncodeToString(shot.BytesData),
				MimeType: shot.MIMEType,
			})
		}
		return parts, false

	case "ohos_act":
		var args ActRequest
		if err := json.Unmarshal(raw, &args); err != nil {
			return fail(err)
		}
		out, err := m.Act(ctx, args)
		if err != nil {
			return fail(err)
		}
		return []mcpContent{{Type: "text", Text: out}}, false

	case "ohos_install":
		var args InstallRequest
		if err := json.Unmarshal(raw, &args); err != nil {
			return fail(err)
		}
		res, err := m.Install(ctx, args)
		if err != nil {
			return fail(err)
		}
		return okJSON(res)

	case "ohos_privacy":
		var args PrivacyRequest
		if err := json.Unmarshal(raw, &args); err != nil {
			return fail(err)
		}
		res, err := m.Privacy(ctx, args)
		if err != nil {
			return fail(err)
		}
		return okJSON(res)

	default:
		return fail(fmt.Errorf("unknown tool: %s", name))
	}
}

func writeRPC(w http.ResponseWriter, resp rpcResponse) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}
