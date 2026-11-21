package main

import (
	"archive/zip"
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

var validInstanceName = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,32}$`)

type StorageConfig struct {
	ImagesDir    string `json:"images_dir"`
	InstancesDir string `json:"instances_dir"`
	HDCPath      string `json:"hdc_path,omitempty"`
}

type LaunchRequest struct {
	Instance       string `json:"instance,omitempty"`
	Profile        string `json:"profile,omitempty"`
	Reset          bool   `json:"reset,omitempty"`
	Display        string `json:"display,omitempty"`
	Peer           string `json:"peer,omitempty"`
	NetMode        string `json:"net_mode,omitempty"`
	MemoryMB       int    `json:"memory_mb,omitempty"`
	SMP            int    `json:"smp,omitempty"`
	Width          int    `json:"width,omitempty"`
	Height         int    `json:"height,omitempty"`
	Unlock         *bool  `json:"unlock,omitempty"`
	TimeoutSeconds int    `json:"timeout_seconds,omitempty"`
}

type StopRequest struct {
	Instance string `json:"instance,omitempty"`
	All      bool   `json:"all,omitempty"`
}

type ObserveRequest struct {
	What     string `json:"what"`
	Instance string `json:"instance,omitempty"`
	Bundle   string `json:"bundle,omitempty"`
	Grep     string `json:"grep,omitempty"`
	Limit    int    `json:"limit,omitempty"`
	Clear    bool   `json:"clear,omitempty"`
}

type ActRequest struct {
	Action         string `json:"action"`
	Instance       string `json:"instance,omitempty"`
	X              int    `json:"x,omitempty"`
	Y              int    `json:"y,omitempty"`
	X2             int    `json:"x2,omitempty"`
	Y2             int    `json:"y2,omitempty"`
	DurationMS     int    `json:"duration_ms,omitempty"`
	Key            string `json:"key,omitempty"`
	Text           string `json:"text,omitempty"`
	Bundle         string `json:"bundle,omitempty"`
	Ability        string `json:"ability,omitempty"`
	Command        string `json:"command,omitempty"`
	TimeoutSeconds int    `json:"timeout_seconds,omitempty"`
}

type InstallRequest struct {
	Path      string `json:"path"`
	Instance  string `json:"instance,omitempty"`
	Sign      *bool  `json:"sign,omitempty"`
	SystemApp bool   `json:"system_app,omitempty"`
	Launch    bool   `json:"launch,omitempty"`
	Ability   string `json:"ability,omitempty"`
}

type PrivacyRequest struct {
	Instance  string `json:"instance,omitempty"`
	AutoAgree *bool  `json:"auto_agree,omitempty"`
}

type ScreenshotResult struct {
	Instance  string `json:"instance"`
	Source    string `json:"source"`
	Path      string `json:"path"`
	URL       string `json:"url"`
	MIMEType  string `json:"mime_type"`
	Bytes     int    `json:"bytes"`
	Width     int    `json:"width"`
	Height    int    `json:"height"`
	SHA256    string `json:"sha256"`
	Hint      string `json:"hint,omitempty"`
	BytesData []byte `json:"-"`
}

type InstanceInfo struct {
	Name      string `json:"name"`
	Profile   string `json:"profile"`
	PID       int    `json:"pid"`
	HDCTarget string `json:"hdc_target"`
	ShellPort int    `json:"shell_port"`
	Display   string `json:"display"`
	NetMode   string `json:"net_mode"`
	Peer      string `json:"peer"`
	Width     int    `json:"width"`
	Height    int    `json:"height"`
	UDID      string `json:"udid,omitempty"`
	UptimeSec int64  `json:"uptime_seconds"`
	ScreenURL string `json:"screen_url"`
	StreamURL string `json:"stream_url"`
}

type runningInstance struct {
	name      string
	profile   string
	instDir   string
	hdcPort   int
	shellPort int
	qmpSock   string
	display   string
	netMode   string
	peer      string
	width     int
	height    int
	udid      string
	cmd       *exec.Cmd
	stderrF   *os.File
	startedAt time.Time
	lastUsed  time.Time
	done      chan struct{}
	exitErr   error

	qmpMu sync.Mutex
}

type Manager struct {
	root         string
	imagesDir    string
	instancesDir string
	hdcPath      string
	configPath   string
	baseURL      string

	mu        sync.Mutex
	instances map[string]*runningInstance
}

func detectRoot(explicit string) string {
	if r := strings.TrimSpace(explicit); r != "" {
		return r
	}
	if r := strings.TrimSpace(os.Getenv("HMOS7_ROOT")); r != "" {
		return r
	}
	if exe, err := os.Executable(); err == nil {
		exeDir := filepath.Dir(exe)
		for _, cand := range []string{filepath.Dir(exeDir), exeDir} {
			if fileExists(filepath.Join(cand, "scripts", "run-hmos7.sh")) ||
				fileExists(filepath.Join(cand, "bin", "run-hmos7.sh")) {
				return cand
			}
		}
	}
	if wd, err := os.Getwd(); err == nil {
		for _, cand := range []string{wd, filepath.Dir(wd)} {
			if fileExists(filepath.Join(cand, "scripts", "run-hmos7.sh")) ||
				fileExists(filepath.Join(cand, "bin", "run-hmos7.sh")) {
				return cand
			}
		}
	}
	return "."
}

func detectHDC(explicit, root string) string {
	candidates := []string{
		strings.TrimSpace(explicit),
		strings.TrimSpace(os.Getenv("HMOS7_HDC")),
		filepath.Join(root, "tools", "hdc"),
		filepath.Join(root, "tools", runtime.GOOS+"-"+runtime.GOARCH, "hdc"),
	}
	if p, err := exec.LookPath("hdc"); err == nil {
		candidates = append(candidates, p)
	}
	for _, envVar := range []string{"OHOS_SDK_HOME", "DEVECO_SDK_HOME", "HARMONYOS_SDK_HOME"} {
		if base := strings.TrimSpace(os.Getenv(envVar)); base != "" {
			candidates = append(candidates,
				filepath.Join(base, "openharmony", "toolchains", "hdc"),
				filepath.Join(base, "default", "openharmony", "toolchains", "hdc"),
				filepath.Join(base, "toolchains", "hdc"),
			)
		}
	}
	home, _ := os.UserHomeDir()
	if home != "" {
		candidates = append(candidates,
			filepath.Join(home, "HarmonyOS", "Sdk", "openharmony", "toolchains", "hdc"),
			filepath.Join(home, "Library", "OpenHarmony", "Sdk", "toolchains", "hdc"),
		)
	}
	candidates = append(candidates, "/opt/ohos-sdk/openharmony/toolchains/hdc", "/usr/local/bin/hdc")
	for _, c := range candidates {
		if c != "" && fileExists(c) {
			return c
		}
	}
	return "hdc"
}

func fileExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}

func firstExisting(paths ...string) string {
	for _, p := range paths {
		if fileExists(p) {
			return p
		}
	}
	if len(paths) > 0 {
		return paths[0]
	}
	return ""
}

func NewManager(root, hdcPath, baseURL, imagesDir, instancesDir string) *Manager {
	resolvedRoot := detectRoot(root)
	cfgPath := filepath.Join(resolvedRoot, "config.json")

	var fileCfg StorageConfig
	if raw, err := os.ReadFile(cfgPath); err == nil {
		_ = json.Unmarshal(raw, &fileCfg)
	}

	pickPath := func(flagVal, envKey, cfgVal, fallback string) string {
		if v := strings.TrimSpace(flagVal); v != "" {
			return v
		}
		if v := strings.TrimSpace(os.Getenv(envKey)); v != "" {
			return v
		}
		if v := strings.TrimSpace(cfgVal); v != "" {
			return v
		}
		return fallback
	}

	resolvedImages := pickPath(imagesDir, "HMOS7_IMAGES_DIR", fileCfg.ImagesDir, filepath.Join(resolvedRoot, "images"))
	resolvedInstances := pickPath(instancesDir, "HMOS7_INSTANCES_DIR", fileCfg.InstancesDir, filepath.Join(resolvedRoot, "instances"))
	explicitHDC := strings.TrimSpace(hdcPath)
	if explicitHDC == "" {
		explicitHDC = strings.TrimSpace(fileCfg.HDCPath)
	}
	resolvedHDC := detectHDC(explicitHDC, resolvedRoot)

	return &Manager{
		root:         resolvedRoot,
		imagesDir:    resolvedImages,
		instancesDir: resolvedInstances,
		hdcPath:      resolvedHDC,
		configPath:   cfgPath,
		baseURL:      strings.TrimRight(baseURL, "/"),
		instances:    make(map[string]*runningInstance),
	}
}

func (m *Manager) GetConfig() map[string]any {
	m.mu.Lock()
	defer m.mu.Unlock()
	return map[string]any{
		"root":          m.root,
		"config_path":   m.configPath,
		"images_dir":    m.imagesDir,
		"instances_dir": m.instancesDir,
		"hdc_path":      m.hdcPath,
	}
}

func (m *Manager) UpdateConfig(req StorageConfig) (map[string]any, error) {
	m.mu.Lock()
	if v := strings.TrimSpace(req.ImagesDir); v != "" {
		abs, err := filepath.Abs(v)
		if err != nil {
			m.mu.Unlock()
			return nil, fmt.Errorf("invalid images_dir: %w", err)
		}
		m.imagesDir = abs
	}
	if v := strings.TrimSpace(req.InstancesDir); v != "" {
		abs, err := filepath.Abs(v)
		if err != nil {
			m.mu.Unlock()
			return nil, fmt.Errorf("invalid instances_dir: %w", err)
		}
		m.instancesDir = abs
	}
	if v := strings.TrimSpace(req.HDCPath); v != "" {
		m.hdcPath = detectHDC(v, m.root)
	}
	cfg := StorageConfig{
		ImagesDir:    m.imagesDir,
		InstancesDir: m.instancesDir,
		HDCPath:      m.hdcPath,
	}
	m.mu.Unlock()

	if b, err := json.MarshalIndent(cfg, "", "  "); err == nil {
		_ = os.WriteFile(m.configPath, append(b, '\n'), 0o644)
	}
	return m.GetConfig(), nil
}

func (m *Manager) launcherPath() string {
	return firstExisting(
		filepath.Join(m.root, "scripts", "run-hmos7.sh"),
		filepath.Join(m.root, "bin", "run-hmos7.sh"),
	)
}

func (m *Manager) signScriptPath() string {
	return firstExisting(
		filepath.Join(m.root, "scripts", "sign-hap.sh"),
		filepath.Join(m.root, "bin", "sign-hap.sh"),
	)
}

func normalizeProfile(p string) string {
	switch strings.ToLower(strings.TrimSpace(p)) {
	case "pc", "2in1", "desktop":
		return "pc"
	default:
		return "phone"
	}
}

func (m *Manager) missingRequirementsFor(profile string) []string {
	profile = normalizeProfile(profile)
	m.mu.Lock()
	imgDir := m.imagesDir
	hdc := m.hdcPath
	m.mu.Unlock()

	profDir := filepath.Join(imgDir, profile)
	var missing []string
	if _, err := exec.LookPath("qemu-system-aarch64"); err != nil {
		missing = append(missing, "qemu-system-aarch64 (not in PATH)")
	}
	if !fileExists(hdc) {
		if _, err := exec.LookPath(hdc); err != nil {
			missing = append(missing, "hdc (set HMOS7_HDC or add hdc to PATH)")
		}
	}
	checks := []struct {
		label string
		paths []string
	}{
		{"run-hmos7.sh", []string{filepath.Join(m.root, "scripts", "run-hmos7.sh"), filepath.Join(m.root, "bin", "run-hmos7.sh")}},
		{"kernel Image", []string{filepath.Join(profDir, "kernel", "Image"), filepath.Join(imgDir, "kernel", "Image"), filepath.Join(imgDir, "out", "kernel", "Image")}},
		{"initramfs.cpio.gz", []string{filepath.Join(profDir, "initramfs.cpio.gz"), filepath.Join(imgDir, "initramfs.cpio.gz"), filepath.Join(imgDir, "out", "initramfs.cpio.gz")}},
		{"qemu_overlay.img", []string{filepath.Join(profDir, "qemu_overlay.img"), filepath.Join(imgDir, "qemu_overlay.img"), filepath.Join(imgDir, "out", "qemu_overlay.img")}},
		{"donor system.img", func() []string {
			if profile == "pc" {
				return []string{filepath.Join(profDir, "donor", "system.img")}
			}
			return []string{filepath.Join(profDir, "donor", "system.img"), filepath.Join(imgDir, "donor", "system.img"), filepath.Join(imgDir, "donor", "pura70proplus-7.0.0.107", "images", "system.img")}
		}()},
	}
	for _, c := range checks {
		found := false
		for _, p := range c.paths {
			if fileExists(p) {
				found = true
				break
			}
		}
		if !found {
			missing = append(missing, c.label)
		}
	}
	return missing
}

func (m *Manager) missingRequirements() []string {
	return m.missingRequirementsFor("phone")
}

func (m *Manager) Usable() bool {
	return len(m.missingRequirementsFor("phone")) == 0 || len(m.missingRequirementsFor("pc")) == 0
}

func detectAccel() string {
	if runtime.GOOS == "darwin" && runtime.GOARCH == "arm64" {
		return "hvf"
	}
	if runtime.GOOS == "linux" && runtime.GOARCH == "arm64" {
		if f, err := os.OpenFile("/dev/kvm", os.O_RDWR, 0); err == nil {
			_ = f.Close()
			return "kvm"
		}
	}
	return "tcg"
}

func detectBridgedReady() (bridged bool, shared bool) {
	if runtime.GOOS == "darwin" {
		if _, err := os.Stat("/var/run/socket_vmnet_bridged"); err == nil {
			bridged = true
		}
		if _, err := os.Stat("/var/run/socket_vmnet"); err == nil {
			shared = true
		}
		return bridged, shared
	}
	if runtime.GOOS == "linux" {
		br := strings.TrimSpace(os.Getenv("HMOS7_BRIDGE"))
		if br == "" {
			br = "br0"
		}
		if st, err := os.Stat(filepath.Join("/sys/class/net", br, "bridge")); err == nil && st.IsDir() {
			if data, err := os.ReadFile("/etc/qemu/bridge.conf"); err == nil {
				for _, line := range strings.Split(string(data), "\n") {
					f := strings.Fields(strings.TrimSpace(line))
					if len(f) == 2 && f[0] == "allow" && (f[1] == br || f[1] == "all") {
						bridged = true
						break
					}
				}
			}
		}
	}
	return bridged, shared
}

func (m *Manager) Close(ctx context.Context) {
	m.mu.Lock()
	names := make([]string, 0, len(m.instances))
	for k := range m.instances {
		names = append(names, k)
	}
	m.mu.Unlock()
	for _, n := range names {
		_ = m.stopOne(ctx, n)
	}
}

func (m *Manager) savedInstances() []string {
	m.mu.Lock()
	instRoot := m.instancesDir
	m.mu.Unlock()

	entries, err := os.ReadDir(instRoot)
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range entries {
		if !validInstanceName.MatchString(e.Name()) {
			continue
		}
		dirPath := filepath.Join(instRoot, e.Name())
		if st, err := os.Stat(dirPath); err == nil && st.IsDir() && fileExists(filepath.Join(dirPath, "userdata.img")) {
			out = append(out, e.Name())
		}
	}
	sort.Strings(out)
	return out
}

func (m *Manager) Status(filterInstance string) map[string]any {
	qemuBin, _ := exec.LookPath("qemu-system-aarch64")
	m.mu.Lock()
	imgDir := m.imagesDir
	instRoot := m.instancesDir
	hdc := m.hdcPath
	m.mu.Unlock()

	provReady := fileExists(filepath.Join(imgDir, "phone", "userdata-provisioned.img")) ||
		fileExists(filepath.Join(imgDir, "userdata-provisioned.img")) ||
		fileExists(filepath.Join(imgDir, "out", "userdata-provisioned.img"))
	signReady := fileExists(m.signScriptPath())
	bridgedReady, sharedReady := detectBridgedReady()
	phoneMissing := m.missingRequirementsFor("phone")
	pcMissing := m.missingRequirementsFor("pc")

	m.mu.Lock()
	active := make([]InstanceInfo, 0, len(m.instances))
	for k, inst := range m.instances {
		select {
		case <-inst.done:
			delete(m.instances, k)
			continue
		default:
		}
		if filterInstance != "" && filterInstance != inst.name {
			continue
		}
		pid := 0
		if inst.cmd != nil && inst.cmd.Process != nil {
			pid = inst.cmd.Process.Pid
		}
		active = append(active, InstanceInfo{
			Name:      inst.name,
			Profile:   inst.profile,
			PID:       pid,
			HDCTarget: fmt.Sprintf("127.0.0.1:%d", inst.hdcPort),
			ShellPort: inst.shellPort,
			Display:   inst.display,
			NetMode:   inst.netMode,
			Peer:      inst.peer,
			Width:     inst.width,
			Height:    inst.height,
			UDID:      inst.udid,
			UptimeSec: int64(time.Since(inst.startedAt).Seconds()),
			ScreenURL: fmt.Sprintf("%s/api/instances/%s/screen.png", m.baseURL, inst.name),
			StreamURL: fmt.Sprintf("%s/api/instances/%s/stream", m.baseURL, inst.name),
		})
	}
	m.mu.Unlock()
	sort.Slice(active, func(i, j int) bool { return active[i].Name < active[j].Name })

	return map[string]any{
		"service":               "HarmonyEmulatorDashboard",
		"host_os":               runtime.GOOS,
		"host_arch":             runtime.GOARCH,
		"accel":                 detectAccel(),
		"usable":                len(phoneMissing) == 0 || len(pcMissing) == 0,
		"missing_requirements":  phoneMissing,
		"profiles": map[string]any{
			"phone": map[string]any{"usable": len(phoneMissing) == 0, "missing": phoneMissing},
			"pc":    map[string]any{"usable": len(pcMissing) == 0, "missing": pcMissing},
		},
		"dashboard_url":         m.baseURL,
		"mcp_url":               m.baseURL + "/mcp",
		"workspace_root":        m.root,
		"images_dir":            imgDir,
		"instances_dir":         instRoot,
		"config_path":           m.configPath,
		"qemu_bin":              qemuBin,
		"hdc_bin":               hdc,
		"provisioned_userdata":  provReady,
		"private_signing_ready": signReady,
		"bridged_ready":         bridgedReady,
		"shared_vmnet_ready":    sharedReady,
		"running_instances":     active,
		"saved_instances":       m.savedInstances(),
	}
}

func normalizeName(name string) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return "default", nil
	}
	if !validInstanceName.MatchString(name) {
		return "", fmt.Errorf("invalid instance name %q: use 1-32 chars of [A-Za-z0-9_.-]", name)
	}
	return name, nil
}

func (m *Manager) resolveRunning(name string) (*runningInstance, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for k, inst := range m.instances {
		select {
		case <-inst.done:
			delete(m.instances, k)
		default:
		}
	}
	name = strings.TrimSpace(name)
	if name == "" {
		if inst, ok := m.instances["default"]; ok {
			inst.lastUsed = time.Now()
			return inst, nil
		}
		if len(m.instances) == 1 {
			for _, inst := range m.instances {
				inst.lastUsed = time.Now()
				return inst, nil
			}
		}
		if len(m.instances) == 0 {
			return nil, errors.New("no HarmonyOS 7 emulator instance is running; launch one first")
		}
		return nil, errors.New("multiple instances are running; specify instance")
	}
	inst, ok := m.instances[name]
	if !ok {
		return nil, fmt.Errorf("instance %q is not running", name)
	}
	inst.lastUsed = time.Now()
	return inst, nil
}

func (m *Manager) Launch(ctx context.Context, req LaunchRequest) (map[string]any, error) {
	profile := normalizeProfile(req.Profile)
	if missing := m.missingRequirementsFor(profile); len(missing) > 0 {
		return nil, fmt.Errorf("profile %q missing requirements: %s", profile, strings.Join(missing, ", "))
	}
	name, err := normalizeName(req.Instance)
	if err != nil {
		return nil, err
	}

	m.mu.Lock()
	existing, exists := m.instances[name]
	if exists {
		select {
		case <-existing.done:
			delete(m.instances, name)
			exists = false
		default:
		}
	}
	m.mu.Unlock()

	if exists && !req.Reset {
		existing.lastUsed = time.Now()
		return map[string]any{
			"instance":   existing.name,
			"profile":    existing.profile,
			"reused":     true,
			"hdc_target": fmt.Sprintf("127.0.0.1:%d", existing.hdcPort),
			"udid":       existing.udid,
			"display":    existing.display,
			"net_mode":   existing.netMode,
			"width":      existing.width,
			"height":     existing.height,
			"screen_url": fmt.Sprintf("%s/api/instances/%s/screen.png", m.baseURL, existing.name),
			"stream_url": fmt.Sprintf("%s/api/instances/%s/stream", m.baseURL, existing.name),
		}, nil
	}
	if exists && req.Reset {
		_ = m.stopOne(ctx, name)
	}

	hdcPort, err := pickFreePort()
	if err != nil {
		return nil, err
	}
	shellPort, err := pickFreePort()
	if err != nil {
		return nil, err
	}

	display := strings.TrimSpace(req.Display)
	if display == "" {
		display = "none"
	}
	peer := strings.TrimSpace(req.Peer)
	if peer == "" {
		peer = "off"
	}
	netMode := strings.TrimSpace(req.NetMode)
	if netMode == "" {
		netMode = "auto"
	}
	width, height := req.Width, req.Height
	if profile == "pc" {
		if width <= 0 {
			width = 1920
		}
		if height <= 0 {
			height = 1080
		}
	} else {
		if width <= 0 {
			width = 1080
		}
		if height <= 0 {
			height = 2340
		}
	}
	mem := req.MemoryMB
	if mem <= 0 {
		if profile == "pc" {
			mem = 8192
		} else {
			mem = 6144
		}
	}
	smp := req.SMP
	if smp <= 0 {
		smp = 4
	}
	timeoutSec := req.TimeoutSeconds
	if timeoutSec <= 0 {
		timeoutSec = 90
	}
	if timeoutSec > 300 {
		timeoutSec = 300
	}
	unlock := true
	if req.Unlock != nil {
		unlock = *req.Unlock
	}

	m.mu.Lock()
	imgDir := m.imagesDir
	instRoot := m.instancesDir
	m.mu.Unlock()

	instDir := filepath.Join(instRoot, name)
	if err := os.MkdirAll(instDir, 0o755); err != nil {
		return nil, err
	}
	errFile, err := os.Create(filepath.Join(instDir, "qemu.stderr"))
	if err != nil {
		return nil, err
	}

	cmd := exec.Command(m.launcherPath())
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Stdout = errFile
	cmd.Stderr = errFile
	resetFlag := "0"
	if req.Reset {
		resetFlag = "1"
	}
	cmd.Env = append(os.Environ(),
		"HMOS7_ROOT="+m.root,
		"HMOS7_IMAGES_DIR="+imgDir,
		"HMOS7_INSTANCES_DIR="+instRoot,
		"HMOS7_PROFILE="+profile,
		"HMOS7_INSTANCE="+name,
		"HMOS7_RESET="+resetFlag,
		"HMOS7_HDC_PORT="+strconv.Itoa(hdcPort),
		"HMOS7_SHELL_PORT="+strconv.Itoa(shellPort),
		"HMOS7_DISPLAY="+display,
		"HMOS7_PEER="+peer,
		"HMOS7_NET="+netMode,
		"HMOS7_MEMORY="+strconv.Itoa(mem),
		"HMOS7_SMP="+strconv.Itoa(smp),
		"HMOS7_WIDTH="+strconv.Itoa(width),
		"HMOS7_HEIGHT="+strconv.Itoa(height),
	)
	if err := cmd.Start(); err != nil {
		_ = errFile.Close()
		return nil, fmt.Errorf("start qemu: %w", err)
	}

	inst := &runningInstance{
		name:      name,
		profile:   profile,
		instDir:   instDir,
		hdcPort:   hdcPort,
		shellPort: shellPort,
		qmpSock:   filepath.Join(instDir, "qmp.sock"),
		display:   display,
		netMode:   netMode,
		peer:      peer,
		width:     width,
		height:    height,
		cmd:       cmd,
		stderrF:   errFile,
		startedAt: time.Now(),
		lastUsed:  time.Now(),
		done:      make(chan struct{}),
	}
	go func() {
		inst.exitErr = cmd.Wait()
		_ = errFile.Close()
		close(inst.done)
	}()

	m.mu.Lock()
	m.instances[name] = inst
	m.mu.Unlock()

	// Detach boot wait from HTTP request cancellation so closing/refreshing the UI
	// or an MCP client timeout never kills a booting QEMU instance.
	bootCtx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutSec)*time.Second)
	defer cancel()

	target := fmt.Sprintf("127.0.0.1:%d", hdcPort)
	hdcReady := false
	sceneReady := false
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()

	for !sceneReady {
		select {
		case <-inst.done:
			m.mu.Lock()
			delete(m.instances, name)
			m.mu.Unlock()
			tail, _ := os.ReadFile(filepath.Join(instDir, "qemu.stderr"))
			return nil, fmt.Errorf("qemu exited early (%v): %s", inst.exitErr, strings.TrimSpace(string(tail)))
		case <-bootCtx.Done():
			// Keep QEMU alive if it is still booting (e.g. first-boot BMS scan on blank userdata)
			// rather than terminating a healthy VM out from under the operator.
			goto doneBoot
		case <-ticker.C:
			if !hdcReady {
				_, _ = m.runHDC(bootCtx, 5*time.Second, "tconn", target)
				out, err := m.hdcShell(bootCtx, target, 4*time.Second, "echo OK")
				if err == nil && strings.Contains(out, "OK") {
					hdcReady = true
				}
				continue
			}
			out, err := m.hdcShell(bootCtx, target, 5*time.Second, "param get init.sceneboard.finish")
			if err == nil && strings.TrimSpace(out) == "true" {
				sceneReady = true
			}
		}
	}
doneBoot:
	postCtx := context.Background()

	if hdcReady {
		if udidOut, err := m.hdcShell(postCtx, target, 8*time.Second, "bm get --udid"); err == nil {
		for _, line := range strings.Split(udidOut, "\n") {
			l := strings.TrimSpace(line)
			if len(l) == 64 {
				inst.udid = l
			}
		}
	}
	}

	unlocked := false
	if unlock && sceneReady {
		unlocked = m.wakeAndUnlock(postCtx, target)
	}
	inst.lastUsed = time.Now()

	return map[string]any{
		"instance":     inst.name,
		"profile":      inst.profile,
		"reused":       false,
		"pid":          cmd.Process.Pid,
		"hdc_target":   target,
		"hdc_ready":    hdcReady,
		"scene_ready":  sceneReady,
		"shell_port":   shellPort,
		"display":      display,
		"net_mode":     netMode,
		"peer":         peer,
		"width":        inst.width,
		"height":       inst.height,
		"udid":         inst.udid,
		"unlocked":     unlocked,
		"boot_seconds": int(time.Since(inst.startedAt).Seconds()),
		"screen_url":   fmt.Sprintf("%s/api/instances/%s/screen.png", m.baseURL, inst.name),
		"stream_url":   fmt.Sprintf("%s/api/instances/%s/stream", m.baseURL, inst.name),
	}, nil
}

func (m *Manager) wakeAndUnlock(ctx context.Context, target string) bool {
	select {
	case <-ctx.Done():
		return false
	case <-time.After(2500 * time.Millisecond):
	}
	_, _ = m.hdcShell(ctx, target, 8*time.Second,
		"begetctl start_service qemu_display_wake; begetctl start_service qemu_keep_awake; power-shell setmode 602; power-shell timeout -o 3600000")
	for i := 0; i < 4; i++ {
		select {
		case <-ctx.Done():
			return false
		case <-time.After(1200 * time.Millisecond):
		}
		_, _ = m.hdcShell(ctx, target, 5*time.Second, "uinput -T -m 540 2100 540 600 300")
		select {
		case <-ctx.Done():
			return false
		case <-time.After(1200 * time.Millisecond):
		}
		out, err := m.hdcShell(ctx, target, 5*time.Second, "hidumper -s 4606 -a '-a' 2>&1 | grep 'Focus window:'")
		if err == nil && strings.Contains(out, "Focus window: 14") {
			return true
		}
	}
	return false
}

func (m *Manager) Stop(ctx context.Context, req StopRequest) (map[string]any, error) {
	if req.All {
		m.mu.Lock()
		names := make([]string, 0, len(m.instances))
		for k := range m.instances {
			names = append(names, k)
		}
		m.mu.Unlock()
		for _, n := range names {
			_ = m.stopOne(ctx, n)
		}
		return map[string]any{"stopped": names}, nil
	}
	inst, err := m.resolveRunning(req.Instance)
	if err != nil {
		return nil, err
	}
	if err := m.stopOne(ctx, inst.name); err != nil {
		return nil, err
	}
	return map[string]any{"stopped": []string{inst.name}}, nil
}

func (m *Manager) stopOne(ctx context.Context, name string) error {
	m.mu.Lock()
	inst, ok := m.instances[name]
	if ok {
		delete(m.instances, name)
	}
	m.mu.Unlock()
	if !ok {
		return nil
	}

	target := fmt.Sprintf("127.0.0.1:%d", inst.hdcPort)
	syncCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	_, _ = m.hdcShell(syncCtx, target, 3*time.Second, "sync")
	_, _ = m.runHDC(syncCtx, 3*time.Second, "tconn", target, "-remove")
	cancel()

	if inst.cmd != nil && inst.cmd.Process != nil {
		pid := inst.cmd.Process.Pid
		_ = syscall.Kill(-pid, syscall.SIGTERM)
		select {
		case <-inst.done:
		case <-time.After(5 * time.Second):
			_ = syscall.Kill(-pid, syscall.SIGKILL)
			select {
			case <-inst.done:
			case <-time.After(2 * time.Second):
			}
		}
	}
	return nil
}

func (m *Manager) Observe(ctx context.Context, req ObserveRequest) (string, error) {
	inst, err := m.resolveRunning(req.Instance)
	if err != nil {
		return "", err
	}
	target := fmt.Sprintf("127.0.0.1:%d", inst.hdcPort)
	limit := req.Limit
	if limit <= 0 {
		limit = 80
	}
	if limit > 300 {
		limit = 300
	}

	switch req.What {
	case "status":
		cmd := "echo '=== BOOTEVENTS ==='; " +
			"for k in bootevent.samgr.ready bootevent.renderservice.ready init.sceneboard.finish bootevent.boot.completed const.product.software.version; do echo \"$k=$(param get $k 2>&1)\"; done; " +
			"echo '=== FOCUS ==='; hidumper -s 4606 -a '-a' 2>&1 | grep -E 'Focus window:|Total window num:'; " +
			"echo '=== PRIVACY AUTO-AGREE ==='; [ -f /data/local/tmp/qemu_privacy_disagreed ] && echo 'auto_agree=false' || echo 'auto_agree=true'; " +
			"echo '=== CORE PROCS ==='; ps -ef | grep -E 'composer_host|allocator_host|render_service|foundation|sceneboard|huks_service|useriam|softbus_server|device_manager|netmanager|dhcp_client|av_codec_service|hdcd' | grep -v grep"
		return m.hdcShell(ctx, target, 15*time.Second, cmd)

	case "windows":
		out, err := m.hdcShell(ctx, target, 15*time.Second, "hidumper -s 4606 -a '-a' 2>&1")
		if err != nil {
			return "", err
		}
		return filterAndClipLines(out, req.Grep, limit), nil

	case "hilog":
		cmd := "hilog -x 2>&1"
		if b := strings.TrimSpace(req.Bundle); b != "" {
			q := shellQuote(b)
			cmd = fmt.Sprintf("P=$(pidof %s 2>/dev/null); if [ -n \"$P\" ]; then hilog -x -P $P 2>&1; else hilog -x 2>&1 | grep -iF %s; fi", q, q)
		}
		out, err := m.hdcShell(ctx, target, 15*time.Second, cmd)
		if err != nil {
			return "", err
		}
		if req.Clear {
			_, _ = m.hdcShell(ctx, target, 5*time.Second, "hilog -r")
		}
		return filterAndClipTail(out, req.Grep, limit), nil

	case "faultlogs":
		cmd := "echo '=== /data/log/faultlog/temp ==='; ls -lt /data/log/faultlog/temp/ 2>&1 | head -n 20; " +
			"for f in $(ls -t /data/log/faultlog/temp/* 2>/dev/null | head -n 2); do echo \"--- $f ---\"; head -n 45 \"$f\"; done"
		return m.hdcShell(ctx, target, 15*time.Second, cmd)

	case "bundles":
		out, err := m.hdcShell(ctx, target, 15*time.Second, "bm dump -a 2>&1")
		if err != nil {
			return "", err
		}
		filter := req.Grep
		if filter == "" {
			filter = req.Bundle
		}
		return filterAndClipLines(out, filter, limit), nil

	case "network":
		cmd := "echo '=== IP ADDR ==='; ip addr 2>&1; echo '=== IP ROUTE ==='; ip route 2>&1; " +
			"echo '=== TUN ==='; ls -la /dev/net/tun /dev/tun 2>&1; " +
			"echo '=== NETCONN (1151) ==='; hidumper -s 1151 -a '-a' 2>&1 | head -n 25; " +
			"echo '=== ETHERNET (1157) ==='; hidumper -s 1157 2>&1 | head -n 25"
		return m.hdcShell(ctx, target, 15*time.Second, cmd)

	default:
		return "", fmt.Errorf("unsupported observe what=%q", req.What)
	}
}

func (m *Manager) capturePPM(ctx context.Context, inst *runningInstance) ([]byte, error) {
	inst.qmpMu.Lock()
	defer inst.qmpMu.Unlock()

	ppmFile := filepath.Join(inst.instDir, fmt.Sprintf("qmp-%d.ppm", time.Now().UnixNano()))
	defer os.Remove(ppmFile)
	if err := qmpScreendump(ctx, inst.qmpSock, ppmFile); err != nil {
		return nil, err
	}
	return os.ReadFile(ppmFile)
}

func (m *Manager) CaptureJPEG(ctx context.Context, instanceName string, halfScale bool) ([]byte, error) {
	inst, err := m.resolveRunning(instanceName)
	if err != nil {
		return nil, err
	}
	ppm, err := m.capturePPM(ctx, inst)
	if err != nil {
		return nil, err
	}
	jpg, _, _, err := encodePPMToJPEG(ppm, 78, halfScale)
	return jpg, err
}

func (m *Manager) Screenshot(ctx context.Context, instanceName, source string) (ScreenshotResult, error) {
	inst, err := m.resolveRunning(instanceName)
	if err != nil {
		return ScreenshotResult{}, err
	}
	source = strings.TrimSpace(source)
	if source == "" {
		source = "qmp"
	}

	var data []byte
	var mimeType string
	var w, h int
	var savedPath string

	if source == "snapshot_display" {
		target := fmt.Sprintf("127.0.0.1:%d", inst.hdcPort)
		remote := "/data/local/tmp/hed_snap.jpeg"
		if _, err := m.hdcShell(ctx, target, 15*time.Second, "snapshot_display -f "+remote); err != nil {
			return ScreenshotResult{}, fmt.Errorf("snapshot_display: %w", err)
		}
		savedPath = filepath.Join(inst.instDir, "last-screenshot.jpeg")
		if _, err := m.runHDC(ctx, 15*time.Second, "-t", target, "file", "recv", remote, savedPath); err != nil {
			return ScreenshotResult{}, fmt.Errorf("hdc file recv: %w", err)
		}
		data, err = os.ReadFile(savedPath)
		if err != nil {
			return ScreenshotResult{}, err
		}
		mimeType = "image/jpeg"
		w, h = 1080, 2340
	} else {
		ppm, err := m.capturePPM(ctx, inst)
		if err != nil {
			return ScreenshotResult{}, fmt.Errorf("qmp screendump: %w", err)
		}
		data, w, h, err = encodePPMToPNG(ppm)
		if err != nil {
			return ScreenshotResult{}, err
		}
		savedPath = filepath.Join(inst.instDir, "last-screenshot.png")
		_ = os.WriteFile(savedPath, data, 0o644)
		mimeType = "image/png"
	}

	sum := sha256.Sum256(data)
	return ScreenshotResult{
		Instance:  inst.name,
		Source:    source,
		Path:      savedPath,
		URL:       fmt.Sprintf("%s/api/instances/%s/screen.png", m.baseURL, inst.name),
		MIMEType:  mimeType,
		Bytes:     len(data),
		Width:     w,
		Height:    h,
		SHA256:    hex.EncodeToString(sum[:]),
		Hint:      "Call view_image with path to inspect the screenshot visually, or view live in HarmonyEmulatorDashboard.",
		BytesData: data,
	}, nil
}

func (m *Manager) Act(ctx context.Context, req ActRequest) (string, error) {
	inst, err := m.resolveRunning(req.Instance)
	if err != nil {
		return "", err
	}
	target := fmt.Sprintf("127.0.0.1:%d", inst.hdcPort)

	switch req.Action {
	case "tap":
		out, err := m.hdcShell(ctx, target, 10*time.Second, fmt.Sprintf("uinput -T -c %d %d", req.X, req.Y))
		return strings.TrimSpace(out), err

	case "swipe":
		dur := req.DurationMS
		if dur <= 0 {
			dur = 250
		}
		out, err := m.hdcShell(ctx, target, 10*time.Second, fmt.Sprintf("uinput -T -m %d %d %d %d %d", req.X, req.Y, req.X2, req.Y2, dur))
		return strings.TrimSpace(out), err

	case "key":
		k := strings.ToLower(strings.TrimSpace(req.Key))
		if k == "home" {
			out, err := m.hdcShell(ctx, target, 10*time.Second, "uinput -T -m 540 2320 540 1200 200")
			return strings.TrimSpace(out), err
		}
		code, ok := mapOHOSKey(k)
		if !ok {
			return "", fmt.Errorf("unknown key %q (home, back, power, enter, volume_up, volume_down, or numeric keycode)", req.Key)
		}
		out, err := m.hdcShell(ctx, target, 10*time.Second, fmt.Sprintf("uinput -K -d %d -u %d", code, code))
		return strings.TrimSpace(out), err

	case "text":
		if req.Text == "" {
			return "", errors.New("text is required")
		}
		out, err := m.hdcShell(ctx, target, 10*time.Second, fmt.Sprintf("uitest uiInput inputText 0 0 %s 2>&1", shellQuote(req.Text)))
		return strings.TrimSpace(out), err

	case "wake":
		ok := m.wakeAndUnlock(ctx, target)
		b, _ := json.Marshal(map[string]any{"instance": inst.name, "unlocked": ok})
		return string(b), nil

	case "launch_app":
		bundle := strings.TrimSpace(req.Bundle)
		if bundle == "" {
			return "", errors.New("bundle is required")
		}
		ability := strings.TrimSpace(req.Ability)
		if ability == "" {
			ability = "EntryAbility"
		}
		out, err := m.hdcShell(ctx, target, 15*time.Second, fmt.Sprintf("aa start -b %s -a %s 2>&1", shellQuote(bundle), shellQuote(ability)))
		if err == nil && strings.Contains(out, "10106102") {
			m.wakeAndUnlock(ctx, target)
			out, err = m.hdcShell(ctx, target, 15*time.Second, fmt.Sprintf("aa start -b %s -a %s 2>&1", shellQuote(bundle), shellQuote(ability)))
		}
		return strings.TrimSpace(out), err

	case "stop_app":
		bundle := strings.TrimSpace(req.Bundle)
		if bundle == "" {
			return "", errors.New("bundle is required")
		}
		out, err := m.hdcShell(ctx, target, 10*time.Second, fmt.Sprintf("aa force-stop %s 2>&1", shellQuote(bundle)))
		return strings.TrimSpace(out), err

	case "shell":
		if strings.TrimSpace(req.Command) == "" {
			return "", errors.New("command is required")
		}
		timeoutSec := req.TimeoutSeconds
		if timeoutSec <= 0 {
			timeoutSec = 30
		}
		if timeoutSec > 120 {
			timeoutSec = 120
		}
		return m.hdcShell(ctx, target, time.Duration(timeoutSec)*time.Second, req.Command)

	default:
		return "", fmt.Errorf("unsupported action %q", req.Action)
	}
}

func (m *Manager) Install(ctx context.Context, req InstallRequest) (map[string]any, error) {
	inst, err := m.resolveRunning(req.Instance)
	if err != nil {
		return nil, err
	}
	hapPath := strings.TrimSpace(req.Path)
	if hapPath == "" {
		return nil, errors.New("path is required")
	}
	absPath, err := filepath.Abs(hapPath)
	if err != nil {
		return nil, err
	}
	if !fileExists(absPath) {
		return nil, fmt.Errorf("hap file not found: %s", absPath)
	}

	sign := true
	if req.Sign != nil {
		sign = *req.Sign
	}
	installPath := absPath
	if sign {
		signScript := m.signScriptPath()
		tmpSigned, err := os.CreateTemp(inst.instDir, "signed-*.hap")
		if err != nil {
			return nil, err
		}
		signedPath := tmpSigned.Name()
		_ = tmpSigned.Close()
		defer os.Remove(signedPath)

		signArgs := []string{absPath, signedPath}
		if inst.udid != "" {
			signArgs = append(signArgs, inst.udid)
		}
		scmd := exec.CommandContext(ctx, signScript, signArgs...)
		scmd.Env = append(os.Environ(), "HMOS7_ROOT="+m.root)
		if req.SystemApp {
			scmd.Env = append(scmd.Env, "SYSTEM_APP=1")
		}
		if out, err := scmd.CombinedOutput(); err != nil {
			return nil, fmt.Errorf("sign-hap.sh failed: %v (%s)", err, strings.TrimSpace(string(out)))
		}
		installPath = signedPath
	}

	target := fmt.Sprintf("127.0.0.1:%d", inst.hdcPort)
	installOut, err := m.runHDC(ctx, 60*time.Second, "-t", target, "install", "-r", installPath)
	if err != nil {
		return nil, fmt.Errorf("hdc install failed: %v (%s)", err, strings.TrimSpace(installOut))
	}

	bundleName, defaultAbility := inspectHAPManifest(absPath)
	resp := map[string]any{
		"instance":    inst.name,
		"signed":      sign,
		"bundle_name": bundleName,
		"install_out": strings.TrimSpace(installOut),
	}
	if req.Launch && bundleName != "" {
		ability := strings.TrimSpace(req.Ability)
		if ability == "" {
			ability = defaultAbility
		}
		if ability == "" {
			ability = "EntryAbility"
		}
		launchOut, lerr := m.Act(ctx, ActRequest{
			Action:   "launch_app",
			Instance: inst.name,
			Bundle:   bundleName,
			Ability:  ability,
		})
		resp["launched_ability"] = ability
		if lerr != nil {
			resp["launch_error"] = lerr.Error()
		} else {
			resp["launch_out"] = launchOut
		}
	}
	return resp, nil
}

func (m *Manager) Privacy(ctx context.Context, req PrivacyRequest) (map[string]any, error) {
	inst, err := m.resolveRunning(req.Instance)
	if err != nil {
		return nil, err
	}
	target := fmt.Sprintf("127.0.0.1:%d", inst.hdcPort)
	if req.AutoAgree != nil {
		if *req.AutoAgree {
			_, err = m.hdcShell(ctx, target, 5*time.Second, "rm -f /data/local/tmp/qemu_privacy_disagreed")
		} else {
			_, err = m.hdcShell(ctx, target, 5*time.Second, "touch /data/local/tmp/qemu_privacy_disagreed && chmod 0644 /data/local/tmp/qemu_privacy_disagreed")
		}
		if err != nil {
			return nil, err
		}
	}
	out, err := m.hdcShell(ctx, target, 5*time.Second, "[ -f /data/local/tmp/qemu_privacy_disagreed ] && echo disagreed || echo agreed")
	if err != nil {
		return nil, err
	}
	agreed := strings.TrimSpace(out) == "agreed"
	return map[string]any{
		"instance":   inst.name,
		"auto_agree": agreed,
		"note":       "Controls @hms.core.appgalleryservice.privacyManager.getAppPrivacyResult() for self-signed debug HAPs. Restart the app to pick up changes.",
	}, nil
}

func (m *Manager) runHDC(ctx context.Context, timeout time.Duration, args ...string) (string, error) {
	cctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	cmd := exec.CommandContext(cctx, m.hdcPath, args...)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func (m *Manager) hdcShell(ctx context.Context, target string, timeout time.Duration, shellCmd string) (string, error) {
	return m.runHDC(ctx, timeout, "-t", target, "shell", shellCmd)
}

func qmpScreendump(ctx context.Context, sockPath, outPPM string) error {
	var d net.Dialer
	d.Timeout = 5 * time.Second
	conn, err := d.DialContext(ctx, "unix", sockPath)
	if err != nil {
		return err
	}
	defer conn.Close()
	if dl, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(dl)
	} else {
		_ = conn.SetDeadline(time.Now().Add(15 * time.Second))
	}
	rd := bufio.NewReader(conn)
	if _, err := rd.ReadString('\n'); err != nil {
		return fmt.Errorf("qmp greeting: %w", err)
	}
	if _, err := conn.Write([]byte("{\"execute\":\"qmp_capabilities\"}\n")); err != nil {
		return err
	}
	if _, err := readQMPResponse(rd); err != nil {
		return fmt.Errorf("qmp_capabilities: %w", err)
	}
	req, _ := json.Marshal(map[string]any{
		"execute":   "screendump",
		"arguments": map[string]any{"filename": outPPM},
	})
	if _, err := conn.Write(append(req, '\n')); err != nil {
		return err
	}
	if _, err := readQMPResponse(rd); err != nil {
		return fmt.Errorf("qmp screendump: %w", err)
	}
	return nil
}

func readQMPResponse(rd *bufio.Reader) (string, error) {
	for {
		line, err := rd.ReadString('\n')
		if err != nil {
			return "", err
		}
		var msg map[string]any
		if json.Unmarshal([]byte(line), &msg) != nil {
			continue
		}
		if _, isEvent := msg["event"]; isEvent {
			continue
		}
		if errObj, hasErr := msg["error"]; hasErr {
			return "", fmt.Errorf("qmp error: %v", errObj)
		}
		return line, nil
	}
}

func pickFreePort() (int, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer ln.Close()
	return ln.Addr().(*net.TCPAddr).Port, nil
}

func mapOHOSKey(k string) (int, bool) {
	switch k {
	case "back":
		return 2, true
	case "power":
		return 18, true
	case "volume_up":
		return 16, true
	case "volume_down":
		return 17, true
	case "enter":
		return 2054, true
	default:
		n, err := strconv.Atoi(k)
		if err == nil && n > 0 {
			return n, true
		}
		return 0, false
	}
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'"
}

func filterAndClipLines(text, grep string, limit int) string {
	lines := strings.Split(strings.TrimRight(text, "\n"), "\n")
	needle := strings.ToLower(strings.TrimSpace(grep))
	var out []string
	for _, l := range lines {
		if needle != "" && !strings.Contains(strings.ToLower(l), needle) {
			continue
		}
		out = append(out, l)
		if len(out) >= limit {
			break
		}
	}
	return strings.Join(out, "\n")
}

func filterAndClipTail(text, grep string, limit int) string {
	lines := strings.Split(strings.TrimRight(text, "\n"), "\n")
	needle := strings.ToLower(strings.TrimSpace(grep))
	var matched []string
	for _, l := range lines {
		if needle != "" && !strings.Contains(strings.ToLower(l), needle) {
			continue
		}
		matched = append(matched, l)
	}
	if len(matched) > limit {
		matched = matched[len(matched)-limit:]
	}
	return strings.Join(matched, "\n")
}

func inspectHAPManifest(hapPath string) (bundleName, firstAbility string) {
	zr, err := zip.OpenReader(hapPath)
	if err != nil {
		return "", ""
	}
	defer zr.Close()
	for _, f := range zr.File {
		if f.Name != "module.json" {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			return "", ""
		}
		defer rc.Close()
		var mj struct {
			App struct {
				BundleName string `json:"bundleName"`
			} `json:"app"`
			Module struct {
				MainElement string `json:"mainElement"`
				Abilities   []struct {
					Name string `json:"name"`
				} `json:"abilities"`
			} `json:"module"`
		}
		if json.NewDecoder(rc).Decode(&mj) == nil {
			ab := mj.Module.MainElement
			if ab == "" && len(mj.Module.Abilities) > 0 {
				ab = mj.Module.Abilities[0].Name
			}
			return mj.App.BundleName, ab
		}
	}
	return "", ""
}
