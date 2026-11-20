package main

import (
	"context"
	"embed"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

//go:embed web/*
var webFS embed.FS

func main() {
	defaultListen := strings.TrimSpace(os.Getenv("HMOS7_DASHBOARD_LISTEN"))
	if defaultListen == "" {
		defaultListen = "127.0.0.1:18555"
	}
	listen := flag.String("listen", defaultListen, "HTTP listen address")
	root := flag.String("root", "", "HarmonyEmulator workspace root (default HMOS7_ROOT or auto-detected)")
	hdc := flag.String("hdc", "", "Path to HarmonyOS hdc binary")
	flag.Parse()

	baseURL := "http://" + *listen
	if strings.HasPrefix(*listen, ":") {
		baseURL = "http://127.0.0.1" + *listen
	}
	mgr := NewManager(*root, *hdc, baseURL)

	mux := http.NewServeMux()
	// MCP Streamable HTTP endpoint for Fancy & other LLM clients
	mux.HandleFunc("/mcp", mgr.handleMCP)

	// Health & status
	mux.HandleFunc("GET /api/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "service": "HarmonyEmulatorDashboard", "usable": mgr.Usable()})
	})
	mux.HandleFunc("GET /api/status", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, mgr.Status(r.URL.Query().Get("instance")))
	})
	mux.HandleFunc("GET /api/mcp/tools", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"mcp_url": baseURL + "/mcp", "tools": mcpToolDefs()})
	})

	// Instance lifecycle
	mux.HandleFunc("POST /api/instances/launch", func(w http.ResponseWriter, r *http.Request) {
		var req LaunchRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
		res, err := mgr.Launch(r.Context(), req)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err)
			return
		}
		writeJSON(w, http.StatusOK, res)
	})
	mux.HandleFunc("POST /api/instances/stop", func(w http.ResponseWriter, r *http.Request) {
		var req StopRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
		res, err := mgr.Stop(r.Context(), req)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err)
			return
		}
		writeJSON(w, http.StatusOK, res)
	})

	// Per-instance live screen PNG, MJPEG stream, act, observe, install, privacy
	mux.HandleFunc("GET /api/instances/{name}/screen.png", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("name")
		source := r.URL.Query().Get("source")
		shot, err := mgr.Screenshot(r.Context(), name, source)
		if err != nil {
			writeErr(w, http.StatusBadGateway, err)
			return
		}
		w.Header().Set("Content-Type", shot.MIMEType)
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Screen-Width", strconv.Itoa(shot.Width))
		w.Header().Set("X-Screen-Height", strconv.Itoa(shot.Height))
		_, _ = w.Write(shot.BytesData)
	})

	mux.HandleFunc("GET /api/instances/{name}/stream", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("name")
		fps := 5
		if v, err := strconv.Atoi(r.URL.Query().Get("fps")); err == nil && v >= 1 && v <= 15 {
			fps = v
		}
		halfScale := r.URL.Query().Get("full") != "1"
		w.Header().Set("Content-Type", "multipart/x-mixed-replace; boundary=frame")
		w.Header().Set("Cache-Control", "no-store, no-cache, must-revalidate")
		flusher, _ := w.(http.Flusher)

		ticker := time.NewTicker(time.Second / time.Duration(fps))
		defer ticker.Stop()

		sendFrame := func() bool {
			jpg, err := mgr.CaptureJPEG(r.Context(), name, halfScale)
			if err != nil {
				return false
			}
			header := fmt.Sprintf("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: %d\r\n\r\n", len(jpg))
			if _, err := w.Write([]byte(header)); err != nil {
				return false
			}
			if _, err := w.Write(jpg); err != nil {
				return false
			}
			if _, err := w.Write([]byte("\r\n")); err != nil {
				return false
			}
			if flusher != nil {
				flusher.Flush()
			}
			return true
		}

		if !sendFrame() {
			return
		}
		for {
			select {
			case <-r.Context().Done():
				return
			case <-ticker.C:
				if !sendFrame() {
					return
				}
			}
		}
	})

	mux.HandleFunc("POST /api/instances/{name}/act", func(w http.ResponseWriter, r *http.Request) {
		var req ActRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
		req.Instance = r.PathValue("name")
		out, err := mgr.Act(r.Context(), req)
		if err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "output": out})
	})

	mux.HandleFunc("POST /api/instances/{name}/observe", func(w http.ResponseWriter, r *http.Request) {
		var req ObserveRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
		req.Instance = r.PathValue("name")
		out, err := mgr.Observe(r.Context(), req)
		if err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "output": out})
	})

	mux.HandleFunc("POST /api/instances/{name}/install", func(w http.ResponseWriter, r *http.Request) {
		name := r.PathValue("name")
		ct := strings.ToLower(r.Header.Get("Content-Type"))
		if strings.HasPrefix(ct, "multipart/form-data") {
			if err := r.ParseMultipartForm(512 << 20); err != nil {
				writeErr(w, http.StatusBadRequest, err)
				return
			}
			file, header, err := r.FormFile("file")
			if err != nil {
				writeErr(w, http.StatusBadRequest, fmt.Errorf("missing form field 'file': %w", err))
				return
			}
			defer file.Close()
			tmpFile, err := os.CreateTemp("", "hed-upload-*-"+filepath.Base(header.Filename))
			if err != nil {
				writeErr(w, http.StatusInternalServerError, err)
				return
			}
			tmpPath := tmpFile.Name()
			defer os.Remove(tmpPath)
			if _, err := io.Copy(tmpFile, file); err != nil {
				_ = tmpFile.Close()
				writeErr(w, http.StatusInternalServerError, err)
				return
			}
			_ = tmpFile.Close()
			sign := r.FormValue("sign") != "false"
			req := InstallRequest{
				Path:      tmpPath,
				Instance:  name,
				Sign:      &sign,
				SystemApp: r.FormValue("system_app") == "true",
				Launch:    r.FormValue("launch") == "true",
				Ability:   r.FormValue("ability"),
			}
			res, err := mgr.Install(r.Context(), req)
			if err != nil {
				writeErr(w, http.StatusInternalServerError, err)
				return
			}
			writeJSON(w, http.StatusOK, res)
			return
		}

		var req InstallRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
		req.Instance = name
		res, err := mgr.Install(r.Context(), req)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err)
			return
		}
		writeJSON(w, http.StatusOK, res)
	})

	mux.HandleFunc("GET /api/instances/{name}/privacy", func(w http.ResponseWriter, r *http.Request) {
		res, err := mgr.Privacy(r.Context(), PrivacyRequest{Instance: r.PathValue("name")})
		if err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
		writeJSON(w, http.StatusOK, res)
	})
	mux.HandleFunc("POST /api/instances/{name}/privacy", func(w http.ResponseWriter, r *http.Request) {
		var req PrivacyRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
		req.Instance = r.PathValue("name")
		res, err := mgr.Privacy(r.Context(), req)
		if err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
		writeJSON(w, http.StatusOK, res)
	})

	// Static Web UI
	sub, err := fs.Sub(webFS, "web")
	if err != nil {
		log.Fatal(err)
	}
	mux.HandleFunc("GET /favicon.ico", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusNoContent) })
	mux.Handle("/", http.FileServer(http.FS(sub)))

	srv := &http.Server{
		Addr:              *listen,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}

	stopCh := make(chan os.Signal, 1)
	signal.Notify(stopCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-stopCh
		log.Println("HarmonyEmulatorDashboard: shutting down...")
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		mgr.Close(ctx)
		_ = srv.Shutdown(ctx)
	}()

	log.Printf("HarmonyEmulatorDashboard listening on %s (Web UI: %s  |  MCP: %s/mcp)", *listen, baseURL, baseURL)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, err error) {
	writeJSON(w, status, map[string]any{"ok": false, "error": err.Error()})
}
