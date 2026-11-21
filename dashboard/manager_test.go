package main

import (
	"bytes"
	"encoding/json"
	"image/jpeg"
	"image/png"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestEncodePPMToPNGAndJPEG(t *testing.T) {
	var buf bytes.Buffer
	buf.WriteString("P6\n# test\n4 4\n255\n")
	for y := 0; y < 4; y++ {
		for x := 0; x < 4; x++ {
			buf.Write([]byte{byte(x * 60), byte(y * 60), 128})
		}
	}
	pngData, w, h, err := encodePPMToPNG(buf.Bytes())
	if err != nil || w != 4 || h != 4 {
		t.Fatalf("encodePPMToPNG: w=%d h=%d err=%v", w, h, err)
	}
	if _, err := png.Decode(bytes.NewReader(pngData)); err != nil {
		t.Fatalf("png.Decode: %v", err)
	}
	jpgData, jw, jh, err := encodePPMToJPEG(buf.Bytes(), 80, false)
	if err != nil || jw != 4 || jh != 4 {
		t.Fatalf("encodePPMToJPEG: w=%d h=%d err=%v", jw, jh, err)
	}
	if _, err := jpeg.Decode(bytes.NewReader(jpgData)); err != nil {
		t.Fatalf("jpeg.Decode: %v", err)
	}
}

func TestMCPEndpointInitializeListAndStatus(t *testing.T) {
	mgr := NewManager(t.TempDir(), "/nonexistent/hdc", "http://127.0.0.1:18555", "", "")
	post := func(body string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, "/mcp", bytes.NewBufferString(body))
		req.Header.Set("Content-Type", "application/json")
		rec := httptest.NewRecorder()
		mgr.handleMCP(rec, req)
		return rec
	}

	// initialize
	rec := post(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("initialize status=%d", rec.Code)
	}
	var initResp struct {
		Result struct {
			ProtocolVersion string `json:"protocolVersion"`
			ServerInfo      struct {
				Name string `json:"name"`
			} `json:"serverInfo"`
		} `json:"result"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &initResp); err != nil {
		t.Fatal(err)
	}
	if initResp.Result.ProtocolVersion != "2025-03-26" || initResp.Result.ServerInfo.Name != "HarmonyEmulatorDashboard" {
		t.Fatalf("unexpected initialize result: %+v", initResp.Result)
	}

	// notifications/initialized -> 202
	rec = post(`{"jsonrpc":"2.0","method":"notifications/initialized"}`)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("notification status=%d want 202", rec.Code)
	}

	// tools/list -> 8 tools
	rec = post(`{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}`)
	var listResp struct {
		Result struct {
			Tools []mcpToolDef `json:"tools"`
		} `json:"result"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &listResp); err != nil {
		t.Fatal(err)
	}
	if len(listResp.Result.Tools) != 8 {
		t.Fatalf("got %d tools, want 8", len(listResp.Result.Tools))
	}

	// tools/call ohos_status
	rec = post(`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ohos_status","arguments":{}}}`)
	if rec.Code != http.StatusOK || !bytes.Contains(rec.Body.Bytes(), []byte("HarmonyEmulatorDashboard")) {
		t.Fatalf("ohos_status call failed: %d %s", rec.Code, rec.Body.String())
	}
}
